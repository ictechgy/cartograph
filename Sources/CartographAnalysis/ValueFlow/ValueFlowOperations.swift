import CartographCore

extension ValueFlowSolver {
    func execute(_ instruction: ValueFlowInstruction, state original: FlowState) -> FlowCallOutcome {
        var state = original
        let context = contexts[activeContext]
        let result: ValueFlowValue
        switch instruction.operation {
        case let .operatorApplication(name, inputs):
            let reason = "operator " + name
            for input in inputs { edge(input, to: instruction.id, kind: "unverified") }
            let operands = inputs.map { value($0, in: state) }
            let escapingValues = operands.flatMap { operand in operand.atoms.map { atom -> ValueFlowValue in
                if case let .reference(address) = atom { return state.memory[address]?.value ?? ValueFlowValue() }
                return ValueFlowValue(atoms: [atom])
            } }
            let escapedObjects = reachableMemory(from: escapingValues, in: state)
            invalidate(&state, roots: operands, reason: reason, escape: false)
            state.escaped.formUnion(escapedObjects)
            result = .unknown(reason)
        case .stringLiteral:
            invalidate(&state, roots: Array(state.values.values) + context.key.arguments + context.key.captures,
                       reason: "unbound-string-literal", escape: true)
            result = .unknown("unbound-string-literal")
        case let .literal(literal):
            result = ValueFlowValue(atoms: [.literal(literal)], origins: [ValueFlowOrigin(
                id: "\(context.key.function):literal:\(instruction.id)", location: instruction.location, literal: literal
            )])
        case let .parameter(index):
            result = context.key.arguments.indices.contains(index)
                ? context.key.arguments[index] : .unknown("missing-argument")
        case .receiver:
            result = context.key.receiver ?? .unknown("unknown-receiver")
        case let .capture(index):
            result = context.key.captures.indices.contains(index)
                ? context.key.captures[index] : .unknown("missing-capture")
        case let .local(name, initial, mutable):
            let address = "local:\(context.id):\(instruction.id):\(name)"
            let initialValue = initial.map { value($0, in: state) } ?? ValueFlowValue()
            if initial != nil && initialValue.isBottom {
                return FlowCallOutcome(mayReturn: false, value: ValueFlowValue(), state: state)
            }
            let definition = memoryNode(for: instruction, value: initialValue)
            if let initial {
                activeEdges.insert(ValueFlowGraphEdge(source: nodeID(initial), target: definition, kind: "store"))
            }
            var cell = FlowCell(value: initialValue, mutable: mutable, unique: !activeBlockRepeated,
                                initialized: initial != nil, definitions: [definition])
            if activeBlockRepeated, let previous = state.memory[address] {
                cell = previous.joining(cell, limit: limits.valuesPerNode)
            }
            state.memory[address] = cell
            result = ValueFlowValue(atoms: [.reference(address)])
        case let .read(address):
            edge(address, to: instruction.id, kind: "address")
            return readMemory(value(address, in: state), instruction: instruction, state: state)
        case let .write(address, source):
            edge(address, to: instruction.id, kind: "address")
            activeEdges.insert(ValueFlowGraphEdge(source: nodeID(source),
                target: nodeID(-2 - instruction.id), kind: "store"))
            return writeMemory(value(address, in: state), value: value(source, in: state),
                               instruction: instruction, state: state)
        case let .symbol(reference):
            result = symbolValue(reference)
            if result.isUnknown {
                invalidate(&state, roots: context.key.receiver.map { [$0] } ?? [],
                           reason: "unknown-symbol-evaluation", escape: false)
            }
        case let .member(base, reference):
            let receiver = value(base, in: state)
            if receiver.isBottom { return FlowCallOutcome(mayReturn: false, value: ValueFlowValue(), state: state) }
            edge(base, to: instruction.id, kind: "receiver")
            result = memberValue(reference, receiver: receiver, state: state)
            if result.isUnknown {
                invalidate(&state, roots: [receiver], reason: "unknown-member-evaluation", escape: false)
            }
        case let .closure(function, captures):
            let values = captures.map { value($0, in: state) }
            if values.contains(where: \.isBottom) {
                return FlowCallOutcome(mayReturn: false, value: ValueFlowValue(), state: state)
            }
            for capture in captures { edge(capture, to: instruction.id, kind: "capture") }
            result = functionValue(FlowClosure(function: function, captures: values, receiver: nil))
        case let .call(callee, arguments, _, isAwait):
            edge(callee, to: instruction.id, kind: "invoke")
            let actual = arguments.map { value($0, in: state) }
            let called = value(callee, in: state)
            if called.isBottom || actual.contains(where: \.isBottom) {
                return FlowCallOutcome(mayReturn: false, value: ValueFlowValue(), state: state)
            }
            if isAwait {
                invalidate(&state, roots: [], reason: "await-shared-state", escape: false)
            }
            return call(called, arguments: actual, instruction: instruction, state: state)
        case let .unknown(reason, inputs, mayWrite):
            for input in inputs { edge(input, to: instruction.id, kind: "unverified") }
            if mayWrite {
                invalidate(&state, roots: Array(state.values.values) + context.key.arguments + context.key.captures
                    + (context.key.receiver.map { [$0] } ?? []), reason: reason, escape: false)
            }
            limitations.insert(reason)
            result = .unknown(reason)
        case let .copy(source):
            edge(source, to: instruction.id)
            result = value(source, in: state)
        }
        if state.memory.count > limits.heapCells {
            truncated = true
            limitations.insert("heap-budget")
            invalidate(&state, roots: Array(state.values.values) + context.key.arguments + context.key.captures
                + (context.key.receiver.map { [$0] } ?? []), reason: "heap-budget", escape: true)
            return FlowCallOutcome(mayReturn: true, value: .unknown("heap-budget"), state: state)
        }
        return FlowCallOutcome(mayReturn: true, value: result, state: state)
    }

    func symbolValue(_ reference: ValueFlowSymbolReference) -> ValueFlowValue {
        guard let usr = reference.usr else { return .unknown("unresolved-symbol") }
        if let id = functionByUSR[usr], let function = functions[id] {
            if function.ownerType != nil && !function.isStatic && function.kind != .initializer {
                guard let receiver = contexts[activeContext].key.receiver else { return .unknown("missing-receiver") }
                return functionValue(FlowClosure(function: id, captures: [], receiver: receiver))
            }
            return functionValue(FlowClosure(function: id, captures: [], receiver: nil))
        }
        if let type = typeByUSR[usr] { return ValueFlowValue(atoms: [.type(type)]) }
        if let id = fieldByUSR[usr], let field = fields[id], field.ownerType == nil || field.isStatic {
            return ValueFlowValue(atoms: [.reference(bindField(field, receiver: nil, object: nil))])
        }
        if let kind = reference.kind, [.function, .method, .initializer].contains(kind) {
            return functionValue(FlowClosure(function: usr, captures: [], receiver: nil))
        }
        if let kind = reference.kind, kind.isTypeDeclaration { return ValueFlowValue(atoms: [.type(usr)]) }
        return .unknown("unmodeled-symbol")
    }

    func memberValue(_ reference: ValueFlowSymbolReference, receiver: ValueFlowValue,
                     state: FlowState) -> ValueFlowValue {
        guard let usr = reference.usr else { return .unknown("unresolved-member") }
        if let type = typeByUSR[usr] { return ValueFlowValue(atoms: [.type(type)]) }
        if let id = functionByUSR[usr], let function = functions[id], function.ownerType == nil || function.isStatic {
            return functionValue(FlowClosure(function: id, captures: [], receiver: nil))
        }
        var result = receiver.isUnknown ? ValueFlowValue.unknown("unknown-receiver") : ValueFlowValue()
        for atom in receiver.atoms.sorted(by: { $0.stableKey < $1.stableKey }) {
            let object: String?
            let type: String?
            switch atom {
            case let .object(id, owner): object = id; type = owner
            case let .type(owner): object = nil; type = owner
            default:
                result = result.joining(.unknown("unsupported-receiver"), limit: limits.valuesPerNode)
                continue
            }
            let bound = ValueFlowValue(atoms: [atom], origins: receiver.origins)
            if let id = fieldByUSR[usr], let field = fields[id] {
                if !field.isStatic && object == nil {
                    result = result.joining(.unknown("unbound-instance-field"), limit: limits.valuesPerNode)
                } else {
                    result.atoms.insert(.reference(bindField(field, receiver: field.isStatic ? nil : bound,
                                                           object: field.isStatic ? nil : object)))
                }
            } else {
                let dispatch = program.dispatch.filter { $0.requirementUSR == usr && $0.ownerType == type }
                let ids = dispatch.isEmpty ? functionByUSR[usr].map { [$0] } ?? [] : dispatch.map(\.implementation)
                if ids.isEmpty {
                    if let kind = reference.kind, [.function, .method, .initializer].contains(kind) {
                        result = result.joining(functionValue(FlowClosure(function: usr, captures: [], receiver: bound)),
                                               limit: limits.valuesPerNode)
                    } else {
                        result = result.joining(.unknown("unmodeled-member"), limit: limits.valuesPerNode)
                    }
                }
                for id in ids.sorted() {
                    guard let function = functions[id] else {
                        result = result.joining(.unknown("missing-dispatch-body"), limit: limits.valuesPerNode)
                        continue
                    }
                    if !function.isStatic && object == nil && function.kind != .initializer {
                        result = result.joining(.unknown("unbound-instance-method"), limit: limits.valuesPerNode)
                    } else {
                        result = result.joining(functionValue(FlowClosure(function: id, captures: [],
                            receiver: function.isStatic || object == nil ? nil : bound)),
                            limit: limits.valuesPerNode)
                    }
                }
            }
        }
        return result
    }
}
