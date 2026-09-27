import CartographCore

/// 다중 root 순회의 방향. isthmus `language-traversal` 계약의 `direction` 값과 같다.
public enum TraversalDirection: String, Sendable, Equatable, CaseIterable {
    /// root 에 기대는 쪽(호출자·참조자). `change-impact` 와 같은 방향이다.
    case dependents
    /// root 가 기대는 쪽(피호출자·참조 대상).
    case dependencies
}

/// 경로 근거 등급. 간선 집합이 `direct ⊂ bound ⊂ candidate` 로 포개진다.
///
/// 컴파일러가 해석한 간선만 `direct` 다. 오버라이드·프로토콜 dispatch 투영은 실제로 어느
/// 구현이 불릴지 모르므로 `candidate` 이고, 전체 프로그램에서 구현이 하나뿐임을 입증할 때만
/// `bound` 로 올린다. 소비자가 "닿는다"와 "닿을 수도 있다"를 구분하게 하려는 값이다.
public enum TraversalEvidence: String, Sendable, Equatable, Comparable, CaseIterable {
    case direct
    case bound
    case candidate

    /// 약할수록 큰 값. 경로 등급은 간선 중 가장 약한 것, 정점 등급은 root 별 최강 중 가장 약한 것이다.
    var weakness: Int {
        switch self {
        case .direct: 0
        case .bound: 1
        case .candidate: 2
        }
    }

    public static func < (lhs: TraversalEvidence, rhs: TraversalEvidence) -> Bool {
        lhs.weakness < rhs.weakness
    }
}

/// 순회가 한 걸음에 쓰는 파생 간선. 같은 두 정점 사이의 여러 근거를 하나로 합친 것이다.
///
/// `evidence` 는 그 쌍을 잇는 근거 중 가장 강한 등급이다(도달 판단용). `relationship`·`edges`·
/// `dispatchContract` 는 `change-impact` 와 같은 우선순위로 고른 대표 근거다(설명용). 둘을
/// 한 근거에서 고르면 강한 근거가 있는데도 설명 우선순위가 약한 근거를 골라 등급이 떨어진다.
public struct TraversalHop: Sendable, Equatable {
    /// 한 걸음 더 나아간 정점.
    public let target: NodeID
    /// 이 쌍을 잇는 가장 강한 근거 등급.
    public let evidence: TraversalEvidence
    /// 대표 근거의 의미(`dependent`·`dispatchCaller`·`automaticRuntime` 등).
    public let relationship: String
    /// 대표 근거를 이루는 간선 종류. 정렬되어 있다.
    public let edges: [EdgeKind]
    /// dispatch 투영이면 그 계약 정점.
    public let dispatchContract: NodeID?
}

/// 그래프 간선에서 순회용 파생 간선을 만든다.
///
/// 역방향(`dependents`)은 `ImpactAnalyzer` 와 **같은 관계**를 쓴다 — incoming 사용 간선,
/// 구현체에서 계약 호출자로의 dispatch 투영, 자동 발견 런타임 연결. 그래야 한 번의 다중 root
/// 순회가 root 별 `change-impact` 와 같은 도달 집합을 낸다. 정방향(`dependencies`)은 그
/// 관계를 정확히 뒤집은 것이다(호출자 → 계약 → 구현). 계약 정점을 거쳐 형제 구현으로 번지지
/// 않도록 투영은 계약을 건너뛰어 호출자와 구현을 곧바로 잇는다.
public struct TraversalHopGenerator: Sendable {
    let graph: CodeGraph
    let direction: TraversalDirection
    let closedWorld: Bool
    private let runtimeBySource: [NodeID: [ImpactDependency]]
    private let runtimeByTarget: [NodeID: [ImpactDependency]]

    /// - Parameters:
    ///   - graph: 소비자 → 피소비자 방향의 심볼 그래프.
    ///   - direction: 순회 방향.
    ///   - closedWorld: 인덱스가 프로젝트 전체를 빠짐없이 담는다고 볼 수 있는지. 거짓이면
    ///     구현이 하나뿐이라는 증명이 성립하지 않으므로 `bound` 를 내지 않는다.
    ///   - runtimeDependencies: 자동 발견한 런타임 연결. 컴파일러 간선이 아니므로 `candidate` 다.
    public init(
        graph: CodeGraph, direction: TraversalDirection, closedWorld: Bool,
        runtimeDependencies: [ImpactDependency] = []
    ) {
        self.graph = graph
        self.direction = direction
        self.closedWorld = closedWorld
        let usable = runtimeDependencies.filter {
            $0.source != $0.target && graph.contains($0.source) && graph.contains($0.target)
        }
        runtimeBySource = Dictionary(grouping: usable, by: \.source)
        runtimeByTarget = Dictionary(grouping: usable, by: \.target)
    }

    /// `node` 에서 한 걸음 나아가는 파생 간선. 대상 정점 순으로 정렬되어 있다.
    public func hops(from node: NodeID) -> [TraversalHop] {
        var merger = HopMerger()
        switch direction {
        case .dependents:
            merger.add(dependentUsageHops(of: node))
            merger.add(dispatchCallerHops(of: node))
            merger.add(runtimeHops(runtimeByTarget[node] ?? [], endpoint: \.source))
        case .dependencies:
            merger.add(dependencyUsageHops(of: node))
            merger.add(dispatchTargetHops(of: node))
            merger.add(runtimeHops(runtimeBySource[node] ?? [], endpoint: \.target))
        }
        return merger.merged()
    }

    /// 구현이 하나뿐이라는 증명이 닫힌 세계 가정 때문에 막혔는지. 한계 문구를 위해 센다.
    public func isBoundBlockedByOpenWorld(contract: NodeID, implementation: NodeID) -> Bool {
        !closedWorld && provesUniqueImplementation(contract: contract, implementation: implementation)
    }

    // MARK: - 역방향

    /// incoming 사용 간선의 출발점. 오버라이드가 섞이면 계약 변경이 구현에 닿는 관계다.
    private func dependentUsageHops(of node: NodeID) -> [TraversalHop] {
        let bySource = Dictionary(grouping: graph.incomingEdges(to: node).filter(\.kind.impliesUsage), by: \.source)
        return bySource.map { source, edges in
            let kinds = Self.sortedKinds(edges.map(\.kind))
            return TraversalHop(target: source, evidence: .direct,
                relationship: kinds.contains(.overrides) ? "dispatchContract" : "dependent",
                edges: kinds, dispatchContract: nil)
        }
    }

    /// 구현체가 속한 계약(오버라이드 사슬 전체)의 일반 호출자. 계약 정점 자체는 싣지 않는다.
    private func dispatchCallerHops(of node: NodeID) -> [TraversalHop] {
        upwardContracts(of: node).flatMap { contract in
            let callers = Dictionary(grouping: contractCallerEdges(of: contract), by: \.source)
            let evidence = dispatchEvidence(contract: contract, implementation: node)
            return callers.map { source, edges in
                TraversalHop(target: source, evidence: evidence, relationship: "dispatchCaller",
                    edges: Self.sortedKinds(edges.map(\.kind) + [.overrides]), dispatchContract: contract)
            }
        }
    }

    // MARK: - 정방향

    /// outgoing 사용 간선의 도착점. 오버라이드면 도착점이 이 선언의 계약이다.
    private func dependencyUsageHops(of node: NodeID) -> [TraversalHop] {
        let byTarget = Dictionary(grouping: graph.outgoingEdges(from: node).filter(\.kind.impliesUsage), by: \.target)
        return byTarget.map { target, edges in
            let kinds = Self.sortedKinds(edges.map(\.kind))
            return TraversalHop(target: target, evidence: .direct,
                relationship: kinds.contains(.overrides) ? "dispatchContract" : "dependency",
                edges: kinds, dispatchContract: nil)
        }
    }

    /// 이 선언이 부르는 계약의 구현(오버라이드 사슬 아래 전체). `dispatchCallerHops` 의 역관계다.
    private func dispatchTargetHops(of node: NodeID) -> [TraversalHop] {
        let calls = graph.outgoingEdges(from: node).filter { edge in
            edge.kind.impliesUsage && edge.kind != .overrides && !isProtocolSelfCall(edge)
        }
        return Dictionary(grouping: calls, by: \.target).flatMap { contract, edges in
            downwardImplementations(of: contract).map { implementation in
                TraversalHop(target: implementation,
                    evidence: dispatchEvidence(contract: contract, implementation: implementation),
                    relationship: "dispatchTarget",
                    edges: Self.sortedKinds(edges.map(\.kind) + [.overrides]), dispatchContract: contract)
            }
        }
    }

    // MARK: - 런타임

    /// 자동 발견한 런타임 연결. 이름 대조로 만든 가능성이므로 `candidate` 다.
    private func runtimeHops(
        _ dependencies: [ImpactDependency], endpoint: KeyPath<ImpactDependency, NodeID>
    ) -> [TraversalHop] {
        Set(dependencies.map { $0[keyPath: endpoint] }).map {
            TraversalHop(target: $0, evidence: .candidate, relationship: "automaticRuntime",
                edges: [], dispatchContract: nil)
        }
    }

    // MARK: - dispatch 근거

    /// 구현에서 오버라이드 사슬을 따라 올라간 계약들. 순환은 방문 집합으로 끊는다.
    private func upwardContracts(of node: NodeID) -> [NodeID] {
        closure(from: node) { current in
            graph.outgoingEdges(from: current).filter { $0.kind == .overrides }.map(\.target)
        }
    }

    /// 계약에서 오버라이드 사슬을 따라 내려간 구현들.
    private func downwardImplementations(of contract: NodeID) -> [NodeID] {
        closure(from: contract) { current in
            graph.incomingEdges(to: current).filter { $0.kind == .overrides }.map(\.source)
        }
    }

    /// 시작 정점을 뺀 전이 폐포. 결정적 순서를 위해 정렬해 돌려준다.
    private func closure(from start: NodeID, next: (NodeID) -> [NodeID]) -> [NodeID] {
        var seen: Set<NodeID> = [start]
        var queue = [start]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for candidate in next(current) where seen.insert(candidate).inserted { queue.append(candidate) }
        }
        return queue.dropFirst().sorted()
    }

    /// 계약을 부르는 일반 사용 간선. 프로토콜이 자기 요구사항을 부르는 컴파일러 간선은 뺀다.
    ///
    /// 프로토콜에는 본문이 없으므로 그 간선을 구현의 호출자로 투영하면 프로토콜 타입을 거쳐
    /// 무관한 모든 준수 타입으로 번진다(`ImpactAnalyzer` 와 같은 규칙).
    private func contractCallerEdges(of contract: NodeID) -> [GraphEdge] {
        graph.incomingEdges(to: contract).filter { edge in
            edge.kind.impliesUsage && edge.kind != .overrides && !isProtocolSelfCall(edge)
        }
    }

    private func isProtocolSelfCall(_ edge: GraphEdge) -> Bool {
        graph.node(edge.source)?.kind == .protocolType && graph.semanticParent(of: edge.target) == edge.source
    }

    /// dispatch 투영 한 걸음의 등급. 구현이 하나뿐임을 닫힌 세계에서 입증할 때만 `bound` 다.
    private func dispatchEvidence(contract: NodeID, implementation: NodeID) -> TraversalEvidence {
        closedWorld && provesUniqueImplementation(contract: contract, implementation: implementation)
            ? .bound : .candidate
    }

    /// 계약 호출이 반드시 이 구현으로 가는지.
    ///
    /// 조건은 좁게 잡는다. 계약이 프로토콜 요구사항이고(클래스 메서드는 기반 본문도 불릴 수
    /// 있다), 구현이 계약을 곧바로 오버라이드하며(사슬이 아니다), 그 계약의 구현이 이것 하나뿐이고,
    /// 프로토콜을 준수하는 타입도 구현을 품은 타입 하나뿐이어야 한다. 준수 타입이 둘이면
    /// 기본 구현(프로토콜 익스텐션)을 쓰는 다른 타입으로 호출이 갈 수 있다.
    private func provesUniqueImplementation(contract: NodeID, implementation: NodeID) -> Bool {
        let implementations = graph.incomingEdges(to: contract).filter { $0.kind == .overrides }.map(\.source)
        guard Set(implementations) == [implementation],
              graph.outgoingEdges(from: contract).allSatisfy({ $0.kind != .overrides }),
              let owner = graph.semanticParent(of: contract), graph.node(owner)?.kind == .protocolType
        else { return false }
        let conformers = Set(graph.incomingEdges(to: owner)
            .filter { $0.kind == .conformance || $0.kind == .inheritance }
            .map { extendedType(of: $0.source) })
        guard conformers.count == 1, let conformer = conformers.first,
              graph.node(conformer)?.kind != .protocolType else { return false }
        return graph.semanticParent(of: implementation) == conformer
    }

    /// 익스텐션으로 쓴 준수는 확장 대상 타입의 준수로 읽는다.
    private func extendedType(of node: NodeID) -> NodeID {
        guard graph.node(node)?.kind == .extensionDeclaration else { return node }
        return graph.outgoingEdges(from: node).first { $0.kind == .extends }?.target ?? node
    }

    static func sortedKinds(_ kinds: [EdgeKind]) -> [EdgeKind] {
        Set(kinds).sorted { $0.rawValue < $1.rawValue }
    }
}

/// 같은 대상의 파생 간선을 하나로 합친다.
private struct HopMerger {
    private var byTarget: [NodeID: TraversalHop] = [:]

    mutating func add(_ hops: [TraversalHop]) {
        for hop in hops { merge(hop) }
    }

    /// 등급은 가장 강한 것, 설명은 `change-impact` 우선순위로 앞선 것을 남긴다.
    private mutating func merge(_ hop: TraversalHop) {
        guard let existing = byTarget[hop.target] else {
            byTarget[hop.target] = hop
            return
        }
        let display = Self.precedes(hop, existing) ? hop : existing
        byTarget[hop.target] = TraversalHop(target: hop.target, evidence: min(hop.evidence, existing.evidence),
            relationship: display.relationship, edges: display.edges, dispatchContract: display.dispatchContract)
    }

    func merged() -> [TraversalHop] {
        byTarget.values.sorted { $0.target < $1.target }
    }

    /// `ImpactAnalyzer` 의 후보 우선순위(관계 순위 → 간선 종류 → 계약)와 같다.
    static func precedes(_ lhs: TraversalHop, _ rhs: TraversalHop) -> Bool {
        let (left, right) = (relationshipRank(lhs.relationship), relationshipRank(rhs.relationship))
        if left != right { return left < right }
        let (leftKinds, rightKinds) = (lhs.edges.map(\.rawValue), rhs.edges.map(\.rawValue))
        if leftKinds != rightKinds { return leftKinds.lexicographicallyPrecedes(rightKinds) }
        switch (lhs.dispatchContract, rhs.dispatchContract) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (left?, right?): return left < right
        }
    }

    private static func relationshipRank(_ relationship: String) -> Int {
        switch relationship {
        case "dependent", "dependency": 0
        case "dispatchContract": 1
        case "dispatchCaller", "dispatchTarget": 2
        default: 3
        }
    }
}
