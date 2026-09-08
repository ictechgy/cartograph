import CartographCore

extension ValueFlowSolver {
    func call(_ callee: ValueFlowValue, arguments: [ValueFlowValue], instruction: ValueFlowInstruction,
              state original: FlowState) -> FlowCallOutcome {
        var combined = FlowCallOutcome(mayReturn: false, value: ValueFlowValue(), state: original)
        var hasState = false
        var unknown = callee.isUnknown
        for atom in callee.atoms.sorted(by: { $0.stableKey < $1.stableKey }) {
            guard case let .function(id) = atom, let frame = closures[id], let function = functions[frame.function] else {
                unknown = true
                continue
            }
            let outcome: FlowCallOutcome
            if function.kind == .initializer && frame.receiver == nil {
                outcome = construct(function, arguments: arguments, instruction: instruction, state: original)
            } else {
                outcome = invoke(frame, arguments: arguments, instruction: instruction, state: original, reason: "call")
            }
            if outcome.mayReturn {
                combined.mayReturn = true
                combined.value = combined.value.joining(outcome.value, limit: limits.valuesPerNode)
                combined.state = hasState ? combined.state.joining(outcome.state, limit: limits.valuesPerNode) : outcome.state
                combined.targets += outcome.targets
                hasState = true
            }
        }
        if unknown {
            var state = original
            let receiver = contexts[activeContext].key.receiver.map { [$0] } ?? []
            invalidate(&state, roots: arguments + [callee] + receiver, reason: "unknown-call", escape: true)
            discoverEscapingCallbacks(arguments + [callee], instruction: instruction, state: state)
            combined.value = combined.value.joining(.unknown("unknown-call"), limit: limits.valuesPerNode)
            combined.state = hasState ? combined.state.joining(state, limit: limits.valuesPerNode) : state
            combined.mayReturn = true
        }
        return combined
    }

    func invoke(_ frame: FlowClosure, arguments: [ValueFlowValue], instruction: ValueFlowInstruction,
                state original: FlowState, reason: String) -> FlowCallOutcome {
        guard let function = functions[frame.function] else {
            var state = original
            invalidate(&state, roots: arguments + frame.captures + (frame.receiver.map { [$0] } ?? []),
                       reason: "missing-function-body", escape: true)
            return FlowCallOutcome(mayReturn: true, value: .unknown("missing-function-body"), state: state)
        }
        guard arguments.count == function.parameters.count else {
            var state = original
            invalidate(&state, roots: arguments + frame.captures + (frame.receiver.map { [$0] } ?? []),
                       reason: "argument-mismatch", escape: true)
            return FlowCallOutcome(mayReturn: true, value: .unknown("argument-mismatch"), state: state)
        }
        let caller = activeContext
        let callID = "\(contexts[caller].key.function):\(instruction.id):\(reason)"
        let calls = contexts[caller].key.calls + [callID]
        let repeated = activeBlockRepeated || contexts[caller].key.function == function.id
        guard let target = request(function: function.id, arguments: arguments, captures: frame.captures,
            receiver: frame.receiver, state: original, call: instruction.location, caller: caller,
            reason: reason, calls: calls, repeated: repeated) else {
            var state = original
            invalidate(&state, roots: arguments + frame.captures + (frame.receiver.map { [$0] } ?? []),
                       reason: "context-budget", escape: true)
            return FlowCallOutcome(mayReturn: true, value: .unknown("context-budget"), state: state)
        }
        linkCall(instruction, target: target, function: function)
        if !contexts[target].summary.mayReturn && canEvaluateImmediately(function) {
            let saved = (activeContext, activeBlockRepeated, activeEdges, activeNodes)
            queued.remove(target)
            evaluate(target)
            (activeContext, activeBlockRepeated, activeEdges, activeNodes) = saved
        }
        let summary = contexts[target].summary
        guard summary.mayReturn else {
            return FlowCallOutcome(mayReturn: false, value: ValueFlowValue(), state: original, targets: [contexts[target].id])
        }
        var state = original
        for (key, cell) in summary.memory {
            var output = cell
            if output.definitions == nil, let prior = state.memory[key], prior.value == output.value,
               prior.initialized == output.initialized { output.definitions = prior.definitions }
            state.memory[key] = output
        }
        state.escaped.formUnion(summary.escaped)
        return FlowCallOutcome(mayReturn: true, value: summary.value, state: state, targets: [contexts[target].id])
    }

    func linkCall(_ instruction: ValueFlowInstruction, target: Int, function: ValueFlowFunction) {
        if case let .call(_, arguments, _, _) = instruction.operation {
            for operation in function.blocks.flatMap(\.instructions) {
                if case let .parameter(index) = operation.operation, arguments.indices.contains(index) {
                    activeEdges.insert(ValueFlowGraphEdge(source: nodeID(arguments[index]),
                        target: nodeID(operation.id, context: target), kind: "argument-to-parameter"))
                }
            }
        }
        activeEdges.insert(ValueFlowGraphEdge(source: nodeID(-1, context: target),
                                              target: nodeID(instruction.id), kind: "return-to-call"))
    }

    func construct(_ function: ValueFlowFunction, arguments: [ValueFlowValue], instruction: ValueFlowInstruction,
                   state original: FlowState) -> FlowCallOutcome {
        guard function.unavailableReason == nil, let owner = function.ownerType,
              let type = types[owner], !type.hasExternalBase, type.unavailableReason == nil else {
            var state = original
            invalidate(&state, roots: arguments, reason: "unmodeled-initializer", escape: true)
            return FlowCallOutcome(mayReturn: true, value: .unknown("unmodeled-initializer"), state: state)
        }
        let instanceFields = fields.values.filter { $0.ownerType == owner && !$0.isStatic }.sorted {
            $0.location == $1.location ? $0.id < $1.id : $0.location < $1.location
        }
        if !type.isReferenceType && instanceFields.contains(where: \.isMutable) {
            var state = original
            invalidate(&state, roots: arguments, reason: "mutable-value-type", escape: true)
            return FlowCallOutcome(mayReturn: true, value: .unknown("mutable-value-type"), state: state)
        }
        let object = "\(contexts[activeContext].id):allocation:\(instruction.id):\(owner)"
        let receiver = ValueFlowValue(atoms: [.object(id: object, type: owner)])
        var state = original
        for field in instanceFields {
            let address = bindField(field, receiver: receiver, object: object)
            if state.memory[address] == nil {
                state.memory[address] = FlowCell(value: ValueFlowValue(), mutable: field.isMutable,
                    unique: !activeBlockRepeated, initialized: false, definitions: nil)
            }
            if let initializer = field.initializer, state.memory[address]?.initialized != true {
                let result = invoke(FlowClosure(function: initializer, captures: [], receiver: receiver),
                                    arguments: [], instruction: instruction, state: state, reason: "field-initializer:\(field.id)")
                guard result.mayReturn else { return result }
                state = result.state
                state.memory[address] = FlowCell(value: result.value, mutable: field.isMutable,
                    unique: !activeBlockRepeated, initialized: true,
                    definitions: [memoryNode(for: instruction, value: result.value)])
            }
            if field.hasUnknownObservers {
                invalidate(&state, roots: [receiver], reason: "unmodeled-property-initialization", escape: true)
            }
        }
        return invoke(FlowClosure(function: function.id, captures: [], receiver: receiver), arguments: arguments,
                      instruction: instruction, state: state, reason: "constructor")
    }

    /// 외부로 넘긴 콜백은 호출되지 않았다고 가정하지 않는다. 미상 인자의 별도 문맥으로 남긴다.
    func discoverEscapingCallbacks(_ values: [ValueFlowValue], instruction: ValueFlowInstruction, state: FlowState) {
        let frames = Set(values.flatMap(\.atoms)).sorted { $0.stableKey < $1.stableKey }
        for atom in frames {
            guard case let .function(id) = atom, let frame = closures[id], let function = functions[frame.function] else { continue }
            let args = function.parameters.map { _ in ValueFlowValue.unknown("escaped-callback-parameter") }
            let callID = "escaped:\(contexts[activeContext].key.function):\(instruction.id)"
            _ = request(function: function.id, arguments: args, captures: frame.captures, receiver: frame.receiver,
                        state: state, call: instruction.location, caller: activeContext, reason: "escaped-callback",
                        calls: contexts[activeContext].key.calls + [callID], repeated: true)
        }
    }
}
