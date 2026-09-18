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

/// `cartograph:ignore` 를 떼어 내도 아무 보고도 생기지 않는, 아무 일도 하지 않는 무시 주석 하나.
public struct SuperfluousIgnore: Sendable, Equatable {
    /// 주석이 덮는 범위의 최상위 선언. 파일 단위면 그 파일의 첫 무시 선언이다.
    public let node: GraphNode
    /// 주석 하나가 덮는 선언 수(앵커 포함).
    public let coveredCount: Int
    /// 파일의 선언 전체가 한 단위로 묶였는지 여부.
    ///
    /// `cartograph:ignore:all` 도 선언마다 같은 속성으로 번지므로 그래프만으로는
    /// 파일 코멘트 하나와 선언별 코멘트를 구별할 수 없다. 파일의 정점이 전부
    /// 무시된 경우는 하나의 파일 범위 주석으로 본다.
    public let coversWholeFile: Bool

    public init(node: GraphNode, coveredCount: Int, coversWholeFile: Bool) {
        self.node = node
        self.coveredCount = coveredCount
        self.coversWholeFile = coversWholeFile
    }
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
    /// 본문에서 한 번도 읽히지 않은 함수 파라미터. 위치 순으로 정렬되어 있다.
    ///
    /// 미사용 선언과는 다른 종류의 발견이다 — 선언이 도달 불가능한 것이 아니라
    /// 살아 있는 함수의 입력이 본문에서 쓰이지 않는다는 뜻이다. 고치는 방법이
    /// 삭제가 아니라 `_` 표기나 시그니처 검토일 수 있으므로 별도 목록으로 분리한다.
    public let unusedParameters: [IndexedParameter]
    /// 대입은 되지만 한 번도 읽히지 않는 프로퍼티·변수. 위치 순으로 정렬되어 있다.
    ///
    /// 도달 불가능한 선언이 아니라 살아 있는 코드가 값을 넣기만 하고 꺼내 보지
    /// 않는 저장소다. 고치는 방법이 삭제가 아닐 수 있으므로(로그·관측 지점으로
    /// 쓰려던 것일 수 있다) 별도 목록으로 분리한다.
    public let assignOnly: [GraphNode]
    /// 파일의 참조 근거가 증명하지 못하는 `import` 선언. 위치 순으로 정렬되어 있다.
    ///
    /// 도달성과 무관한 별도 질이다 — 죽은 파일의 import도 import로서는
    /// 미사용이다. 재수출·조건부·무시 표식이 있거나 근거를 확신할 수 없는
    /// 파일의 import는 목록에 나타나지 않는다.
    public let unusedImports: [IndexedImport]
    /// 떼어 내도 아무 보고도 생기지 않는 `cartograph:ignore` 주석. 위치 순으로 정렬되어 있다.
    ///
    /// 억제할 발견이 없는 주석은 선언을 죽은 것으로 영원히 덮는 죽은 주석이다.
    /// 무시 정점이 하나도 없으면 비어 있고, 그때는 반사실 탐색도 돌지 않는다.
    public let superfluousIgnores: [SuperfluousIgnore]
    /// 도달 경로 복원을 위한 선행 정점 사전.
    private let predecessors: [NodeID: NodeID]

    public init(
        unused: [GraphNode],
        retentions: [NodeID: RetentionReason],
        reachableCount: Int,
        totalCount: Int,
        inheritedRetentions: [NodeID: InheritedRetention] = [:],
        predecessors: [NodeID: NodeID] = [:],
        testOnly: [GraphNode] = [],
        unusedParameters: [IndexedParameter] = [],
        assignOnly: [GraphNode] = [],
        unusedImports: [IndexedImport] = [],
        superfluousIgnores: [SuperfluousIgnore] = []
    ) {
        self.testOnly = testOnly
        self.unused = unused
        self.retentions = retentions
        self.reachableCount = reachableCount
        self.totalCount = totalCount
        self.inheritedRetentions = inheritedRetentions
        self.predecessors = predecessors
        self.unusedParameters = unusedParameters
        self.assignOnly = assignOnly
        self.unusedImports = unusedImports
        self.superfluousIgnores = superfluousIgnores
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
        let protocolRequirementOwners = protocolRequirementOwners(in: graph)
        // 증인 보존은 소유 타입이 살아 있을 때만 성립한다. 프레임워크가 `body` 를 부르는 것은
        // 그 타입을 누군가 만들 때뿐이라, 아무도 만들지 않는 타입의 `body` 를 무조건 뿌리로
        // 두면 답이 스스로 모순된다 — 타입은 "미사용", 그 멤버는 "보존됨".
        let (unconditional, conditional) = partitionWitnesses(declared, graph: graph)
        let inherited = inheritedRetentions(retentions: unconditional, graph: graph)
        let traversal = traverse(
            from: Set(unconditional.keys).union(inherited.keys),
            conditionalWitnesses: conditional,
            protocolRequirementOwners: protocolRequirementOwners,
            in: graph
        )
        // 살아나지 못한 증인의 근거는 남기지 않는다. 근거 목록은 언제나 도달 가능한 정점의
        // 부분집합이어야 하고, 그렇지 않으면 `explain` 이 보고서와 다른 답을 한다.
        let retentions = declared.filter { traversal.reachable.contains($0.key) }

        let unreachable = graph.sortedNodes.filter { !traversal.reachable.contains($0.id) }
        let reported = filterReportable(unreachable, unreachableIDs: Set(unreachable.map(\.id)), graph: graph)
        let unusedParameters = unusedParameters(
            in: snapshot,
            reachable: traversal.reachable,
            protocolRequirementOwners: protocolRequirementOwners
        )
        let assignOnly = assignOnlyProperties(
            in: graph,
            snapshot: snapshot,
            reachable: traversal.reachable,
            protocolRequirementOwners: protocolRequirementOwners
        )

        let testOnly = testOnlyCode(
            reachable: traversal.reachable,
            retentions: retentions,
            inherited: inherited,
            conditionalWitnesses: conditional,
            protocolRequirementOwners: protocolRequirementOwners,
            graph: graph
        )

        return UnusedCodeReport(
            unused: reported,
            retentions: retentions,
            reachableCount: traversal.reachable.count,
            totalCount: graph.nodeCount,
            inheritedRetentions: inherited,
            predecessors: traversal.predecessors,
            testOnly: testOnly,
            unusedParameters: unusedParameters,
            assignOnly: assignOnly,
            unusedImports: UnusedImportAnalyzer.analyze(snapshot),
            superfluousIgnores: superfluousIgnores(
                declared: declared,
                reachable: traversal.reachable,
                testOnly: testOnly,
                protocolRequirementOwners: protocolRequirementOwners,
                graph: graph,
                snapshot: snapshot
            )
        )
    }

    // MARK: - 내부 구현

    /// 본문에서 한 번도 읽히지 않은 파라미터.
    ///
    /// 파라미터는 정점이 아니므로 도달성 탐색이 아니라 별도 질의로 계산한다.
    /// 보고 조건은 둘 다 보존 방향이다: 선언한 함수가 살아 있을 때만 보고하고
    /// (죽은 함수의 파라미터는 함수의 발견에 덮인다), 프로토콜 요구사항의
    /// 파라미터는 본문이 없어 미사용이 규칙이므로 제외한다. `newValue` 같은
    /// 접근자 파라미터는 접근자가 정점이 아니라 부모 해석이 안 되어 자연히 빠진다.
    private func unusedParameters(
        in snapshot: IndexSnapshot,
        reachable: Set<NodeID>,
        protocolRequirementOwners: [NodeID: NodeID]
    ) -> [IndexedParameter] {
        snapshot.parameters.filter { parameter in
            // 근거가 없는(nil) 파라미터는 모르는 것이므로 보고하지 않는다.
            guard parameter.isReferenced == false else { return false }
            let owner = NodeID(parameter.functionUSR)
            guard reachable.contains(owner),
                  protocolRequirementOwners[owner] == nil
            else { return false }
            return true
        }
        .sorted { $0.location < $1.location }
    }

    /// 대입은 되지만 한 번도 읽히지 않는 프로퍼티.
    ///
    /// 파라미터와 달리 사용 근거가 인덱스에 있다 — 참조 발생에 read/write
    /// 역할이 붙는다. 쓰기만 있고 읽기가 없으며 불명한 접근도 없는 심볼만
    /// 보고한다. 보고 조건은 전부 보존 방향이다: 정점이 살아 있을 때만(죽은
    /// 코드의 저장소는 그 정점의 발견에 덮인다), 프로토콜 요구사항은 본문이
    /// 없어 제외하고, 오버라이드·준수 증인은 요구사항 심볼 쪽으로 읽기가
    /// 기록되어 제외한다. 런타임이 저장소를 관리하거나(`@NSManaged`·
    /// `@Observable` 등) Objective-C·Interface Builder·합성 Codable 이
    /// 접근을 숨길 수 있는 선언도 제외한다 — 인덱스 밖의 읽기가 있을 수 있다.
    private func assignOnlyProperties(
        in graph: CodeGraph,
        snapshot: IndexSnapshot,
        reachable: Set<NodeID>,
        protocolRequirementOwners: [NodeID: NodeID],
        honoringIgnoreComments: Bool = true
    ) -> [GraphNode] {
        guard !snapshot.propertyAccesses.isEmpty else { return [] }
        let hiddenOwners = accessHidingOwners(in: snapshot, graph: graph)
        return graph.sortedNodes.filter { node in
            guard node.kind == .property || node.kind == .variable,
                  reachable.contains(node.id),
                  snapshot.propertyAccesses[node.id.rawValue]?.isAssignOnly == true,
                  !options.excludedKinds.contains(node.kind),
                  isAccessVisible(node, honoringIgnoreComments: honoringIgnoreComments),
                  protocolRequirementOwners[node.id] == nil,
                  // 오버라이드·준수 증인의 읽기는 요구사항 심볼에 기록된다.
                  !graph.outgoingEdges(from: node.id).contains(where: { $0.kind == .overrides }),
                  !isAccessHidden(node, hiddenOwners: hiddenOwners, in: graph)
            else { return false }
            return true
        }
        .sorted(by: Self.locationThenID)
    }

    /// 이 선언 자체에 대한 접근이 인덱스에 보이는지 — 보이지 않는 경로가
    /// 열려 있으면 "읽힌 적 없다" 를 주장할 수 없다.
    ///
    /// 반사실 질의에서는 `honoringIgnoreComments` 를 꺼서 "주석이 없었다면"
    /// 보고될지를 재본다 — 주석이 assign-only 보고를 억제하고 있었다면
    /// 그 주석은 불필요가 아니다.
    private func isAccessVisible(_ node: GraphNode, honoringIgnoreComments: Bool = true) -> Bool {
        !node.attributes.contains(.implicit)
            && !(honoringIgnoreComments && node.attributes.contains(.ignoreComment))
            && !node.attributes.contains(.runtimeManaged)
            && !node.attributes.contains(.dynamicDispatch)
            && !node.attributes.contains(.dynamicReplacement)
            && !node.attributes.contains { $0.isObjectiveCRelated || $0.isInterfaceBuilderRelated }
    }

    /// 프로퍼티의 소유자가 접근을 숨기는 선언인지.
    ///
    /// 어휘적 부모와 의미상 부모를 함께 본다 — `extension S: Hashable` 안에
    /// 선언된 프로퍼티의 어휘적 부모는 익스텐션이고, `S` 안에 선언된
    /// 프로퍼티의 소유 타입은 S 이다. 둘 다 검사해야 익스텐션에 선언된
    /// 준수를 놓치지 않는다. 중첩 타입은 바깥 타입의 합성이 건드리지
    /// 않으므로 직접 부모만 본다.
    private func isAccessHidden(
        _ node: GraphNode,
        hiddenOwners: Set<NodeID>,
        in graph: CodeGraph
    ) -> Bool {
        if let lexical = graph.incomingEdges(to: node.id).first(where: { $0.kind == .member })?.source,
           hiddenOwners.contains(lexical) {
            return true
        }
        if let semantic = graph.semanticParent(of: node.id), hiddenOwners.contains(semantic) {
            return true
        }
        return false
    }

    /// 저장소 접근을 인덱스 밖으로 빼는 소유 선언의 USR 집합.
    ///
    /// 두 갈래다. 속성으로 알 수 있는 것(`@NSManaged`·`@objcMembers`·구문에서
    /// 읽은 `.codable` 표식)과, 준수 합성으로만 생기는 것(`Equatable`·
    /// `Hashable`·`Codable` 계열의 합성 구현은 저장 프로퍼티를 읽지만 소스
    /// 위치가 없어 인덱스에 읽기가 남지 않는다). 후자는 준수 참조로 잡는다 —
    /// 외부 프로토콜은 그래프 정점이 아니어서 간선이 아니라 스냅샷의
    /// conformance 참조를 봐야 한다. 익스텐션에 선언된 준수는 extends 대상
    /// 타입으로 번역한다.
    private func accessHidingOwners(in snapshot: IndexSnapshot, graph: CodeGraph) -> Set<NodeID> {
        var hidden: Set<NodeID> = []
        for reference in snapshot.references where reference.kind == .conformance {
            guard Self.synthesizedReaderProtocolUSRs.contains(reference.targetUSR) else { continue }
            hidden.insert(NodeID(reference.sourceUSR))
        }
        for node in graph.sortedNodes {
            let attrs = node.attributes
            if attrs.contains(.codable) || attrs.contains(.runtimeManaged)
                || attrs.contains(.objcMembers) {
                hidden.insert(node.id)
            }
        }
        // 익스텐션 선언에 붙은 숨김 근거는 확장 대상 타입에도 적용한다.
        for node in graph.sortedNodes
        where node.kind == .extensionDeclaration && hidden.contains(node.id) {
            if let extended = graph.outgoingEdges(from: node.id)
                .first(where: { $0.kind == .extends })?.target {
                hidden.insert(extended)
            }
        }
        return hidden
    }

    /// 준수하면 컴파일러가 저장 프로퍼티를 읽는 멤버를 합성해 주는 stdlib 프로토콜 USR.
    /// 합성 본문은 소스 위치가 없어 인덱스에 읽기 참조가 남지 않는다.
    static let synthesizedReaderProtocolUSRs: Set<String> = [
        "s:SQ",  // Equatable
        "s:SH",  // Hashable
        "s:SE",  // Encodable
        "s:Se",  // Decodable
    ]

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
        protocolRequirementOwners: [NodeID: NodeID],
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
            protocolRequirementOwners: protocolRequirementOwners,
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

    /// 프로토콜이 어휘적으로 직접 포함하는 요구사항과 그 소유자.
    ///
    /// `semanticParent` 는 프로토콜 익스텐션의 구현을 프로토콜 아래로 접기 때문에,
    /// 요구사항 판정에 쓰면 기본 구현까지 요구사항으로 오인한다. 실제 요구사항은
    /// 프로토콜 정점에서 나가는 직접 `member` 간선으로만 식별해야 한다.
    private func protocolRequirementOwners(in graph: CodeGraph) -> [NodeID: NodeID] {
        var owners: [NodeID: NodeID] = [:]
        for node in graph.sortedNodes where node.kind == .protocolType {
            for edge in graph.outgoingEdges(from: node.id) where edge.kind == .member {
                owners[edge.target] = node.id
            }
        }
        return owners
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
        protocolRequirementOwners: [NodeID: NodeID],
        in graph: CodeGraph,
        alreadyReached: Set<NodeID> = []
    ) -> Traversal {
        var reachable = alreadyReached.union(roots)
        var predecessors: [NodeID: NodeID] = [:]
        // 이미 도달한 정점은 펼쳐도 새로 닿는 곳이 없다 — 그 폐쇄 부분집합의
        // 간선을 단위마다 다시 훑으면 무시 단위 수만큼 전체 탐색 비용이 곱해진다.
        var queue = roots.subtracting(alreadyReached).sorted()
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

        /// `current` 를 오버라이드한 구현체를 조건에 맞게 살린다.
        ///
        /// 요구사항이 쓰였다고 해서 "한 번도 만들어지지 않는 타입"의 구현까지
        /// 살리면, 그 구현이 호출하는 바깥 심볼들이 줄줄이 되살아난다.
        /// 소유 타입이 살아 있을 때만 구현을 살린다.
        func examineOverrides(of current: NodeID) {
            for edge in graph.incomingEdges(to: current) where edge.kind == .overrides {
                let witness = edge.source
                guard !reachable.contains(witness) else { continue }
                if isDefaultProtocolWitness(
                    witness,
                    protocolID: protocolRequirementOwners[current],
                    in: graph
                ) {
                    visit(witness, from: current)
                } else if let owner = owningType(of: witness, in: graph), !reachable.contains(owner) {
                    pendingWitnesses[owner, default: []].append((witness, current))
                } else {
                    visit(witness, from: current)
                }
            }
        }

        // 시드로 받은 정점은 큐에 들어가지 않아 아래 순회에서 간선 검사가 건너뛰어진다.
        // 시드 집합은 전체 탐색에서 닫혀 있어도, 아직 살아나지 않은 소유 타입에 걸려
        // 있던 증인은 이 세계의 뿌리에서 새로 살아날 수 있다. 오버라이드 관계만은
        // 시드에 대해서도 다시 본다.
        if options.followOverridesInReverse {
            for seed in alreadyReached.sorted() {
                examineOverrides(of: seed)
            }
        }

        while head < queue.count {
            let current = queue[head]
            head += 1

            for edge in graph.outgoingEdges(from: current) {
                if edge.kind == .overrides, protocolRequirementOwners[edge.target] != nil,
                   protocolRequirementOwners[edge.source] == nil {
                    continue
                }
                if edge.kind.impliesUsage {
                    visit(edge.target, from: current)
                } else if edge.kind == .member, graph.node(edge.target)?.kind == .deinitializer {
                    // 살아 있는 타입의 deinit 은 런타임이 부른다. 코드 어디에도 참조가 없다.
                    visit(edge.target, from: current)
                }
            }

            if options.followOverridesInReverse {
                examineOverrides(of: current)
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
    /// 사용하지 않으므로 증인이 영원히 되살아나지 못한다. 확장 대상이 외부이거나
    /// 필터 밖이라 확인할 수 없으면 소유자를 추측하지 않고 nil 을 돌려 보존을 넓힌다.
    private func owningType(of node: NodeID, in graph: CodeGraph) -> NodeID? {
        guard let lexicalParent = graph.incomingEdges(to: node).first(where: { $0.kind == .member })?.source,
              let parent = graph.node(lexicalParent)
        else { return nil }
        if parent.kind == .extensionDeclaration {
            guard let extended = graph.outgoingEdges(from: parent.id)
                .first(where: { $0.kind == .extends })?.target,
                  let owner = graph.node(extended),
                  !owner.isExternal
            else { return nil }
            return owner.id
        }
        return parent.id
    }

    /// 해당 구현이 요구사항의 기본 구현을 담은 프로토콜 익스텐션인지 확인한다.
    ///
    /// 기본 구현의 의미상 소유자는 프로토콜이지만, 요구사항 호출만으로도 그 구현이
    /// 선택될 수 있다. 따라서 프로토콜 정점 자체가 별도로 도달하지 않아도 요구사항의
    /// 역방향 디스패치에서 활성화한다. 어휘적 `.member` 부모와 `.extends` 대상을 함께
    /// 확인해 클래스 오버라이드나 임의 익스텐션 구현을 섞지 않는다.
    private func isDefaultProtocolWitness(
        _ witness: NodeID,
        protocolID: NodeID?,
        in graph: CodeGraph
    ) -> Bool {
        guard let lexicalParent = graph.incomingEdges(to: witness).first(where: { $0.kind == .member })?.source,
              let parent = graph.node(lexicalParent),
              parent.kind == .extensionDeclaration,
              let extendedProtocol = graph.outgoingEdges(from: parent.id)
                  .first(where: { $0.kind == .extends })?.target,
              extendedProtocol == protocolID,
              graph.node(extendedProtocol)?.kind == .protocolType
        else { return false }
        return true
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
            if options.reportMembersOfUnusedTypes, !SourceLocalSymbol.contains(node.usr ?? "") { return true }
            return !hasReportableUnreachableTypeAncestor(node, unreachableIDs: unreachableIDs, graph: graph)
        }
        .sorted(by: Self.locationThenID)
    }

    private func hasReportableUnreachableTypeAncestor(
        _ node: GraphNode,
        unreachableIDs: Set<NodeID>,
        graph: CodeGraph
    ) -> Bool {
        var current = node.id
        var visited: Set<NodeID> = [current]
        while let parent = graph.semanticParent(of: current) {
            guard visited.insert(parent).inserted else { return false }
            // SDK 익스텐션은 자체가 보고 대상 타입이 아니다. 그 정점이 도달하지
            // 않는다는 이유로 내부 도우미까지 숨기면 query는 unreachable인데
            // dead에서는 영원히 사라지는 판정이 된다.
            let isLocal = SourceLocalSymbol.contains(node.usr ?? "")
            if unreachableIDs.contains(parent), let ancestor = graph.node(parent),
               (ancestor.kind.isTypeDeclaration || (isLocal
                   && [.function, .method, .initializer, .deinitializer].contains(ancestor.kind))),
               !options.excludedKinds.contains(ancestor.kind),
               !ancestor.attributes.contains(.implicit) {
                return true
            }
            current = parent
        }
        return false
    }

    // MARK: - 불필요한 무시 주석

    /// `cartograph:ignore` 코멘트 하나가 덮는 선언 묶음.
    private struct IgnoreUnit {
        /// 단위에 속한 정점.
        let members: Set<NodeID>
        /// 진단 위치를 제공하는, 위치가 가장 앞선 선언.
        let anchor: GraphNode
        /// 파일 범위 주석(`ignore:all`)이 덮는 단위인지.
        let coversWholeFile: Bool
    }

    /// 주석을 떼어 내도 보고가 달라지지 않는 무시 단위를 찾는다.
    ///
    /// 이 판정은 "그 주석이 없었다면 무엇이 보고됐는가" 하는 반사실 질의다.
    /// 모든 주석을 동시에 뗀 탐색을 한 번 돌려 그래도 살아남는 단위는 즉시
    /// 불필요로 확정하고, 그래도 죽는 단위만 자기 범위의 무지만 뗀 탐색으로
    /// 다시 본다 — 다른 주석이 살려 두는 선언에 기대 죽는 것과 스스로 죽는
    /// 것을 구분해야 연쇄된 주석을 억지로 붙잡지 않기 때문이다.
    ///
    /// 보고 대상은 죽은 선언만이 아니다. 테스트에서만 도달되는 선언도 보고에
    /// 오르므로, 주석을 떼면 test-only 발견이 되는 선언을 덮는 주석도 일을 한다.
    private func superfluousIgnores(
        declared: [NodeID: RetentionReason],
        reachable: Set<NodeID>,
        testOnly: [GraphNode],
        protocolRequirementOwners: [NodeID: NodeID],
        graph: CodeGraph,
        snapshot: IndexSnapshot
    ) -> [SuperfluousIgnore] {
        let units = ignoreUnits(in: graph)
        guard !units.isEmpty else { return [] }

        // 정점 하나를 덮는 단위 수. 무시된 익스텐션의 멤버가 무시된 확장 대상에도
        // 속하면 두 주석이 같은 선언을 덮는데, 한쪽을 떼어도 다른 쪽이 남으므로
        // 그 정점의 무지는 살아 있는 것으로 둬야 한다.
        var coverageCount: [NodeID: Int] = [:]
        for unit in units {
            for member in unit.members {
                coverageCount[member, default: 0] += 1
            }
        }

        let fallback = policy.retainedNodesWithoutIgnoreComments(in: graph, snapshot: snapshot)
        let fallbackWorld = reachabilityWorld(
            retentions: fallback,
            protocolRequirementOwners: protocolRequirementOwners,
            graph: graph
        )
        let reachableWithoutAnyIgnore = fallbackWorld.reachable
        let testOnlyWithoutAll = Set(testOnlyCode(
            reachable: reachableWithoutAnyIgnore,
            retentions: fallbackWorld.retentions,
            inherited: fallbackWorld.inherited,
            conditionalWitnesses: fallbackWorld.conditionalWitnesses,
            protocolRequirementOwners: protocolRequirementOwners,
            graph: graph
        ).map(\.id))
        // assign-only 보고도 주석이 억제한다. 모든 주석을 뗀 세계에서
        // assign-only로 보고될 정점이면, 그 정점을 덮는 주석은 억제
        // 역할을 하고 있으므로 불필요가 아니다.
        let assignOnlyWithoutAll = Set(assignOnlyProperties(
            in: graph,
            snapshot: snapshot,
            reachable: reachableWithoutAnyIgnore,
            protocolRequirementOwners: protocolRequirementOwners,
            honoringIgnoreComments: false
        ).map(\.id))
        let allIDs = Set(graph.sortedNodes.map(\.id))
        let reportedTestOnly = Set(testOnly.map(\.id))
        // 파일 범위 주석이 억제하는 미사용 import 발견의 기준선.
        let reportedImportLocations = Set(
            UnusedImportAnalyzer.analyze(snapshot).map(\.location)
        )

        // 불필요로 확정된 주석은 뗀 채로 두고 다음 단위를 판정한다. 서로만
        // 참조하는 무시 덩어리는 각각을 따로 보면 둘 다 "다른 주석이 살려 준다"로
        // 보이지만, 하나를 확정하고 나면 나머지는 스스로 죽는다 — 확정분을 누적해
        // 빼야 보고된 주석들을 한꺼번에 떼어도 새 보고가 생기지 않는다는 보장이
        // 성립한다. 판정 순서는 결과 순서와 같은 위치 순으로 고정한다.
        var remainingRetentions = declared
        var remainingCoverage = coverageCount

        var result: [SuperfluousIgnore] = []
        for unit in units.sorted(by: { Self.locationThenID($0.anchor, $1.anchor) }) {
            // 이 단위를 떼면 무시가 실제로 풀리는 정점 — 다른 단위가 함께
            // 덮는 정점은 무시가 남아 새 보고를 만들지 않는다.
            let newlyUncovered = unit.members.filter { remainingCoverage[$0, default: 0] == 1 }
            var isSuperfluous = unit.members.isSubset(of: reachableWithoutAnyIgnore)
                && unit.members.isDisjoint(with: testOnlyWithoutAll)
            if isSuperfluous {
                // 도달성이 같아도 주석이 assign-only나 미사용 import 보고를
                // 억제하고 있을 수 있다 — 그 보고를 떠받치는 주석은 필요하다.
                isSuperfluous = newlyUncovered.isDisjoint(with: assignOnlyWithoutAll)
                    && !exposesIgnoredImport(unit, in: snapshot, reportedLocations: reportedImportLocations)
            }
            if !isSuperfluous {
                // 이 단위만 뗀 세계. 아직 확정되지 않은 다른 단위가 함께 덮는
                // 정점은 무시가 남는다.
                var counterfactual = remainingRetentions
                for member in newlyUncovered
                where counterfactual[member] == .ignoreComment {
                    counterfactual[member] = fallback[member]
                }
                let world = reachabilityWorld(
                    retentions: counterfactual,
                    protocolRequirementOwners: protocolRequirementOwners,
                    graph: graph,
                    alreadyReached: reachableWithoutAnyIgnore
                )
                let killed = reachable.subtracting(world.reachable)
                // 죽는 정점이 생겨도 보고되지 않으면(제외 종류이거나 보고 대상
                // 조상에 숨으면) 주석은 여전히 아무 일도 하지 않는다.
                isSuperfluous = filterReportable(
                    killed.compactMap { graph.node($0) },
                    unreachableIDs: allIDs.subtracting(world.reachable),
                    graph: graph
                ).isEmpty
                if isSuperfluous {
                    // 살아남아도 테스트 전용·assign-only·미사용 import 보고가
                    // 새로 생기면 주석은 그 보고를 억제하고 있던 것이다.
                    let newTestOnly = testOnlyCode(
                        reachable: world.reachable,
                        retentions: world.retentions,
                        inherited: world.inherited,
                        conditionalWitnesses: world.conditionalWitnesses,
                        protocolRequirementOwners: protocolRequirementOwners,
                        graph: graph
                    )
                    isSuperfluous = newTestOnly.allSatisfy {
                        reportedTestOnly.contains($0.id)
                    }
                }
                if isSuperfluous {
                    let newAssignOnly = assignOnlyProperties(
                        in: graph,
                        snapshot: snapshot,
                        reachable: world.reachable,
                        protocolRequirementOwners: protocolRequirementOwners,
                        honoringIgnoreComments: false
                    )
                    isSuperfluous = newAssignOnly.allSatisfy { !newlyUncovered.contains($0.id) }
                        && !exposesIgnoredImport(unit, in: snapshot, reportedLocations: reportedImportLocations)
                }
            }
            if isSuperfluous {
                // 확정된 주석은 이 세계에서 영구히 뗀다. 다른 단위가 함께 덮는
                // 정점은 마지막 덮개가 확정될 때까지 무시가 남는다.
                for member in unit.members {
                    remainingCoverage[member, default: 0] -= 1
                    if remainingCoverage[member] == 0,
                       remainingRetentions[member] == .ignoreComment {
                        remainingRetentions[member] = fallback[member]
                    }
                }
                result.append(SuperfluousIgnore(
                    node: unit.anchor,
                    coveredCount: unit.members.count,
                    coversWholeFile: unit.coversWholeFile
                ))
            }
        }
        return result
    }

    /// 무시 코멘트가 덮는 범위를 그래프에서 복원한다.
    ///
    /// 선언별 주석은 코멘트마다 다른 표식을 남기지 않고 전부 `.ignoreComment`
    /// 하나로 번지므로 범위는 그래프에서 다시 세운다. 무시된 `.member` 부모가
    /// 없는 무시 정점이 한 범위의 꼭대기이고 그 아래의 무시된 자손이 같은 범위다.
    /// `ignore:all` 은 enricher 가 `.ignoreAllComment` 를 남기므로 출처가
    /// 확실할 때만 파일 단위로 묶는다 — 선언별 주석으로 전부 무시된 파일을
    /// 한 단위로 보면 필요한 코멘트 하나가 나머지 불필요 코멘트를 숨긴다.
    private func ignoreUnits(in graph: CodeGraph) -> [IgnoreUnit] {
        let ignored = Set(graph.sortedNodes.filter {
            !$0.isExternal && $0.attributes.contains(.ignoreComment)
        }.map(\.id))
        guard !ignored.isEmpty else { return [] }

        var nodesByPath: [String: [GraphNode]] = [:]
        for node in graph.sortedNodes {
            guard let path = node.location?.path else { continue }
            nodesByPath[path, default: []].append(node)
        }

        var fileScopeIDs: Set<NodeID> = []
        var units: [IgnoreUnit] = []
        for (_, nodes) in nodesByPath.sorted(by: { $0.key < $1.key }) {
            guard nodes.contains(where: { $0.attributes.contains(.ignoreAllComment) })
            else { continue }
            let fileIgnored = nodes.filter { ignored.contains($0.id) }
            // 표식만 있고 무시 정점이 하나도 없는 파일(외부 심볼뿐)은 단위를
            // 만들지 않는다 — 빈 멤버 집합은 닻도 보고도 못 만든다.
            guard !fileIgnored.isEmpty else { continue }
            let members = Set(fileIgnored.map(\.id))
            fileScopeIDs.formUnion(members)
            units.append(IgnoreUnit(
                members: members,
                anchor: fileIgnored.min(by: Self.locationThenID) ?? fileIgnored[0],
                coversWholeFile: true
            ))
        }

        // 전파 무시 정점 중 같은 파일에 무시된 `.member` 부모가 있는 것만
        // 부모 단위에 접힌다. 무시 부모가 없는 전파 정점은 — 주석을 단
        // 컨테이너가 그래프 정점이 아니어서 물려주기만 한 경우 — 어느 단위에도
        // 속하지 않아 그 주석이 영원히 판정되지 않는다. 그런 고아는 스스로
        // 단위 꼭대기가 되어 실제로 존재하는 무시 효과를 판정한다.
        var coveredInherited: Set<NodeID> = []
        for node in graph.sortedNodes
        where ignored.contains(node.id) {
            guard let path = node.location?.path else { continue }
            for edge in graph.outgoingEdges(from: node.id)
            where edge.kind == .member && ignored.contains(edge.target)
                && graph.node(edge.target)?.attributes.contains(.ignoreInherited) == true
                && graph.node(edge.target)?.location?.path == path {
                coveredInherited.insert(edge.target)
            }
        }

        // 나머지는 자기 주석이 있는 정점마다 단위를 세운다. 주석 단 선언이
        // 무시된 부모 아래에 있어도 자기 단위를 가진다 — 부모의 주석은 자손까지
        // 덮지만, 자식의 주석이 억제하는 발견은 자식 주석만 뗐을 때
        // 드러나므로 따로 판정해야 한다. 부모 단위는 무시된 자손을 함께
        // 덮고(부모 주석이 없어져도 자식의 주석은 남는다), 그 겹침은
        // 커버리지 중복도로 판정한다. 조상 주석이 물려준 무시(`.ignoreInherited`)
        // 는 자기 코멘트가 없으므로 단위를 세우지 않는다 — 그 무시를 거둘
        // 코멘트는 물려준 조상의 것이다. 부모·자손 판정은 같은 파일
        // 안에서만 한다 — 다른 파일의 무시된 확장 대상 타입이 이쪽
        // 선언의 독립된 주석을 삼키면 안 된다. 위치가 없는 정점은
        // 같은 파일로 묶을 근거가 없어 자기 단위만 둔다.
        for node in graph.sortedNodes
        where ignored.contains(node.id) && !fileScopeIDs.contains(node.id)
            && (!node.attributes.contains(.ignoreInherited)
                || !coveredInherited.contains(node.id)) {
            guard let path = node.location?.path else {
                units.append(IgnoreUnit(members: [node.id], anchor: node, coversWholeFile: false))
                continue
            }
            var members: Set<NodeID> = [node.id]
            var queue = [node.id]
            var head = 0
            while head < queue.count {
                let current = queue[head]
                head += 1
                for edge in graph.outgoingEdges(from: current)
                where edge.kind == .member && ignored.contains(edge.target)
                    && !fileScopeIDs.contains(edge.target)
                    && graph.node(edge.target)?.location?.path == path {
                    if members.insert(edge.target).inserted { queue.append(edge.target) }
                }
            }
            units.append(IgnoreUnit(members: members, anchor: node, coversWholeFile: false))
        }
        return units
    }

    /// 파일 범위 주석을 떼면 그 파일에서 새로 보고되는 미사용 import 가 있는지.
    ///
    /// 파일 맨 앞의 `ignore:all` 은 첫 import 의 주석 trivia 에도 걸려
    /// 그 import 에 무시 표식을 붙인다. 주석을 떼면 미사용 import 발견이
    /// 새로 생길 수 있고, 그 경우 파일 주석은 그 보고도 억제하고 있던
    /// 것이다. import 는 그래프 정점이 아니므로 도달성 반사실에 잡히지
    /// 않아 스냅샷을 바꿔 별도로 재본다.
    private func exposesIgnoredImport(
        _ unit: IgnoreUnit,
        in snapshot: IndexSnapshot,
        reportedLocations: Set<SourceLocation>
    ) -> Bool {
        guard unit.coversWholeFile,
              let path = unit.anchor.location?.path,
              snapshot.imports.contains(where: {
                  $0.location.path == path && $0.isIgnoredOnlyByFileComment
              })
        else { return false }
        var unignored = snapshot
        unignored.imports = snapshot.imports.map { fact in
            // 자기 `ignore` 주석이 있는 import 는 파일 주석을 떼어도
            // 무시가 남는다 — 파일 지시로만 무시된 import 만 푼다.
            guard fact.location.path == path, fact.isIgnoredOnlyByFileComment
            else { return fact }
            return IndexedImport(
                modulePath: fact.modulePath,
                scopedKind: fact.scopedKind,
                isConditional: fact.isConditional,
                isReexported: fact.isReexported,
                isIgnored: false,
                isIgnoredOnlyByFileComment: false,
                location: fact.location
            )
        }
        return UnusedImportAnalyzer.analyze(unignored).contains {
            $0.location.path == path && !reportedLocations.contains($0.location)
        }
    }

    /// 보존 판정부터 도달성 탐색까지 한 번 돌린 세계.
    ///
    /// 반사실 탐색은 뿌리 선언만 바꾸고 증인 조건·물려받은 보존·역방향
    /// 오버라이드 규칙은 본분석과 똑같이 둔다 — 주석을 떼어도 그 규칙들의
    /// 의미는 변하지 않는다. `alreadyReached` 에 이미 닫힌 도달 집합을 주면
    /// 그 부분집합의 간선은 다시 훑지 않아 단위별 반사실이 죽은 영역만큼만
    /// 걷는다.
    private struct ReachabilityWorld {
        /// 뿌리에서 사용 의미 간선만 따라 도달한 정점.
        let reachable: Set<NodeID>
        /// 도달 가능한 정점으로 거른 보존 근거. `testOnlyCode` 의 뿌리 목록이다.
        let retentions: [NodeID: RetentionReason]
        /// 보존된 멤버 때문에 함께 살아난 조상들.
        let inherited: [NodeID: InheritedRetention]
        /// 소유 타입이 살아야 성립하는 증인과 그 소유자.
        let conditionalWitnesses: [NodeID: NodeID]
    }

    private func reachabilityWorld(
        retentions: [NodeID: RetentionReason],
        protocolRequirementOwners: [NodeID: NodeID],
        graph: CodeGraph,
        alreadyReached: Set<NodeID> = []
    ) -> ReachabilityWorld {
        let (unconditional, conditional) = partitionWitnesses(retentions, graph: graph)
        let inherited = inheritedRetentions(retentions: unconditional, graph: graph)
        let traversal = traverse(
            from: Set(unconditional.keys).union(inherited.keys),
            conditionalWitnesses: conditional,
            protocolRequirementOwners: protocolRequirementOwners,
            in: graph,
            alreadyReached: alreadyReached
        )
        return ReachabilityWorld(
            reachable: traversal.reachable,
            retentions: retentions.filter { traversal.reachable.contains($0.key) },
            inherited: inherited,
            conditionalWitnesses: conditional
        )
    }

    /// 위치가 앞선 정점을 고르는 비교자. 위치가 없거나 같으면 식별자로 자른다.
    private static func locationThenID(_ lhs: GraphNode, _ rhs: GraphNode) -> Bool {
        switch (lhs.location, rhs.location) {
        case let (left?, right?) where left != right:
            return left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return lhs.id < rhs.id
        }
    }
}
