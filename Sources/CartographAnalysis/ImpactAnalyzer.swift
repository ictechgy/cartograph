import CartographCore

/// 컴파일러 근거와 디스패치 가능성·사용자 선언 계약을 서로 다른 관계로 보존한다.
public enum ImpactRelationship: String, Sendable, Equatable, Codable {
    case dependent
    case dispatchContract
    case dispatchCaller
    case runtimeContract
    case automaticRuntime
    case observedRuntime
}

/// 정적 간선 밖에서 선언한 동적 연결. 실행이 관측됐다는 의미로 바꾸지 않는다.
public struct ImpactDependency: Sendable, Equatable {
    public let source: NodeID
    public let target: NodeID
    public let contract: String
    public let origin: RuntimeEvidenceOrigin
    public let kind: RuntimeBoundaryKind?

    /// 양쪽 선언이 검증된 런타임 계약을 영향 탐색에 연결한다.
    public init(source: NodeID, target: NodeID, contract: String,
                origin: RuntimeEvidenceOrigin = .declared, kind: RuntimeBoundaryKind? = nil) {
        self.source = source
        self.target = target
        self.contract = contract
        self.origin = origin
        self.kind = kind
    }
}

/// 변경한 정점에서 영향을 받을 수 있는 정점 하나와 그 근거.
public struct ImpactVisit: Sendable, Equatable {
    /// 영향을 받을 수 있는 정점.
    public let node: NodeID
    /// 변경한 정점에서 이 정점까지의 최소 영향 단계.
    public let depth: Int
    /// 이 정점을 처음 발견하게 한 바로 앞 정점.
    public let via: NodeID
    /// 영향이 생긴 관계의 의미. 출력에 쓰이는 값은 영어로 고정한다.
    public let relationship: ImpactRelationship
    /// 선택된 근거를 이루는 간선 종류. 디스패치 투영에는 계약으로 향하는 overrides도 포함된다.
    public let edges: [EdgeKind]
    /// 프로토콜 요구사항 또는 상위 선언을 통한 호출이면 그 계약 정점.
    ///
    /// 이 값은 `node` 로 가는 합성 경로의 근거를 보존한다. 계약 정점 자체를
    /// 영향 목록에 넣으면 변경한 witness 와 같은 계약의 다른 witness 를 잘못
    /// 전파할 수 있으므로, 계약은 연결자로만 남긴다.
    public let dispatchContract: NodeID?
    public let runtimeContracts: [String]
    public let runtimeEvidence: [RuntimeEvidenceReference]

    /// 영향 방문 하나를 만든다.
    public init(
        node: NodeID,
        depth: Int,
        via: NodeID,
        relationship: ImpactRelationship,
        edges: [EdgeKind],
        dispatchContract: NodeID? = nil,
        runtimeContracts: [String] = [], runtimeEvidence: [RuntimeEvidenceReference] = []
    ) {
        self.node = node
        self.depth = depth
        self.via = via
        self.relationship = relationship
        self.edges = edges
        self.dispatchContract = dispatchContract
        self.runtimeContracts = runtimeContracts
        self.runtimeEvidence = runtimeEvidence
    }
}

/// 변경 정점에서 전이적으로 영향을 받을 수 있는 범위를 담는다.
public struct ImpactReport: Sendable, Equatable {
    /// 분석에 사용한 변경 정점. 입력 순서와 무관하게 정렬되어 있다.
    public let changed: [NodeID]
    /// 변경 정점을 제외한 영향 정점. 깊이와 정점 식별자로 정렬되어 있다.
    public let affected: [ImpactVisit]
    /// 깊이 상한 때문에 아직 확인하지 못한 영향 정점이 있는지 여부.
    public let truncatedByDepth: Bool

    /// 영향 분석 결과를 만든다.
    public init(changed: [NodeID], affected: [ImpactVisit], truncatedByDepth: Bool) {
        self.changed = changed
        self.affected = affected
        self.truncatedByDepth = truncatedByDepth
    }
}

/// 변경된 선언의 잠재적 소비자를 그래프에서 계산한다.
///
/// 그래프의 방향은 소비자에서 피소비자로 향하므로, 일반 영향은 incoming
/// 간선을 거꾸로 걷는다. 이 타입은 파일이나 인덱스 스토어를 읽지 않으며,
/// 호출자가 준비한 `CodeGraph` 만 사용해 반복 질의와 CI 재사용을 가능하게 한다.
public struct ImpactAnalyzer: Sendable {
    /// 영향 분석기를 만든다.
    public init() {}

    /// 변경 정점에서 영향을 받을 수 있는 소비자를 계산한다.
    ///
    /// 일반 간선은 사용 의미가 있는 incoming 간선만 따라간다. 포함(`member`)
    /// 간선은 사용이 아니므로 제외한다. 오버라이드 간선은 두 방향을 별도로
    /// 다룬다. 실제 계약 정점이 변경되면 incoming 오버라이드로 구현체들을
    /// 찾고, 구현체가 변경되면 outgoing 오버라이드가 가리키는 계약의 일반
    /// 호출자만 투영해 찾는다. 후자의 계약 정점과 형제 구현체는 결과 정점이
    /// 아니라 근거 연결자이므로 영향 목록에 넣지 않는다.
    ///
    /// 깊이 상한은 결과 정점의 최대 단계다. 상한 단계의 정점까지는 포함하고,
    /// 그 너머에 아직 방문하지 않은 후보가 있을 때만 `truncatedByDepth` 를
    /// 세운다. 이미 방문한 정점으로 향하는 순환 간선만 남았으면 잘린 것으로
    /// 표시하지 않는다.
    ///
    /// - Parameters:
    ///   - changing: 변경된 정점들의 식별자.
    ///   - graph: 소비자에서 피소비자로 향하는 의존성 그래프.
    ///   - maxDepth: 결과에 포함할 최대 단계. `nil`이면 제한이 없다. 음수는
    ///     변경 정점만 허용하는 0단계로 취급한다.
    /// - Returns: 변경 정점과 결정적인 순서의 영향 방문 목록.
    public func analyze(
        changing: Set<NodeID>,
        in graph: CodeGraph,
        maxDepth: Int? = nil,
        additionalDependencies: [ImpactDependency] = []
    ) -> ImpactReport {
        let changed = changing.sorted()
        let changedSet = Set(changed)
        let depthLimit = maxDepth.map { max(0, $0) }

        var visited = changedSet
        var frontier = graph.nodeIDs.filter { changedSet.contains($0) }
        var depth = 0
        var visits: [NodeID: ImpactVisit] = [:]
        var truncated = false
        var projectedContracts: [NodeID: Int] = [:]
        let runtime = Dictionary(grouping: additionalDependencies.filter {
            graph.contains($0.source) && graph.contains($0.target)
        }, by: \.target)

        while !frontier.isEmpty {
            let currentDepth = depth
            let candidates = frontierCandidates(
                from: frontier,
                depth: currentDepth,
                visited: visited,
                graph: graph,
                projectedContracts: &projectedContracts,
                runtime: runtime
            )

            if let depthLimit, currentDepth >= depthLimit {
                truncated = truncated || candidates.contains { !visited.contains($0.node) }
                break
            }

            var bestByNode: [NodeID: Candidate] = [:]
            for candidate in candidates where !visited.contains(candidate.node) {
                if let best = bestByNode[candidate.node] {
                    if candidate.precedes(best) {
                        bestByNode[candidate.node] = candidate
                    }
                } else {
                    bestByNode[candidate.node] = candidate
                }
            }

            guard !bestByNode.isEmpty else { break }

            let next = bestByNode.keys.sorted()
            for node in next {
                guard let candidate = bestByNode[node] else { continue }
                visited.insert(node)
                visits[node] = candidate.visit
            }
            frontier = next
            depth += 1
        }

        return ImpactReport(
            changed: changed,
            affected: visits.values.sorted(by: Self.visitPrecedes),
            truncatedByDepth: truncated
        )
    }

    // MARK: - 후보 생성

    /// 한 BFS 층에서 일반 소비자와 dispatch 투영 후보를 만든다.
    private func frontierCandidates(
        from frontier: [NodeID],
        depth: Int,
        visited: Set<NodeID>,
        graph: CodeGraph,
        projectedContracts: inout [NodeID: Int],
        runtime: [NodeID: [ImpactDependency]]
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        for current in frontier.sorted() {
            candidates += incomingCandidates(
                for: current,
                depth: depth + 1,
                visited: visited,
                graph: graph
            )
            candidates += dispatchCandidates(
                from: current,
                depth: depth + 1,
                visited: visited,
                graph: graph,
                projectedContracts: &projectedContracts
            )
            let supplemental = Dictionary(grouping: runtime[current] ?? [], by: \.source)
            for source in supplemental.keys.sorted() where !visited.contains(source) {
                let dependencies = supplemental[source] ?? []
                let evidence = Set(dependencies.filter { $0.origin != .declared }.map {
                    RuntimeEvidenceReference(id: $0.contract, origin: $0.origin, kind: $0.kind)
                }).sorted { ($0.origin.rawValue, $0.id) < ($1.origin.rawValue, $1.id) }
                let relationship: ImpactRelationship = evidence.contains { $0.origin == .observed }
                    ? .observedRuntime : (evidence.isEmpty ? .runtimeContract : .automaticRuntime)
                candidates.append(Candidate(node: source, visit: ImpactVisit(
                    node: source, depth: depth + 1, via: current, relationship: relationship,
                    edges: [], runtimeContracts: Set(dependencies.filter { $0.origin == .declared }.map(\.contract)).sorted(),
                    runtimeEvidence: evidence
                )))
            }
        }
        return candidates
    }

    /// 현재 정점의 incoming 사용 간선에서 소비자 후보를 만든다.
    private func incomingCandidates(
        for current: NodeID,
        depth: Int,
        visited: Set<NodeID>,
        graph: CodeGraph
    ) -> [Candidate] {
        var edgesBySource: [NodeID: [GraphEdge]] = [:]
        for edge in graph.incomingEdges(to: current) where edge.kind.impliesUsage {
            guard !visited.contains(edge.source) else { continue }
            edgesBySource[edge.source, default: []].append(edge)
        }

        return edgesBySource.keys.sorted().compactMap { source in
            guard let edges = edgesBySource[source] else { return nil }
            let kinds = edges.map(\.kind).sorted { $0.rawValue < $1.rawValue }
            let isDispatch = edges.contains { $0.kind == .overrides }
            let relationship: ImpactRelationship = isDispatch ? .dispatchContract : .dependent
            return Candidate(
                node: source,
                visit: ImpactVisit(
                    node: source,
                    depth: depth,
                    via: current,
                    relationship: relationship,
                    edges: kinds,
                    dispatchContract: nil
                )
            )
        }
    }

    /// 현재 구현체가 속한 계약의 일반 호출자를 투영한다.
    ///
    /// incoming 오버라이드 간선을 이 자리에서 걷지 않는 것이 핵심이다. 그
    /// 간선을 따라가면 변경된 witness 와 같은 계약을 구현하는 형제 witness 를
    /// 영향 정점으로 잘못 보고하게 된다.
    private func dispatchCandidates(
        from current: NodeID,
        depth: Int,
        visited: Set<NodeID>,
        graph: CodeGraph,
        projectedContracts: inout [NodeID: Int]
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        var pending = graph.outgoingEdges(from: current)
            .filter { $0.kind == .overrides }
            .map { DispatchPath(contract: $0.target) }
        var pendingIndex = 0
        var seenContracts: Set<NodeID> = []

        while pendingIndex < pending.count {
            let path = pending[pendingIndex]
            pendingIndex += 1
            guard seenContracts.insert(path.contract).inserted else { continue }

            // 같은 계약을 구현하는 witness 가 많으면 계약 호출자 목록은 모두
            // 동일하다. 가장 얕은 층에서 한 번만 투영해야 W 개 witness 와 C 개
            // 호출자에 대해 W×C 스캔이 생기지 않는다. 같은 층에서는 frontier 가
            // NodeID 순으로 정렬되어 있어 첫 witness 가 결정적인 부모가 된다.
            let previousDepth = projectedContracts[path.contract]
            let shouldProject = previousDepth.map { $0 > depth } ?? true
            if shouldProject {
                projectedContracts[path.contract] = depth
                candidates += projectedCallers(
                    of: path.contract,
                    from: current,
                    depth: depth,
                    visited: visited,
                    in: graph
                )

                // 계약을 한 번 확장했다면 이후 witness 는 같은 계약의 상위
                // 선언을 다시 걷지 않는다. 첫 확장은 BFS 깊이와 정렬 순서가
                // 정하므로 상위 계약의 근거도 결정적이다.
                pending += graph.outgoingEdges(from: path.contract)
                    .filter { $0.kind == .overrides }
                    .map { DispatchPath(contract: $0.target) }
            }
        }
        return candidates
    }

    /// 하나의 계약 정점에서 일반 호출자를 모아 dispatch 투영 후보를 만든다.
    private func projectedCallers(
        of contract: NodeID,
        from current: NodeID,
        depth: Int,
        visited: Set<NodeID>,
        in graph: CodeGraph
    ) -> [Candidate] {
        var edgesBySource: [NodeID: [GraphEdge]] = [:]
        for edge in graph.incomingEdges(to: contract)
        where edge.kind.impliesUsage && edge.kind != .overrides {
            // 컴파일러는 프로토콜 선언에서 자기 요구사항으로 향하는 call도 남긴다.
            // 프로토콜에는 구현 본문이 없으므로 이것을 witness의 호출자로 투영하면
            // 프로토콜 타입을 거쳐 무관한 모든 준수 타입으로 영향이 퍼진다.
            if graph.node(edge.source)?.kind == .protocolType,
               graph.semanticParent(of: contract) == edge.source { continue }
            guard !visited.contains(edge.source) else { continue }
            edgesBySource[edge.source, default: []].append(edge)
        }

        return edgesBySource.keys.sorted().compactMap { source in
            guard let incoming = edgesBySource[source] else { return nil }
            var kinds = incoming.map(\.kind)
            kinds.append(.overrides)
            kinds = Array(Set(kinds)).sorted { $0.rawValue < $1.rawValue }
            return Candidate(
                node: source,
                visit: ImpactVisit(
                    node: source,
                    depth: depth,
                    via: current,
                    relationship: .dispatchCaller,
                    edges: kinds,
                    dispatchContract: contract
                )
            )
        }
    }

    /// override 간선으로 도달한 계약과 그 근거 종류.
    private struct DispatchPath {
        let contract: NodeID
    }

    // MARK: - 정렬

    /// 방문 후보의 우선순위를 비교한다.
    private struct Candidate {
        let node: NodeID
        let visit: ImpactVisit

        func precedes(_ other: Candidate) -> Bool {
            if visit.via != other.visit.via { return visit.via < other.visit.via }
            let relationRank = Self.relationshipRank(visit.relationship)
            let otherRelationRank = Self.relationshipRank(other.visit.relationship)
            if relationRank != otherRelationRank { return relationRank < otherRelationRank }
            let kinds = visit.edges.map(\.rawValue)
            let otherKinds = other.visit.edges.map(\.rawValue)
            if kinds != otherKinds {
                return kinds.lexicographicallyPrecedes(otherKinds)
            }
            if visit.dispatchContract != other.visit.dispatchContract {
                switch (visit.dispatchContract, other.visit.dispatchContract) {
                case (nil, _): return true
                case (_, nil): return false
                case let (lhs?, rhs?): return lhs < rhs
                }
            }
            return node < other.node
        }

        private static func relationshipRank(_ relationship: ImpactRelationship) -> Int {
            switch relationship {
            case .dependent: return 0
            case .dispatchContract: return 1
            case .dispatchCaller: return 2
            case .runtimeContract: return 3
            case .automaticRuntime: return 4
            case .observedRuntime: return 5
            }
        }
    }

    /// 최종 방문 목록을 깊이, 정점 순으로 정렬한다.
    private static func visitPrecedes(_ lhs: ImpactVisit, _ rhs: ImpactVisit) -> Bool {
        if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
        if lhs.node != rhs.node { return lhs.node < rhs.node }
        if lhs.via != rhs.via { return lhs.via < rhs.via }
        if lhs.relationship != rhs.relationship { return lhs.relationship.rawValue < rhs.relationship.rawValue }
        return lhs.edges.map(\.rawValue).lexicographicallyPrecedes(rhs.edges.map(\.rawValue))
    }
}
