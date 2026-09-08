import CartographCore

extension ValueFlowSolver {
    func objectPrefix(_ object: String) -> String { "object:\(object.utf8.count):\(object):" }

    func reachableMemory(from roots: [ValueFlowValue], in state: FlowState) -> Set<String> {
        var pending = roots.flatMap { $0.atoms }
        var visitedAtoms: Set<ValueFlowAtom> = []
        var result: Set<String> = []
        while let atom = pending.popLast() {
            guard visitedAtoms.insert(atom).inserted else { continue }
            switch atom {
            case let .reference(address):
                if result.insert(address).inserted, let cell = state.memory[address] { pending += cell.value.atoms }
            case let .object(id, _):
                for (key, cell) in state.memory where key.hasPrefix(objectPrefix(id)) {
                    if result.insert(key).inserted { pending += cell.value.atoms }
                }
            case let .function(id):
                if let frame = closures[id] {
                    pending += frame.captures.flatMap { $0.atoms }
                    pending += frame.receiver?.atoms ?? []
                }
            default: break
            }
        }
        return result
    }

    /// 외부 호출은 인자/캡처로 닿는 가변 메모리와 이미 외부에 노출된 상태를 무효화한다.
    func invalidate(_ state: inout FlowState, roots: [ValueFlowValue], reason: String, escape: Bool) {
        let globals = state.memory.filter { $0.key.hasPrefix("global:") || state.escaped.contains($0.key) }
            .map { $0.value.value }
        let reached = reachableMemory(from: roots + globals, in: state)
        let affected = reached.union(state.escaped).union(state.memory.keys.filter { $0.hasPrefix("global:") })
        for address in affected {
            guard var cell = state.memory[address] else { continue }
            guard cell.mutable || (address.hasPrefix("global:") && !cell.initialized) else { continue }
            cell.value = .unknown(reason, origins: cell.value.origins)
            cell.initialized = true
            cell.definitions = nil
            state.memory[address] = cell
        }
        if escape { state.escaped.formUnion(reached) }
        limitations.insert(reason)
    }

    func memoryNode(for instruction: ValueFlowInstruction, value: ValueFlowValue) -> String {
        let id = -2 - instruction.id
        let prior = activeNodes[id]?.value ?? ValueFlowValue()
        activeNodes[id] = ValueFlowGraphNode(id: nodeID(id), context: contexts[activeContext].id,
            function: contexts[activeContext].key.function, instruction: id, kind: "memory",
            location: instruction.location, value: prior.joining(value, limit: limits.valuesPerNode))
        return nodeID(id)
    }

    func bindField(_ field: ValueFlowField, receiver: ValueFlowValue?, object: String?) -> String {
        let address = object.map { objectPrefix($0) + field.id } ?? "global:\(field.id)"
        boundFields[address] = FlowBoundField(field: field.id, receiver: receiver)
        return address
    }

    func readMemory(_ addressValue: ValueFlowValue, instruction: ValueFlowInstruction,
                    state original: FlowState) -> FlowCallOutcome {
        if addressValue.isBottom { return FlowCallOutcome(mayReturn: false, value: ValueFlowValue(), state: original) }
        var result = addressValue.isUnknown ? ValueFlowValue.unknown("unknown-address") : ValueFlowValue()
        var joined: FlowState?
        var mayReturn = false
        for atom in addressValue.atoms.sorted(by: { $0.stableKey < $1.stableKey }) {
            guard case let .reference(address) = atom else {
                result = result.joining(ValueFlowValue(atoms: [atom], origins: addressValue.origins),
                                         limit: limits.valuesPerNode)
                joined = joined.map { $0.joining(original, limit: limits.valuesPerNode) } ?? original
                mayReturn = true
                continue
            }
            var state = original
            if let binding = boundFields[address], let field = fields[binding.field] {
                if let getter = field.getter {
                    let outcome = invoke(FlowClosure(function: getter, captures: [], receiver: binding.receiver),
                                         arguments: [], instruction: instruction, state: state, reason: "getter")
                    if outcome.mayReturn {
                        result = result.joining(outcome.value, limit: limits.valuesPerNode)
                        joined = joined.map { $0.joining(outcome.state, limit: limits.valuesPerNode) } ?? outcome.state
                        mayReturn = true
                    }
                    continue
                }
                if state.memory[address]?.initialized != true, let initializer = field.initializer {
                    let previous = state.memory[address]?.value ?? ValueFlowValue()
                    state.memory[address] = FlowCell(value: .unknown("recursive-initialization"),
                        mutable: field.isMutable, unique: true, initialized: true, definitions: nil)
                    let outcome = invoke(FlowClosure(function: initializer, captures: [], receiver: binding.receiver),
                                         arguments: [], instruction: instruction, state: state, reason: "initializer")
                    guard outcome.mayReturn else { continue }
                    state = outcome.state
                    state.memory[address] = FlowCell(value: previous.joining(outcome.value, limit: limits.valuesPerNode),
                        mutable: field.isMutable, unique: true, initialized: true,
                        definitions: [memoryNode(for: instruction, value: outcome.value)])
                }
                if field.hasUnknownObservers {
                    result = result.joining(.unknown("property-observer"), limit: limits.valuesPerNode)
                    mayReturn = true
                    joined = joined.map { $0.joining(state, limit: limits.valuesPerNode) } ?? state
                    continue
                }
            }
            let read = state.memory[address]?.value ?? .unknown("uninitialized-memory")
            result = result.joining(read.isBottom ? .unknown("uninitialized-memory") : read,
                                    limit: limits.valuesPerNode)
            let definitions = state.memory[address]?.definitions
                ?? contexts[activeContext].inputDefinitions[address, default: []]
            for definition in definitions {
                activeEdges.insert(ValueFlowGraphEdge(source: definition, target: nodeID(instruction.id), kind: "load"))
            }
            joined = joined.map { $0.joining(state, limit: limits.valuesPerNode) } ?? state
            mayReturn = true
        }
        if addressValue.isUnknown { mayReturn = true; joined = joined ?? original }
        return FlowCallOutcome(mayReturn: mayReturn, value: result, state: joined ?? original)
    }

    func writeMemory(_ addressValue: ValueFlowValue, value stored: ValueFlowValue,
                     instruction: ValueFlowInstruction, state original: FlowState) -> FlowCallOutcome {
        if addressValue.isBottom || stored.isBottom {
            return FlowCallOutcome(mayReturn: false, value: ValueFlowValue(), state: original)
        }
        var state = original
        let addresses = addressValue.atoms.compactMap { atom -> String? in
            if case let .reference(address) = atom { return address }; return nil
        }.sorted()
        if addressValue.isUnknown || addresses.count != addressValue.atoms.count {
            invalidate(&state, roots: Array(state.values.values), reason: "unknown-write", escape: false)
        }
        if addresses.count > 1 && addresses.contains(where: {
            boundFields[$0].flatMap { fields[$0.field]?.setter } != nil
        }) {
            let receivers = addresses.compactMap { boundFields[$0]?.receiver }
            invalidate(&state, roots: receivers + [stored], reason: "ambiguous-property-setter", escape: true)
            return FlowCallOutcome(mayReturn: true, value: ValueFlowValue(atoms: [.literal(.unit)]), state: state)
        }
        let definition = memoryNode(for: instruction, value: stored)
        for address in addresses {
            if let binding = boundFields[address], let field = fields[binding.field] {
                if let setter = field.setter {
                    let outcome = invoke(FlowClosure(function: setter, captures: [], receiver: binding.receiver),
                                         arguments: [stored], instruction: instruction, state: state, reason: "setter")
                    guard outcome.mayReturn else { return outcome }
                    state = outcome.state
                    continue
                }
                if field.getter != nil || field.hasUnknownObservers {
                    invalidate(&state, roots: binding.receiver.map { [$0] } ?? [], reason: "property-write", escape: false)
                    state.memory[address] = FlowCell(value: .unknown("property-write"), mutable: true,
                                                     unique: false, initialized: true, definitions: nil)
                    continue
                }
            }
            var cell = state.memory[address] ?? FlowCell(value: ValueFlowValue(), mutable: true,
                                                         unique: false, initialized: false, definitions: nil)
            let strong = addresses.count == 1 && !addressValue.isUnknown && cell.unique
            cell.value = strong || !cell.initialized ? stored : cell.value.joining(stored, limit: limits.valuesPerNode)
            cell.initialized = true
            cell.definitions = strong ? [definition] : (cell.definitions
                ?? contexts[activeContext].inputDefinitions[address, default: []]).union([definition])
            state.memory[address] = cell
        }
        return FlowCallOutcome(mayReturn: true, value: ValueFlowValue(atoms: [.literal(.unit)]), state: state)
    }
}
