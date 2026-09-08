import CartographCore

/// 호출별 입력과 메모리를 고정점으로 풀어 값 그래프를 만든다. I/O나 인덱스 조회는 하지 않는다.
public struct ValueFlowAnalyzer: Sendable {
    public let limits: ValueFlowLimits

    /// 분석마다 독립적인 예산을 적용하고 요약 캐시를 공유하지 않는다.
    public init(limits: ValueFlowLimits = ValueFlowLimits()) { self.limits = limits }

    /// roots를 명시하면 그 함수의 미상 입력에서 분석한다. 기본값은 프로그램의 알려진 진입점이다.
    public func analyze(_ program: ValueFlowProgram, roots: [String]? = nil) -> ValueFlowGraph {
        ValueFlowSolver(program: program, limits: limits).solve(roots: roots)
    }
}

/// 재귀 호출은 Swift 스택 재귀가 아니라 문맥 작업 목록과 의존자 갱신으로 해결한다.
final class ValueFlowSolver {
    let program: ValueFlowProgram
    let limits: ValueFlowLimits
    let functions: [String: ValueFlowFunction]
    let functionByUSR: [String: String]
    let fields: [String: ValueFlowField]
    let fieldByUSR: [String: String]
    let types: [String: ValueFlowType]
    let typeByUSR: [String: String]
    var contexts: [FlowContext] = []
    var contextByKey: [FlowContextKey: Int] = [:]
    var dependents: [Int: Set<Int>] = [:]
    var queue: [Int] = []
    var queued: Set<Int> = []
    var cursor = 0
    var iterations = 0
    var truncated = false
    var limitations: Set<String>
    var closures: [String: FlowClosure] = [:]
    var boundFields: [String: FlowBoundField] = [:]
    var repeatedBlocksByFunction: [String: Set<Int>] = [:]
    var immediateFunctions: [String: Bool] = [:]
    var closureIDs: [FlowClosure: String] = [:]
    var activeContext = 0
    var activeBlockRepeated = false
    var activeEdges: Set<ValueFlowGraphEdge> = []
    var activeNodes: [Int: ValueFlowGraphNode] = [:]

    init(program: ValueFlowProgram, limits: ValueFlowLimits) {
        self.program = program
        self.limits = limits
        functions = Dictionary(program.functions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        fields = Dictionary(program.fields.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        types = Dictionary(program.types.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        functionByUSR = Dictionary(program.functions.compactMap { function in
            function.symbolUSR.map { ($0, function.id) }
        }, uniquingKeysWith: { first, _ in first })
        fieldByUSR = Dictionary(program.fields.compactMap { field in field.symbolUSR.map { ($0, field.id) } },
                                uniquingKeysWith: { first, _ in first })
        typeByUSR = Dictionary(program.types.compactMap { type in type.symbolUSR.map { ($0, type.id) } },
                               uniquingKeysWith: { first, _ in first })
        limitations = Set(program.limitations)
    }

    func solve(roots: [String]?) -> ValueFlowGraph {
        let selected: [ValueFlowFunction]
        if let roots {
            selected = roots.compactMap { functions[$0] }.sorted { $0.id < $1.id }
        } else {
            let entries = functions.values.filter { $0.isEntryPoint || $0.mayBeCalledExternally }
            selected = entries.sorted { $0.id < $1.id }
        }
        if selected.isEmpty { limitations.insert("no-entry-contexts") }
        for function in selected {
            var state = FlowState()
            for field in fields.values where field.ownerType == nil || field.isStatic {
                let address = bindField(field, receiver: nil, object: nil)
                state.memory[address] = FlowCell(value: ValueFlowValue(), mutable: field.isMutable,
                                                 unique: true, initialized: false, definitions: nil)
                if (roots != nil || !function.isEntryPoint) && !isImmutableLiteral(field) {
                    state.memory[address]?.value = .unknown("external-entry-state")
                    state.memory[address]?.initialized = true
                }
            }
            let args = function.parameters.indices.map { index -> ValueFlowValue in
                let value = ValueFlowValue.unknown("entry-parameter", origins: [ValueFlowOrigin(
                    id: "parameter:\(function.id):\(index)", location: function.location
                )])
                if function.parameters[index].isInout {
                    let address = "entry:\(function.id):\(index)"
                    state.memory[address] = FlowCell(value: value, mutable: true, unique: true,
                                                     initialized: true, definitions: nil)
                    return ValueFlowValue(atoms: [.reference(address)])
                }
                return value
            }
            _ = request(function: function.id, arguments: args, captures: [], receiver: nil,
                        state: state, call: nil, caller: nil,
                        reason: roots == nil ? "entry" : "requested", calls: [], repeated: false)
        }
        while cursor < queue.count && iterations < limits.iterations {
            let index = queue[cursor]
            cursor += 1
            guard queued.remove(index) != nil else { continue }
            iterations += 1
            evaluate(index)
        }
        if cursor < queue.count {
            truncated = true
            limitations.insert("iteration-budget")
            // 고정점이 완성되지 않으면 알려진 값만 보이더라도 확정값으로 내보내지 않는다.
            for index in contexts.indices {
                contexts[index].summary.value.unknownReasons.insert("iteration-budget")
                for nodeID in contexts[index].nodes.keys {
                    guard let node = contexts[index].nodes[nodeID] else { continue }
                    var value = node.value
                    value.unknownReasons.insert("iteration-budget")
                    contexts[index].nodes[nodeID] = ValueFlowGraphNode(id: node.id, context: node.context,
                        function: node.function, instruction: node.instruction, kind: node.kind,
                        location: node.location, value: value)
                }
            }
        }
        return graph()
    }

    /// 실행 순서에 의존하지 않는 불변 리터럴 초기화만 외부 진입에서도 유지한다.
    func isImmutableLiteral(_ field: ValueFlowField) -> Bool {
        guard !field.isMutable, !field.hasUnknownObservers, field.getter == nil,
              let id = field.initializer, let function = functions[id], function.unavailableReason == nil,
              function.blocks.count == 1, let block = function.blocks.first,
              case let .return(result) = block.terminator, let result else { return false }
        return block.instructions.contains { $0.id == result }
            && block.instructions.allSatisfy { if case .literal = $0.operation { return true }; return false }
    }

    func schedule(_ index: Int) {
        if queued.insert(index).inserted { queue.append(index) }
    }

    func request(function: String, arguments: [ValueFlowValue], captures: [ValueFlowValue],
                 receiver: ValueFlowValue?, state: FlowState, call: SourceLocation?, caller: Int?,
                 reason: String, calls: [String], repeated: Bool) -> Int? {
        let globalValues = state.memory.filter { $0.key.hasPrefix("global:") || state.escaped.contains($0.key) }
            .map { $0.value.value }
        let seeds = arguments + captures + (receiver.map { [$0] } ?? []) + globalValues
        let relevant = reachableMemory(from: seeds, in: state)
        var memory = state.memory.filter { relevant.contains($0.key) || $0.key.hasPrefix("global:") }
        // 호출 대상이 닿을 수 없는 호출자의 지역 상태는 요약 입력에 섞지 않는다.
        for key in state.escaped where state.memory[key] != nil { memory[key] = state.memory[key] }
        if memory.count > limits.heapCells {
            truncated = true
            limitations.insert("heap-budget")
            return nil
        }
        let definitions = memory.compactMapValues { cell in cell.definitions }
        // 도달 경로 ID는 값 의미가 아니다. 메모리 쓰기 노드가 달라졌다고 새 문맥을 계속 만들지 않는다.
        memory = memory.mapValues { cell in var copy = cell; copy.definitions = nil; return copy }
        let key = FlowContextKey(function: function, calls: Array(calls.suffix(limits.callStringDepth)),
                                 arguments: arguments, captures: captures, receiver: receiver,
                                 memory: memory, escaped: state.escaped, repeated: repeated || calls.count > limits.callStringDepth)
        if let index = contextByKey[key] {
            if let caller { dependents[index, default: []].insert(caller) }
            let old = contexts[index].inputDefinitions
            for (address, incoming) in definitions {
                contexts[index].inputDefinitions[address, default: []].formUnion(incoming)
            }
            if old != contexts[index].inputDefinitions { schedule(index) }
            return index
        }
        guard contexts.count < limits.contexts else {
            truncated = true
            limitations.insert("context-budget")
            return nil
        }
        let index = contexts.count
        var context = FlowContext(id: "c\(index)", key: key, callSite: call,
                                  caller: caller.map { contexts[$0].id }, reason: reason)
        context.inputDefinitions = definitions
        contexts.append(context)
        contextByKey[key] = index
        if let caller { dependents[index, default: []].insert(caller) }
        schedule(index)
        return index
    }

    func graph() -> ValueFlowGraph {
        let resultContexts = contexts.enumerated().map { index, context in
            ValueFlowContextResult(id: context.id, function: context.key.function,
                symbolUSR: functions[context.key.function]?.symbolUSR, callSite: context.callSite,
                caller: context.caller, reason: context.reason, arguments: context.key.arguments,
                result: context.summary.value, mayReturn: context.summary.mayReturn,
                callers: dependents[index, default: []].map { contexts[$0].id }, effects: effects(context))
        }.sorted { $0.id < $1.id }
        let nodes = contexts.flatMap { $0.nodes.values }.sorted { $0.id < $1.id }
        let nodeIDs = Set(nodes.map(\.id))
        let edges = Set(contexts.flatMap { $0.edges }).filter {
            nodeIDs.contains($0.source) && nodeIDs.contains($0.target)
        }.sorted {
            if $0.source != $1.source { return $0.source < $1.source }
            if $0.target != $1.target { return $0.target < $1.target }
            return $0.kind < $1.kind
        }
        return ValueFlowGraph(contexts: resultContexts, nodes: nodes, edges: edges,
                              limitations: limitations.sorted(), iterations: iterations, truncated: truncated)
    }

    func effects(_ context: FlowContext) -> [ValueFlowMemoryEffect] {
        context.summary.memory.compactMap { address, cell in
            let before = context.key.memory[address]
            let escaped = context.summary.escaped.contains(address)
            guard before?.value != cell.value || before?.initialized != cell.initialized
                || (escaped && !context.key.escaped.contains(address)) else { return nil }
            return ValueFlowMemoryEffect(address: address,
                fieldUSR: boundFields[address].flatMap { fields[$0.field]?.symbolUSR },
                before: before?.value, after: cell.value, escaped: escaped)
        }.sorted { $0.address < $1.address }
    }

    func nodeID(_ instruction: Int, context: Int? = nil) -> String {
        "\(contexts[context ?? activeContext].id):n\(instruction)"
    }

    func functionValue(_ frame: FlowClosure) -> ValueFlowValue {
        if let id = closureIDs[frame] { return ValueFlowValue(atoms: [.function(id)]) }
        let id = "f\(closures.count)"
        closures[id] = frame
        closureIDs[frame] = id
        return ValueFlowValue(atoms: [.function(id)])
    }

    func value(_ id: Int, in state: FlowState) -> ValueFlowValue { state.values[id] ?? ValueFlowValue() }

    func edge(_ source: Int, to target: Int, kind: String = "value") {
        activeEdges.insert(ValueFlowGraphEdge(source: nodeID(source), target: nodeID(target), kind: kind))
    }
}
