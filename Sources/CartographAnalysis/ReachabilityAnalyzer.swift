import CartographCore

/// 어떤 선언이 왜 살아 있는지(또는 없는지)에 대한 설명.
public enum ReachabilityExplanation: Sendable, Equatable {
    /// 보존 규칙이 뿌리로 지정했다.
    case retained(RetentionReason)
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
    /// 도달 경로 복원을 위한 선행 정점 사전.
    private let predecessors: [NodeID: NodeID]

    public init(
        unused: [GraphNode],
        retentions: [NodeID: RetentionReason],
        reachableCount: Int,
        totalCount: Int,
        predecessors: [NodeID: NodeID] = [:]
    ) {
        self.unused = unused
        self.retentions = retentions
        self.reachableCount = reachableCount
        self.totalCount = totalCount
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

        public init(
            reportMembersOfUnusedTypes: Bool = false,
            excludedKinds: Set<SymbolKind> = [.parameter, .file, .module, .extensionDeclaration]
        ) {
            self.reportMembersOfUnusedTypes = reportMembersOfUnusedTypes
            self.excludedKinds = excludedKinds
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
        let roots = rootNodes(retentions: retentions, graph: graph)
        let traversal = traverse(from: roots, in: graph)

        let unreachable = graph.sortedNodes.filter { !traversal.reachable.contains($0.id) }
        let reported = filterReportable(unreachable, unreachableIDs: Set(unreachable.map(\.id)), graph: graph)

        return UnusedCodeReport(
            unused: reported,
            retentions: retentions,
            reachableCount: traversal.reachable.count,
            totalCount: graph.nodeCount,
            predecessors: traversal.predecessors
        )
    }

    // MARK: - 내부 구현

    /// 보존된 정점과 그 조상들을 뿌리로 삼는다.
    ///
    /// 멤버 하나가 보존되었는데 그것을 감싸는 타입이 죽은 것으로 보고되면
    /// 결과가 서로 모순된다. 조상까지 함께 살린다.
    private func rootNodes(retentions: [NodeID: RetentionReason], graph: CodeGraph) -> Set<NodeID> {
        var roots: Set<NodeID> = []
        for node in retentions.keys {
            var current: NodeID? = node
            var guardSet: Set<NodeID> = []
            while let identifier = current, guardSet.insert(identifier).inserted {
                roots.insert(identifier)
                current = graph.incomingEdges(to: identifier).first { $0.kind == .member }?.source
            }
        }
        return roots
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

        while head < queue.count {
            let current = queue[head]
            head += 1
            for edge in graph.outgoingEdges(from: current) where edge.kind.impliesUsage {
                if reachable.insert(edge.target).inserted {
                    predecessors[edge.target] = current
                    queue.append(edge.target)
                }
            }
        }
        return Traversal(reachable: reachable, predecessors: predecessors)
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
