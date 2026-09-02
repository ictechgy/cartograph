import CartographCore

/// 멤버가 보존되어 그 조상까지 함께 살아남은 경우의 근거.
public struct InheritedRetention: Hashable, Sendable {
    /// 실제로 보존 규칙에 걸린 멤버.
    public let member: NodeID
    public let reason: RetentionReason

    public init(member: NodeID, reason: RetentionReason) {
        self.member = member
        self.reason = reason
    }
}

/// 어떤 선언이 왜 살아 있는지(또는 없는지)에 대한 설명.
public enum ReachabilityExplanation: Sendable, Equatable {
    /// 보존 규칙이 뿌리로 지정했다.
    case retained(RetentionReason)
    /// 자신이 아니라 안쪽 멤버가 보존되어 함께 살아남았다.
    case retainedByMember(InheritedRetention)
    /// 뿌리에서 이 경로를 따라 도달했다. 경로의 첫 원소가 뿌리다.
    case reachable(path: [NodeID])
    /// 어디에서도 도달할 수 없다.
    case unreachable
    /// 그래프에 없는 정점이다.
    case unknown
}

/// 데드코드 분석 결과.
public struct UnusedCodeReport: Sendable, Equatable {
    /// 보고 대상 미사용 선언. 위치 순으로 정렬되어 있다.
    public let unused: [GraphNode]
    /// 보존 뿌리와 그 근거.
    public let retentions: [NodeID: RetentionReason]
    /// 뿌리에서 도달 가능한 정점 수.
    public let reachableCount: Int
    /// 분석 대상 정점 수.
    public let totalCount: Int
    /// 멤버가 보존되어 함께 살아남은 조상들.
    public let inheritedRetentions: [NodeID: InheritedRetention]
    /// 도달 경로 복원을 위한 선행 정점 사전.
    private let predecessors: [NodeID: NodeID]

    public init(
        unused: [GraphNode],
        retentions: [NodeID: RetentionReason],
        reachableCount: Int,
        totalCount: Int,
        inheritedRetentions: [NodeID: InheritedRetention] = [:],
        predecessors: [NodeID: NodeID] = [:]
    ) {
        self.unused = unused
        self.retentions = retentions
        self.reachableCount = reachableCount
        self.totalCount = totalCount
        self.inheritedRetentions = inheritedRetentions
        self.predecessors = predecessors
    }

    /// 도달 가능한 정점의 비율(0...1).
    public var reachableRatio: Double {
        totalCount == 0 ? 1 : Double(reachableCount) / Double(totalCount)
    }

    /// 특정 정점이 살아 있는 이유를 설명한다.
    ///
    /// Periphery 를 쓰면서 가장 답답했던 질문 — "이건 왜 안 지워도 된다는 거지?" —
    /// 에 답하기 위한 기능이다.
    public func explain(_ node: NodeID, in graph: CodeGraph) -> ReachabilityExplanation {
        guard graph.contains(node) else { return .unknown }
        if let reason = retentions[node] { return .retained(reason) }
        if let inherited = inheritedRetentions[node] { return .retainedByMember(inherited) }
        guard predecessors[node] != nil else { return .unreachable }

        var path: [NodeID] = [node]
        var current = node
        var visited: Set<NodeID> = [node]
        while let previous = predecessors[current], visited.insert(previous).inserted {
            path.append(previous)
            current = previous
        }
        return .reachable(path: path.reversed())
    }
}

/// 보존 뿌리에서 출발해 도달할 수 없는 선언을 찾는다.
///
/// 데드코드를 "참조가 없는 선언"이 아니라 "뿌리에서 도달 불가능한 정점"으로
/// 정의한다. 서로만 참조하는 죽은 코드 덩어리도 함께 찾아내기 위해서다.
public struct ReachabilityAnalyzer: Sendable {
    public struct Options: Sendable, Equatable {
        /// 미사용 타입의 내부 멤버를 따로 보고할지 여부.
        ///
        /// 기본값은 거짓이다. 타입 하나가 죽으면 그 안의 멤버 스무 개가 함께
        /// 보고되어 정작 고쳐야 할 목록이 묻힌다.
        public var reportMembersOfUnusedTypes: Bool
        /// 보고에서 제외할 선언 종류.
        public var excludedKinds: Set<SymbolKind>
        /// 오버라이드 관계를 역방향으로도 따라갈지 여부.
        ///
        /// 인덱스는 프로토콜 요구사항 호출을 요구사항 심볼에 대한 참조로 기록한다.
        /// 구현체 메서드로 향하는 참조는 어디에도 없다. 정방향만 따라가면
        /// 프로토콜을 통해 호출되는 모든 구현이 미사용으로 보고된다.
        /// Periphery 가 프로토콜 준수 참조를 뒤집어 해결한 것과 같은 문제다.
        public var followOverridesInReverse: Bool

        public init(
            reportMembersOfUnusedTypes: Bool = false,
            excludedKinds: Set<SymbolKind> = [.parameter, .file, .module, .extensionDeclaration],
            followOverridesInReverse: Bool = true
        ) {
            self.reportMembersOfUnusedTypes = reportMembersOfUnusedTypes
            self.excludedKinds = excludedKinds
            self.followOverridesInReverse = followOverridesInReverse
        }
    }

    private let policy: RetentionPolicy
    private let options: Options

    public init(policy: RetentionPolicy = RetentionPolicy(), options: Options = Options()) {
        self.policy = policy
        self.options = options
    }

    public func analyze(graph: CodeGraph, snapshot: IndexSnapshot) -> UnusedCodeReport {
        let retentions = policy.retainedNodes(in: graph, snapshot: snapshot)
        let inherited = inheritedRetentions(retentions: retentions, graph: graph)
        let traversal = traverse(from: Set(retentions.keys).union(inherited.keys), in: graph)

        let unreachable = graph.sortedNodes.filter { !traversal.reachable.contains($0.id) }
        let reported = filterReportable(unreachable, unreachableIDs: Set(unreachable.map(\.id)), graph: graph)

        return UnusedCodeReport(
            unused: reported,
            retentions: retentions,
            reachableCount: traversal.reachable.count,
            totalCount: graph.nodeCount,
            inheritedRetentions: inherited,
            predecessors: traversal.predecessors
        )
    }

    // MARK: - 내부 구현

    /// 보존된 멤버 때문에 함께 살아남는 조상들과 그 근거.
    ///
    /// 멤버 하나가 보존되었는데 그것을 감싸는 타입이 죽은 것으로 보고되면
    /// 결과가 서로 모순된다. 조상까지 함께 살리되, 왜 살았는지도 남긴다.
    /// 근거를 남기지 않으면 `explain` 이 "도달 불가"라고 답해 보고 결과와 어긋난다.
    private func inheritedRetentions(
        retentions: [NodeID: RetentionReason],
        graph: CodeGraph
    ) -> [NodeID: InheritedRetention] {
        var result: [NodeID: InheritedRetention] = [:]
        for (node, reason) in retentions.sorted(by: { $0.key < $1.key }) {
            var current = node
            var visited: Set<NodeID> = [node]
            while let parent = graph.incomingEdges(to: current).first(where: { $0.kind == .member })?.source,
                  visited.insert(parent).inserted {
                if retentions[parent] == nil, result[parent] == nil {
                    result[parent] = InheritedRetention(member: node, reason: reason)
                }
                current = parent
            }
        }
        return result
    }

    private struct Traversal {
        let reachable: Set<NodeID>
        let predecessors: [NodeID: NodeID]
    }

    /// 사용 의미가 있는 간선만 따라가는 너비 우선 탐색.
    private func traverse(from roots: Set<NodeID>, in graph: CodeGraph) -> Traversal {
        var reachable = roots
        var predecessors: [NodeID: NodeID] = [:]
        var queue = roots.sorted()
        var head = 0
        /// 소유 타입이 아직 살아나지 않은 구현체들. 타입이 살아나면 그때 함께 살린다.
        var pendingWitnesses: [NodeID: [(witness: NodeID, requirement: NodeID)]] = [:]

        func visit(_ node: NodeID, from previous: NodeID) {
            guard reachable.insert(node).inserted else { return }
            predecessors[node] = previous
            queue.append(node)
        }

        while head < queue.count {
            let current = queue[head]
            head += 1

            for edge in graph.outgoingEdges(from: current) {
                if edge.kind.impliesUsage {
                    visit(edge.target, from: current)
                } else if edge.kind == .member, graph.node(edge.target)?.kind == .deinitializer {
                    // 살아 있는 타입의 deinit 은 런타임이 부른다. 코드 어디에도 참조가 없다.
                    visit(edge.target, from: current)
                }
            }

            if options.followOverridesInReverse {
                for edge in graph.incomingEdges(to: current) where edge.kind == .overrides {
                    let witness = edge.source
                    guard !reachable.contains(witness) else { continue }
                    // 요구사항이 쓰였다고 해서 "한 번도 만들어지지 않는 타입"의 구현까지
                    // 살리면, 그 구현이 호출하는 바깥 심볼들이 줄줄이 되살아난다.
                    // 소유 타입이 살아 있을 때만 구현을 살린다.
                    if let owner = owningType(of: witness, in: graph), !reachable.contains(owner) {
                        pendingWitnesses[owner, default: []].append((witness, current))
                    } else {
                        visit(witness, from: current)
                    }
                }
            }

            for entry in pendingWitnesses.removeValue(forKey: current) ?? [] {
                visit(entry.witness, from: entry.requirement)
            }
        }
        return Traversal(reachable: reachable, predecessors: predecessors)
    }

    /// 포함 관계 간선을 거슬러 올라간 직계 부모.
    private func owningType(of node: NodeID, in graph: CodeGraph) -> NodeID? {
        graph.incomingEdges(to: node).first { $0.kind == .member }?.source
    }

    /// 사람이 실제로 행동할 수 있는 항목만 남긴다.
    private func filterReportable(
        _ nodes: [GraphNode],
        unreachableIDs: Set<NodeID>,
        graph: CodeGraph
    ) -> [GraphNode] {
        nodes.filter { node in
            guard !options.excludedKinds.contains(node.kind) else { return false }
            guard !node.attributes.contains(.implicit) else { return false }
            if options.reportMembersOfUnusedTypes { return true }
            return !hasUnreachableAncestor(node, unreachableIDs: unreachableIDs, graph: graph)
        }
        .sorted { lhs, rhs in
            switch (lhs.location, rhs.location) {
            case let (left?, right?) where left != right:
                return left < right
            default:
                return lhs.id < rhs.id
            }
        }
    }

    private func hasUnreachableAncestor(
        _ node: GraphNode,
        unreachableIDs: Set<NodeID>,
        graph: CodeGraph
    ) -> Bool {
        var current = node.id
        var visited: Set<NodeID> = [current]
        while let parent = graph.incomingEdges(to: current).first(where: { $0.kind == .member })?.source {
            guard visited.insert(parent).inserted else { return false }
            if unreachableIDs.contains(parent) { return true }
            current = parent
        }
        return false
    }
}
