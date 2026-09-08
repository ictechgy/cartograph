import CartographCore

extension ValueFlowSolver {
    func evaluate(_ index: Int) {
        guard let function = functions[contexts[index].key.function] else { return }
        activeContext = index
        activeEdges = []
        activeNodes = [:]
        let input = contexts[index].key
        var initial = FlowState(memory: input.memory, escaped: input.escaped)
        for (address, definitions) in contexts[index].inputDefinitions {
            initial.memory[address]?.definitions = definitions
        }
        if let reason = function.unavailableReason {
            invalidate(&initial, roots: input.arguments + input.captures + (input.receiver.map { [$0] } ?? []),
                       reason: reason, escape: false)
            finish(FlowSummary(mayReturn: true, value: .unknown(reason), memory: initial.memory, escaped: initial.escaped), function: function)
            return
        }
        let blocks = Dictionary(function.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let repeatedBlocks: Set<Int>
        if let cached = repeatedBlocksByFunction[function.id] { repeatedBlocks = cached }
        else {
            repeatedBlocks = cyclicBlocks(function.blocks)
            repeatedBlocksByFunction[function.id] = repeatedBlocks
        }
        var incoming = [function.entry: initial]
        var work = [function.entry]
        var present: Set<Int> = [function.entry]
        var offset = 0
        var summary = FlowSummary()
        while offset < work.count && iterations < limits.iterations {
            let id = work[offset]
            offset += 1
            present.remove(id)
            iterations += 1
            guard let block = blocks[id], var state = incoming[id] else { continue }
            activeBlockRepeated = input.repeated || repeatedBlocks.contains(id)
            var proceeds = true
            for instruction in block.instructions {
                if iterations >= limits.iterations {
                    truncated = true
                    limitations.insert("iteration-budget")
                    summary.value.unknownReasons.insert("iteration-budget")
                    proceeds = false
                    break
                }
                iterations += 1
                let outcome = execute(instruction, state: state)
                state = outcome.state
                state.values[instruction.id] = outcome.value
                record(instruction, value: outcome.value)
                if !outcome.mayReturn { proceeds = false; break }
            }
            guard proceeds else { continue }
            switch block.terminator {
            case let .return(operand):
                let result: ValueFlowValue
                if function.kind == .initializer { result = input.receiver ?? .unknown("initializer-receiver") }
                else { result = operand.map { value($0, in: state) } ?? ValueFlowValue(atoms: [.literal(.unit)]) }
                if result.isBottom { continue }
                if let operand { edge(operand, to: -1, kind: "return") }
                let retained = reachableMemory(from: [result] + input.arguments + input.captures
                    + (input.receiver.map { [$0] } ?? []), in: state)
                let memory = state.memory.filter {
                    retained.contains($0.key) || $0.key.hasPrefix("global:") || state.escaped.contains($0.key)
                }
                summary = summary.joining(FlowSummary(mayReturn: true, value: result, memory: memory,
                                                      escaped: state.escaped), limit: limits.valuesPerNode)
            case let .jump(target):
                joinBlock(target, state: state, incoming: &incoming, work: &work, present: &present)
            case let .branch(condition, then, otherwise):
                let tested = value(condition, in: state)
                if tested.isBottom { continue }
                let onlyTrue = !tested.isUnknown && tested.atoms == [.literal(.boolean(true))]
                let onlyFalse = !tested.isUnknown && tested.atoms == [.literal(.boolean(false))]
                if !onlyFalse { joinBlock(then, state: state, incoming: &incoming, work: &work, present: &present) }
                if !onlyTrue { joinBlock(otherwise, state: state, incoming: &incoming, work: &work, present: &present) }
            case let .stop(reason):
                limitations.insert(reason)
                invalidate(&state, roots: Array(state.values.values) + input.arguments + input.captures
                    + (input.receiver.map { [$0] } ?? []), reason: reason, escape: true)
                summary = summary.joining(FlowSummary(mayReturn: true, value: .unknown(reason),
                    memory: state.memory, escaped: state.escaped),
                                           limit: limits.valuesPerNode)
            }
        }
        if offset < work.count {
            truncated = true
            limitations.insert("iteration-budget")
            summary.value.unknownReasons.insert("iteration-budget")
        }
        finish(summary, function: function)
    }

    func joinBlock(_ target: Int, state: FlowState, incoming: inout [Int: FlowState],
                   work: inout [Int], present: inout Set<Int>) {
        let joined = incoming[target].map { $0.joining(state, limit: limits.valuesPerNode) } ?? state
        if incoming[target] != joined {
            incoming[target] = joined
            if present.insert(target).inserted { work.append(target) }
        }
    }

    func finish(_ summary: FlowSummary, function: ValueFlowFunction) {
        let index = activeContext
        let old = contexts[index].summary
        let joined = old.joining(summary, limit: limits.valuesPerNode)
        contexts[index].summary = joined
        activeNodes[-1] = ValueFlowGraphNode(id: nodeID(-1), context: contexts[index].id,
            function: function.id, instruction: -1, kind: "return", location: function.location, value: joined.value)
        contexts[index].nodes = activeNodes
        contexts[index].edges.formUnion(activeEdges)
        if joined != old {
            for parent in dependents[index, default: []].sorted() { schedule(parent) }
        }
    }

    /// 블록 순서와 무관하게 뒤로 돌아올 수 있는 블록을 찾는다. 반복 할당의 강한 갱신을 막는다.
    func cyclicBlocks(_ blocks: [ValueFlowBlock]) -> Set<Int> {
        let nodes = blocks.map { GraphNode(id: NodeID(String($0.id)), name: "block", kind: .function) }
        var edges: [GraphEdge] = []
        for block in blocks {
            let targets: [Int]
            switch block.terminator {
            case let .jump(next): targets = [next]
            case let .branch(_, left, right): targets = [left, right]
            default: targets = []
            }
            edges += targets.map { GraphEdge(source: NodeID(String(block.id)), target: NodeID(String($0)), kind: .reference) }
        }
        // 검증된 반복형 SCC를 재사용하는 내부 어댑터다. 이 그래프를 심볼 결과로 내보내지 않는다.
        let graph = CodeGraph(level: .symbol, nodes: nodes, edges: edges)
        let components = CycleDetector(options: .init(edgeKinds: [.reference])).stronglyConnectedComponents(in: graph)
        var result = Set(components.filter { $0.count > 1 }.flatMap { $0 }.compactMap { Int($0.rawValue) })
        for edge in edges where edge.source == edge.target {
            if let id = Int(edge.source.rawValue) { result.insert(id) }
        }
        return result
    }

    func record(_ instruction: ValueFlowInstruction, value: ValueFlowValue) {
        let joined = activeNodes[instruction.id].map {
            $0.value.joining(value, limit: limits.valuesPerNode)
        } ?? value
        activeNodes[instruction.id] = ValueFlowGraphNode(id: nodeID(instruction.id),
            context: contexts[activeContext].id, function: contexts[activeContext].key.function,
            instruction: instruction.id, kind: operationKind(instruction.operation),
            location: instruction.location, value: joined)
    }

    func operationKind(_ operation: ValueFlowOperation) -> String {
        switch operation {
        case .literal: "literal"
        case .stringLiteral: "unbound-string-literal"
        case .operatorApplication: "unmodeled-operator"
        case .parameter: "parameter"
        case .receiver: "receiver"
        case .capture: "capture"
        case .local: "local"
        case .read: "read"
        case .write: "write"
        case .symbol: "symbol"
        case .member: "member"
        case .closure: "closure"
        case .call: "call"
        case .unknown: "unknown"
        case .copy: "copy"
        }
    }
}


extension ValueFlowSolver {
    /// 호출 없는 요약은 즉시 계산해 긴 순차 호출에서 호출자 앞부분을 반복 평가하지 않는다.
    /// 내부/간접 호출과 접근자는 작업 목록에 남겨 Swift 재귀 스택을 쓰지 않는다.
    func canEvaluateImmediately(_ function: ValueFlowFunction) -> Bool {
        if let cached = immediateFunctions[function.id] { return cached }
        let instructions = function.blocks.flatMap(\.instructions)
        let byID = Dictionary(instructions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var immediate = true
        for instruction in instructions {
            switch instruction.operation {
            case .member: immediate = false
            case let .symbol(reference):
                if let usr = reference.usr, fieldByUSR[usr] != nil { immediate = false }
            case let .call(callee, _, _, _):
                var id = callee
                var seen: Set<Int> = []
                while let node = byID[id], seen.insert(id).inserted {
                    switch node.operation {
                    case let .read(address): id = address; continue
                    case let .copy(source): id = source; continue
                    default: break
                    }
                    break
                }
                if let node = byID[id], case let .symbol(reference) = node.operation,
                   let usr = reference.usr, functionByUSR[usr] == nil, fieldByUSR[usr] == nil {
                    break
                }
                immediate = false
            default: break
            }
            if !immediate { break }
        }
        immediateFunctions[function.id] = immediate
        return immediate
    }
}
