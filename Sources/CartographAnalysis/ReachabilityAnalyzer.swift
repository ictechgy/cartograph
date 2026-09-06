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
    /// 생산 코드에서는 도달할 수 없고 테스트·프리뷰만 붙잡고 있는 선언.
    ///
    /// 죽은 코드가 아니므로 미사용으로 보고하지 않는다. 다만 테스트가 유일한
    /// 사용자라는 사실은 팀이 알아야 할 정보다. 계산하지 않았으면 비어 있다.
    public let testOnly: [GraphNode]
    /// 도달 경로 복원을 위한 선행 정점 사전.
    private let predecessors: [NodeID: NodeID]

    public init(
        unused: [GraphNode],
        retentions: [NodeID: RetentionReason],
        reachableCount: Int,
        totalCount: Int,
        inheritedRetentions: [NodeID: InheritedRetention] = [:],
        predecessors: [NodeID: NodeID] = [:],
        testOnly: [GraphNode] = []
    ) {
        self.testOnly = testOnly
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
        /// 테스트·프리뷰만 붙잡고 있는 선언을 따로 계산할지 여부.
        ///
        /// 탐색을 한 번 더 돌아야 하므로 요청받았을 때만 한다.
        public var findsTestOnlyCode: Bool

        public init(
            reportMembersOfUnusedTypes: Bool = false,
            excludedKinds: Set<SymbolKind> = [.parameter, .file, .module, .extensionDeclaration],
            followOverridesInReverse: Bool = true,
            findsTestOnlyCode: Bool = false
        ) {
            self.reportMembersOfUnusedTypes = reportMembersOfUnusedTypes
            self.excludedKinds = excludedKinds
            self.followOverridesInReverse = followOverridesInReverse
            self.findsTestOnlyCode = findsTestOnlyCode
        }
    }

    private let policy: RetentionPolicy
    private let options: Options

    public init(policy: RetentionPolicy = RetentionPolicy(), options: Options = Options()) {
        self.policy = policy
        self.options = options
    }

    public func analyze(graph: CodeGraph, snapshot: IndexSnapshot) -> UnusedCodeReport {
        let declared = policy.retainedNodes(in: graph, snapshot: snapshot)
        // 증인 보존은 소유 타입이 살아 있을 때만 성립한다. 프레임워크가 `body` 를 부르는 것은
        // 그 타입을 누군가 만들 때뿐이라, 아무도 만들지 않는 타입의 `body` 를 무조건 뿌리로
        // 두면 답이 스스로 모순된다 — 타입은 "미사용", 그 멤버는 "보존됨".
        let (unconditional, conditional) = partitionWitnesses(declared, graph: graph)
        let inherited = inheritedRetentions(retentions: unconditional, graph: graph)
        let traversal = traverse(
            from: Set(unconditional.keys).union(inherited.keys),
            conditionalWitnesses: conditional,
            in: graph
        )
        // 살아나지 못한 증인의 근거는 남기지 않는다. 근거 목록은 언제나 도달 가능한 정점의
        // 부분집합이어야 하고, 그렇지 않으면 `explain` 이 보고서와 다른 답을 한다.
        let retentions = declared.filter { traversal.reachable.contains($0.key) }

        let unreachable = graph.sortedNodes.filter { !traversal.reachable.contains($0.id) }
        let reported = filterReportable(unreachable, unreachableIDs: Set(unreachable.map(\.id)), graph: graph)

        return UnusedCodeReport(
            unused: reported,
            retentions: retentions,
            reachableCount: traversal.reachable.count,
            totalCount: graph.nodeCount,
            inheritedRetentions: inherited,
            predecessors: traversal.predecessors,
            testOnly: testOnlyCode(
                reachable: traversal.reachable,
                retentions: retentions,
                inherited: inherited,
                conditionalWitnesses: conditional,
                graph: graph
            )
        )
    }

    // MARK: - 내부 구현

    /// 테스트·프리뷰만 붙잡고 있는 선언.
    ///
    /// 생산 코드 뿌리에서만 한 번 더 탐색해, 전체 도달 집합과의 차이를 본다.
    /// 그 차이가 곧 "지워도 앱은 그대로지만 테스트가 깨지는" 선언들이다.
    /// 죽은 코드가 아니므로 미사용으로 보고하지 않는다.
    private func testOnlyCode(
        reachable: Set<NodeID>,
        retentions: [NodeID: RetentionReason],
        inherited: [NodeID: InheritedRetention],
        conditionalWitnesses: [NodeID: NodeID],
        graph: CodeGraph
    ) -> [GraphNode] {
        guard options.findsTestOnlyCode else { return [] }

        // 합성 선언은 생산 코드의 시작점이 될 수 없다. 그것은 무언가 *때문에*
        // 생긴 것이지 스스로 살아 있는 이유가 아니다. 특히 swift-testing 은
        // 테스트를 등록하려고 합성 심볼 사슬을 만드는데, 그것을 생산 뿌리로 세면
        // 테스트가 닿는 모든 것이 생산에서도 닿는 것으로 보여 이 질의가 무의미해진다.
        func seedsProduction(_ reason: RetentionReason) -> Bool {
            !reason.isTestOrPreviewRoot && reason != .compilerSynthesized
        }

        var productionRoots: Set<NodeID> = []
        for (node, reason) in retentions where seedsProduction(reason) {
            productionRoots.insert(node)
        }
        // 물려받은 보존도 근거를 따라간다. 테스트 메서드 때문에 살아남은 타입은
        // 생산 코드의 뿌리가 아니다.
        for (node, retention) in inherited where seedsProduction(retention.reason) {
            productionRoots.insert(node)
        }

        // 테스트 선언이 들어 있는 모듈은 테스트 타깃이다. 이름 규칙에 기대지 않고
        // 그래프가 말해 주는 사실로 판단한다. 이것이 없으면 목록의 대부분이 테스트
        // 타깃 내부의 도우미로 채워져, 정작 알고 싶은 것 — 테스트만 붙잡고 있는
        // *생산* 코드 — 이 묻힌다. 실측에서 408건 중 318건이 그런 잡음이었다.
        var testModules: Set<String> = []
        for (node, reason) in retentions where reason.isTestTargetRoot {
            if let module = graph.node(node)?.module { testModules.insert(module) }
        }

        // 같은 조건을 여기에도 건다. 걸러진 목록만 넘기면 "이미 살아난 증인이라 무조건
        // 뿌리여도 된다" 는 우연에 기대게 되고, 다음 사람이 목록을 바꾸는 순간 증인과 그
        // 호출자들이 테스트 전용 목록으로 쏟아진다. 소유 타입이 생산에서 도달 가능할 때만
        // 증인이 생산 뿌리가 된다는 규칙을 그대로 쓴다.
        let production = traverse(
            from: productionRoots,
            conditionalWitnesses: conditionalWitnesses,
            in: graph
        ).reachable
        let candidates = graph.sortedNodes.filter {
            reachable.contains($0.id)
                && !production.contains($0.id)
                && !($0.module.map(testModules.contains) ?? false)
                // 합성 선언은 사용자가 손댈 수 있는 것이 아니다. 생산 씨앗에서
                // 뺐기 때문에 후보로 새어 들어올 수 있어 여기서도 막는다.
                && retentions[$0.id] != .compilerSynthesized
                // 합성된 멤버 때문에 살아난 타입도 마찬가지다. 아무도 쓰지 않는 public
                // 구조체는 memberwise init 이 뿌리가 되어 전체 탐색에서는 살고 생산
                // 탐색에서는 죽는다. 그 차이를 "테스트만 붙잡고 있다"로 읽으면 테스트가
                // 닿은 적 없는 선언이 테스트 전용으로 보고된다. 코퍼스가 잡았다.
                && inherited[$0.id]?.reason != .compilerSynthesized
                && !$0.attributes.contains(.implicit)
                && !isTestInfrastructure($0.id, retentions: retentions, graph: graph)
        }
        return filterReportable(candidates, unreachableIDs: Set(candidates.map(\.id)), graph: graph)
    }

    /// 테스트 코드 자신인지 판단한다.
    ///
    /// 테스트 메서드와 그것을 감싸는 스위트는 당연히 테스트에서만 도달한다.
    /// 그것까지 보고하면 목록이 자명한 사실로 가득 차, 정작 알고 싶은 것
    /// — 테스트만 붙잡고 있는 *생산* 코드 — 이 묻힌다.
    ///
    /// 테스트 파일 최상위에 둔 도우미처럼 테스트 뿌리를 조상으로 갖지 않는 선언은
    /// 여전히 보고된다. 그것까지 걸러 내려면 타깃 구분이 필요한데, 인덱스만으로는
    /// 모듈 이름 규칙에 기대는 수밖에 없어 더 부정확해진다.
    private func isTestInfrastructure(
        _ node: NodeID,
        retentions: [NodeID: RetentionReason],
        graph: CodeGraph
    ) -> Bool {
        var current: NodeID? = node
        var visited: Set<NodeID> = []
        while let id = current, visited.insert(id).inserted {
            if retentions[id]?.isTestOrPreviewRoot == true { return true }
            current = graph.semanticParent(of: id)
        }
        return false
    }

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
            // 모든 근거가 컨테이너를 살리지는 않는다. 합성 선언과 외부 준수·오버라이드는
            // 타입이 있으면 따라 생기는 것이라, 전파하면 아무도 쓰지 않는 타입이 자기
            // memberwise init 이나 자기 `body` 때문에 영원히 살아남는다.
            guard reason.retainsContainingType else { continue }
            while let parent = graph.semanticParent(of: current), visited.insert(parent).inserted {
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
    /// 보존 근거를 무조건 뿌리가 되는 것과, 소유 타입이 살아야 성립하는 증인으로 가른다.
    ///
    /// 외부 선언을 오버라이드·준수하는 멤버는 "프레임워크가 부른다" 를 근거로 살아남는데,
    /// 그것은 그 타입을 누군가 만들 때만 참이다. 소유 타입이 없는 최상위 선언은 조건이
    /// 붙을 자리가 없으므로 그대로 무조건이다.
    private func partitionWitnesses(
        _ retentions: [NodeID: RetentionReason],
        graph: CodeGraph
    ) -> (unconditional: [NodeID: RetentionReason], conditional: [NodeID: NodeID]) {
        var unconditional: [NodeID: RetentionReason] = [:]
        var conditional: [NodeID: NodeID] = [:]
        for (node, reason) in retentions {
            if reason.needsReachableOwner, let owner = owningType(of: node, in: graph) {
                conditional[node] = owner
            } else {
                unconditional[node] = reason
            }
        }
        return (unconditional, conditional)
    }

    private func traverse(
        from roots: Set<NodeID>,
        conditionalWitnesses: [NodeID: NodeID] = [:],
        in graph: CodeGraph
    ) -> Traversal {
        var reachable = roots
        var predecessors: [NodeID: NodeID] = [:]
        var queue = roots.sorted()
        var head = 0
        /// 소유 타입이 아직 살아나지 않은 구현체들. 타입이 살아나면 그때 함께 살린다.
        ///
        /// `reachedFrom` 은 설명 경로에 기록할 앞 정점이다. 역방향 오버라이드에서 온
        /// 항목은 요구사항이고, 조건부 증인으로 씨앗을 뿌린 항목은 소유 타입이다.
        /// 둘 다 그래프에 실재하는 간선이라 경로에 없는 홉이 생기지 않는다.
        var pendingWitnesses: [NodeID: [(witness: NodeID, reachedFrom: NodeID)]] = [:]
        for (witness, owner) in conditionalWitnesses.sorted(by: { $0.key < $1.key })
        where !reachable.contains(witness) {
            // 소유 타입이 이미 뿌리면 바로 살리고, 아니면 그 타입이 살아날 때를 기다린다.
            if reachable.contains(owner) {
                visit(witness, from: owner)
            } else {
                pendingWitnesses[owner, default: []].append((witness, owner))
            }
        }

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
                visit(entry.witness, from: entry.reachedFrom)
            }
        }
        return Traversal(reachable: reachable, predecessors: predecessors)
    }

    /// 포함 관계를 거슬러 올라간 의미상의 소유 타입.
    ///
    /// 익스텐션을 건너뛴다. 익스텐션 정점을 소유자로 쓰면, 아무도 익스텐션을
    /// 사용하지 않으므로 증인이 영원히 되살아나지 못한다.
    private func owningType(of node: NodeID, in graph: CodeGraph) -> NodeID? {
        graph.semanticParent(of: node)
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
        while let parent = graph.semanticParent(of: current) {
            guard visited.insert(parent).inserted else { return false }
            if unreachableIDs.contains(parent) { return true }
            current = parent
        }
        return false
    }
}
