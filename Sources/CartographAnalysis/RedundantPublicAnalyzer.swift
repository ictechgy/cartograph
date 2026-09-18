import CartographCore

/// 자기 모듈 밖에서는 참조되지 않는 public 선언.
///
/// "지워도 된다"가 아니라 "공개할 필요가 없다"는 발견이다. 같은 모듈 안에서
/// 쓰이지만 다른 모듈은 쓰지 않는 public 선언은 internal 로 줄일 수 있다.
/// 참조가 하나도 없는 선언은 여기 오지 않는다 — 의도된 API 표면일 수 있고,
/// 미사용 여부는 `dead` 의 다른 보고가 답한다. 다만 이 인덱스 밖의 소비자
/// (다른 저장소의 앱, 배포된 프레임워크의 클라이언트)는 볼 수 없으므로,
/// 그런 소비자가 있으면 이 발견은 틀린다 — 도구는 분석 범위 안의 모듈만
/// 증거로 삼는다.
public struct RedundantPublic: Sendable, Equatable {
    /// 발견된 선언.
    public let node: GraphNode
    /// 자기 모듈 안에서 확인된 참조 수. 0이면 발견되지 않는다.
    public let referenceCount: Int

    public init(node: GraphNode, referenceCount: Int) {
        self.node = node
        self.referenceCount = referenceCount
    }
}

/// public 접근 수준이 필요 없는 선언을 찾는다.
///
/// 판정은 두 질문이다.
/// 1. 이 선언은 자기 모듈 밖에서 참조되는가? — 참조의 출처 모듈을 본다.
/// 2. 이 선언을 참조하는 공개 선언이 있는가? — 인터페이스 자리의 참조는
///    감싸는 선언이 공개인 한 대상을 공개로 요구한다. 본문 자리의 참조는
///    요구하지 않는다(`ReferencePosition`).
///
/// 그래서 이 판정은 참조 자리 분류가 필요하다. 본문으로 잘못 분류한 참조는
/// 필요 없는 공개 노출을 요구하지 않아 오탐을 만들므로, 분류하지 못한 참조는
/// 인터페이스로 간주해 보고를 억제한다.
struct RedundantPublicAnalyzer: Sendable {
    private let graph: CodeGraph
    private let referencesByTarget: [String: [IndexedReference]]
    private let symbolsByUSR: [String: IndexedSymbol]
    private let parametersByUSR: [String: IndexedParameter]
    private let fileModulesByPath: [String: String]
    /// 오버라이드·프로토콜 증인인 선언의 USR.
    private let overriders: Set<String>
    private let testModules: Set<String>
    private let retentions: [NodeID: RetentionReason]

    init(
        graph: CodeGraph,
        snapshot: IndexSnapshot,
        testModules: Set<String>,
        retentions: [NodeID: RetentionReason]
    ) {
        self.graph = graph
        referencesByTarget = Dictionary(grouping: snapshot.references, by: \.targetUSR)
        symbolsByUSR = snapshot.symbolsByUSR()
        parametersByUSR = Dictionary(
            snapshot.parameters.map { ($0.usr, $0) }, uniquingKeysWith: { first, _ in first }
        )
        fileModulesByPath = snapshot.fileModuleUsages.compactMapValues(\.owningModule)
        // `overrideOf` 관계는 오버라이드하는 쪽의 발생에 붙는다. 요구사항 구현도
        // 같은 관계로 기록되므로 이 표식 하나로 오버라이드와 증인을 함께 거른다.
        overriders = Set(snapshot.references.filter { $0.kind == .overrides }.map(\.sourceUSR))
        self.testModules = testModules
        self.retentions = retentions
    }

    /// 위치 순으로 발견을 돌려준다.
    func findings(
        reachable: Set<NodeID>,
        honoringIgnoreComments: Bool = true
    ) -> [RedundantPublic] {
        graph.sortedNodes.compactMap {
            finding(for: $0, reachable: reachable, honoringIgnoreComments: honoringIgnoreComments)
        }
    }

    /// 정점 하나의 판정. 조건이 맞지 않으면 nil.
    func finding(
        for node: GraphNode,
        reachable: Set<NodeID>,
        honoringIgnoreComments: Bool = true
    ) -> RedundantPublic? {
        guard let usr = node.usr, !node.isExternal else { return nil }
        guard node.accessibility.isExposedOutsideModule else { return nil }
        guard Self.candidateKinds.contains(node.kind) else { return nil }
        guard reachable.contains(node.id) else { return nil }
        guard !isExcluded(node, honoringIgnoreComments: honoringIgnoreComments) else { return nil }
        guard isEffectivelyExposed(node) else { return nil }
        guard !overriders.contains(usr) else { return nil }
        guard !isProtocolRequirement(node) else { return nil }

        var referenceCount = 0
        for reference in referencesByTarget[usr] ?? [] where reference.sourceUSR != usr {
            // 출처 모듈을 모르면 밖에서 왔을 수 있다. 보고하지 않는다.
            guard let module = sourceModule(reference), module == node.module else { return nil }
            referenceCount += 1
            if isForcing(reference) { return nil }
        }
        // 참조가 없는 public 선언은 의도된 표면일 수 있다. `retain_public` 이
        // 살려 둔 API 전체를 "internal 로 줄이라"고 하면 보고가 쏟아진다.
        // 미사용 여부는 `dead` 의 다른 보고가 답한다.
        guard referenceCount > 0 else { return nil }
        return RedundantPublic(node: node, referenceCount: referenceCount)
    }

    // MARK: - 판정 재료

    private static let candidateKinds: Set<SymbolKind> = [
        .classType, .structType, .enumType, .protocolType, .typeAlias,
        .function, .method, .initializer, .subscriptDeclaration, .property, .variable, .macro,
    ]

    /// 이 근거로 살아 있는 선언은 인덱스 밖과의 관계가 이미 증명된 것들이다.
    /// 그런 선언에 접근 수준 변경을 권하면 증명된 관계를 깨뜨린다.
    ///
    /// `publicAPI` 는 `retain_public` 이 켜진 상태다 — 공개 표면이 의도적이라고
    /// 선언한 것이므로 이 규칙은 조용해야 한다. 그러지 않으면 라이브러리마다
    /// 자기 공개 API 를 모듈 안에서 읽는다는 이유로 전체 표면이 보고된다.
    /// Periphery 도 같은 모드에서 redundant-public 분석을 끈다.
    private static let externallyEngagedReasons: Set<RetentionReason> = [
        .entryPoint, .xcTest, .swiftTesting, .preview, .objectiveCAccessible,
        .interfaceBuilder, .runtimeManaged, .dynamicDispatch, .externalOverride,
        .externalConformance, .userConfigured, .externalBridge, .publicAPI,
    ]

    private func isExcluded(_ node: GraphNode, honoringIgnoreComments: Bool) -> Bool {
        let attributes = node.attributes
        if attributes.contains(.implicit) || attributes.contains(.sourceUnavailable)
            || attributes.contains(.overrideDeclaration) { return true }
        if honoringIgnoreComments, attributes.contains(.ignoreComment) { return true }
        if attributes.contains(.runtimeManaged) || attributes.contains(.dynamicDispatch)
            || attributes.contains(.dynamicReplacement) || attributes.contains(.dynamicMemberLookup) {
            return true
        }
        if attributes.contains(.entryPoint) || attributes.contains(.unitTest)
            || attributes.contains(.testFunction) || attributes.contains(.testSuite)
            || attributes.contains(.preview) {
            return true
        }
        if attributes.contains(where: \.isObjectiveCRelated)
            || attributes.contains(where: \.isInterfaceBuilderRelated) {
            return true
        }
        if node.module.map(testModules.contains) == true { return true }
        guard let reason = retentions[node.id] else { return false }
        return Self.externallyEngagedReasons.contains(reason)
    }

    /// 선언을 감싸는 타입까지 모두 공개여야 실제로 모듈 밖에서 보인다.
    ///
    /// internal 타입 안의 명시적 public 은 컴파일러가 조용히 internal 로 깎는다.
    /// 그런 선언은 공개 API 표면이 아니므로 대상에서 뺀다.
    private func isEffectivelyExposed(_ node: GraphNode) -> Bool {
        guard node.accessibility.isExposedOutsideModule else { return false }
        var current = node.id
        var visited: Set<NodeID> = [current]
        while let parent = graph.semanticParent(of: current) {
            guard visited.insert(parent).inserted else { return false }
            // 그래프 밖 타입(외부 익스텐션 대상)은 공개로 본다. SDK 타입의 public
            // 멤버는 실제로 모듈 밖에서 보인다.
            guard let parentNode = graph.node(parent) else { return true }
            if !parentNode.accessibility.isExposedOutsideModule { return false }
            current = parent
        }
        return true
    }

    /// 프로토콜이 직접 포함하는 요구사항인지 여부.
    ///
    /// 요구사항의 접근 수준은 프로토콜이 정한다 — 따로 낮출 수 없다.
    private func isProtocolRequirement(_ node: GraphNode) -> Bool {
        graph.incomingEdges(to: node.id).contains { edge in
            edge.kind == .member && graph.node(edge.source)?.kind == .protocolType
        }
    }

    /// 참조가 일어난 파일이 컴파일된 모듈.
    private func sourceModule(_ reference: IndexedReference) -> String? {
        if let symbol = symbolsByUSR[reference.sourceUSR], !symbol.module.isEmpty {
            return symbol.module
        }
        if let parameter = parametersByUSR[reference.sourceUSR],
           let function = symbolsByUSR[parameter.functionUSR], !function.module.isEmpty {
            return function.module
        }
        if let path = reference.location?.path {
            return fileModulesByPath[path]
        }
        return nil
    }

    /// 이 참조가 대상을 공개로 요구하는가.
    ///
    /// 본문 자리의 참조는 요구하지 않는다. 인터페이스 자리의 참조는 그것을 담은
    /// 선언이 공개일 때만 요구한다 — 감싸는 선언이 internal 이면 그 인터페이스는
    /// 모듈 밖에서 보이지 않아 대상도 internal 이어도 된다.
    private func isForcing(_ reference: IndexedReference) -> Bool {
        guard reference.position != .body else { return false }
        guard let source = sourceNode(reference) else { return true }
        return isEffectivelyExposed(source)
    }

    private func sourceNode(_ reference: IndexedReference) -> GraphNode? {
        if let node = graph.node(NodeID(reference.sourceUSR)) { return node }
        if let parameter = parametersByUSR[reference.sourceUSR] {
            return graph.node(NodeID(parameter.functionUSR))
        }
        return nil
    }
}
