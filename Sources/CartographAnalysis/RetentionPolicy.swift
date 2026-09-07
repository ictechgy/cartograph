import CartographCore

/// "쓰이지 않는 것처럼 보여도 지우면 안 되는" 선언을 판정한다.
///
/// 인덱스 스토어는 컴파일러가 본 참조만 담는다. 런타임 셀렉터, 합성된 Codable,
/// Interface Builder 연결, 원시값 열거형의 동적 생성처럼 컴파일 시점에 보이지
/// 않는 사용은 전부 빠져 있다. 그 공백을 규칙으로 메우는 것이 이 타입의 역할이다.
///
/// 각 판정은 근거(`RetentionReason`)를 함께 남긴다. 사용자가 결과를 믿으려면
/// 왜 살아남았는지 되짚을 수 있어야 하기 때문이다.
public struct RetentionPolicy: Sendable {
    private let options: RetentionOptions
    /// `retained_files` 판정에 쓰는 경로 필터. 기준 디렉터리를 품는다.
    ///
    /// 기준 경로의 여러 표기를 한 번만 펼쳐 두려고 미리 만든다. 정점마다 다시 만들면
    /// 심볼 수만큼 URL 연산이 생긴다.
    private let pathFilter: PathFilter
    /// 다른 도구가 알려 온 언어 경계 너머의 사용.
    private let externalRetentions: ExternalRetentionIndex

    public init(
        options: RetentionOptions = .default,
        basePath: String? = nil,
        externalRetentions: ExternalRetentionIndex = .empty
    ) {
        self.options = options
        self.externalRetentions = externalRetentions
        pathFilter = PathFilter(basePath: basePath)
    }

    /// 보존해야 할 정점과 그 근거.
    ///
    /// - Parameters:
    ///   - graph: 심볼 레벨 그래프.
    ///   - snapshot: 외부 심볼 판정에 필요한 원본 스냅샷.
    public func retainedNodes(in graph: CodeGraph, snapshot: IndexSnapshot) -> [NodeID: RetentionReason] {
        let externalBases = Self.symbolsWithExternalBase(in: snapshot)
        var decisions: [NodeID: RetentionReason] = [:]

        for node in graph.sortedNodes {
            if let reason = reason(for: node, in: graph, symbolsWithExternalBase: externalBases) {
                decisions[node.id] = reason
            }
        }
        return decisions
    }

    /// 분석 범위 밖 선언을 오버라이드하거나 준수하는 심볼의 USR 집합.
    ///
    /// 그래프는 양쪽 끝이 모두 있는 간선만 남기므로, 외부로 향하는 관계는
    /// 그래프가 아니라 원본 스냅샷에서 읽어야 한다. 이 차이를 놓치면
    /// "UIKit 메서드 오버라이드가 전부 미사용으로 보고되는" 결과가 된다.
    static func symbolsWithExternalBase(in snapshot: IndexSnapshot) -> Set<String> {
        let knownUSRs = Set(snapshot.symbols.map(\.usr))
        var result: Set<String> = []
        for reference in snapshot.references
        where reference.kind == .overrides || reference.kind == .conformance {
            if !knownUSRs.contains(reference.targetUSR) {
                result.insert(reference.sourceUSR)
            }
        }
        return result
    }

    /// 정점 하나에 대한 보존 근거. 없으면 nil.
    ///
    /// 규칙 순서는 "사용자가 가장 납득하기 쉬운 설명"이 먼저 오도록 정했다.
    /// 예컨대 `// cartograph:ignore` 가 붙어 있으면 그것이 유일하게 의미 있는 설명이다.
    func reason(
        for node: GraphNode,
        in graph: CodeGraph,
        symbolsWithExternalBase: Set<String>
    ) -> RetentionReason? {
        // 구문 누락을 설명해야 하므로 이미 있던 근거보다 우선한다.
        // 테스트 전용 판정도 소스 접근을 복구하기 전에는 보수적으로 억제한다.
        if node.attributes.contains(.sourceUnavailable) { return .sourceUnavailable }
        if node.attributes.contains(.ignoreComment) { return .ignoreComment }
        if isUserRetained(node) { return .userConfigured }
        // 사용자 설정 다음이다. 외부 도구의 주장은 설정보다 약하고, 인덱스에서 유도한
        // 나머지 규칙보다는 구체적이다(어느 줄이 불렀는지까지 안다).
        if !externalRetentions.isEmpty,
           externalRetentions.retention(
               for: node, names: [ExternalRetentionIndex.syntaxQualifiedName(of: node, in: graph)]
           ) != nil {
            return .externalBridge
        }
        if node.attributes.contains(.implicit) { return .compilerSynthesized }
        if node.attributes.contains(.entryPoint) { return .entryPoint }
        if isTopLevelCode(node, in: graph) { return .entryPoint }

        if options.retainTests {
            if node.attributes.contains(.unitTest) { return .xcTest }
            if node.attributes.contains(.testFunction) || node.attributes.contains(.testSuite) {
                return .swiftTesting
            }
        }
        if options.retainPreviews, node.attributes.contains(.preview) { return .preview }
        if options.retainPublic, node.accessibility.isExposedOutsideModule { return .publicAPI }
        if options.retainObjectiveCAccessible, isObjectiveCAccessible(node) { return .objectiveCAccessible }
        if options.retainInterfaceBuilder, node.attributes.contains(where: \.isInterfaceBuilderRelated) {
            return .interfaceBuilder
        }
        if isDynamicallyDispatched(node) { return .dynamicDispatch }
        if node.attributes.contains(.runtimeManaged) { return .runtimeManaged }

        if let reason = parentDrivenReason(for: node, in: graph) { return reason }
        if let reason = externalRelationReason(for: node, symbolsWithExternalBase: symbolsWithExternalBase) {
            return reason
        }
        return nil
    }

    // MARK: - 개별 규칙

    private func isUserRetained(_ node: GraphNode) -> Bool {
        // 제외와 같은 규칙으로 본다. 절대 경로까지 후보로 두면 프로젝트 루트의 조상
        // 디렉터리 이름이 패턴에 걸려, `retained_files` 한 줄이 프로젝트 전체를 보존하고
        // `dead` 가 아무것도 보고하지 않는다. 제외 쪽과 정확히 같은 모양의 거짓 초록이다.
        if let path = node.location?.path, pathFilter.removes(options.retainedFiles, path) {
            return true
        }
        return options.retainedNames.matchesAny(node.name)
            || options.retainedNames.matchesAny(node.baseName)
            || options.retainedNames.matchesAny(node.qualifiedName)
    }

    /// `main.swift` 의 최상위 선언인지 확인한다.
    ///
    /// Swift 는 `main.swift` 에서만 최상위 코드를 허용하고, 그것이 실행 파일의
    /// 진입점이다. 여기에 `@main` 같은 표식은 붙지 않으므로 그냥 두면 시작점이
    /// 하나도 없는 그래프가 되어 실행 파일 전체가 미사용으로 보고된다.
    ///
    /// 최상위 선언만 본다. `main.swift` 안에 정의한 타입의 멤버까지 살려 두면
    /// 그 파일에 무엇을 넣든 분석이 멎는다.
    private func isTopLevelCode(_ node: GraphNode, in graph: CodeGraph) -> Bool {
        guard let path = node.location?.path,
              Self.lastComponent(of: path) == Self.topLevelCodeFileName
        else { return false }
        return graph.semanticParent(of: node.id) == nil
    }

    static func lastComponent(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Swift 가 최상위 코드를 허용하는 유일한 파일 이름.
    static let topLevelCodeFileName = "main.swift"

    private func isObjectiveCAccessible(_ node: GraphNode) -> Bool {
        if node.attributes.contains(where: \.isObjectiveCRelated) { return true }
        // Clang 계열 USR 은 `c:` 로 시작한다. Swift 심볼이 @objc 로 노출되면
        // 별도의 Clang USR 이 함께 만들어지므로 이것만으로도 판정할 수 있다.
        return node.usr?.hasPrefix("c:") == true
    }

    private func isDynamicallyDispatched(_ node: GraphNode) -> Bool {
        node.attributes.contains(.dynamicMemberLookup)
            || node.attributes.contains(.dynamicReplacement)
            || node.attributes.contains(.dynamicDispatch)
    }

    /// 부모 선언의 성격 때문에 살아남는 경우.
    ///
    /// 원시값 열거형의 케이스, CodingKey, 프로퍼티 래퍼/결과 빌더의 규약 멤버,
    /// Codable 타입의 저장 프로퍼티가 여기에 해당한다.
    private func parentDrivenReason(for node: GraphNode, in graph: CodeGraph) -> RetentionReason? {
        guard let parent = parent(of: node, in: graph) else { return nil }
        let conformances = conformanceAttributes(of: parent, in: graph)

        // @main 타입의 static main() 은 런타임이 부르므로 코드 어디에도 참조가 없다.
        if parent.attributes.contains(.entryPoint), node.baseName == Self.entryPointMethodName {
            return .entryPoint
        }
        if node.kind == .enumCase {
            if conformances.contains(.codingKey) { return .codingKey }
            if conformances.contains(.caseIterable) { return .caseIterableEnumCase }
            if options.retainRawRepresentableEnumCases, conformances.contains(.rawRepresentable) {
                return .rawRepresentableEnumCase
            }
        }
        if parent.attributes.contains(.propertyWrapper) {
            // 래퍼를 붙이는 자리에서 컴파일러가 부르는 init(wrappedValue:)는
            // 인덱스에 호출로 남지 않는다.
            if Self.propertyWrapperMembers.contains(node.baseName) || node.kind == .initializer {
                return .propertyWrapperRequirement
            }
        }
        if parent.attributes.contains(.resultBuilder), node.baseName.hasPrefix("build") {
            return .resultBuilderRequirement
        }
        if options.retainCodableProperties, conformances.contains(.codable), node.kind == .property {
            return .codableProperty
        }
        if parent.attributes.contains(.runtimeManaged), node.kind == .property {
            return .runtimeManaged
        }
        return nil
    }

    /// 분석 범위 밖 선언과 연결되어 살아남는 경우.
    ///
    /// UIKit 메서드 오버라이드나 외부 프로토콜 요구사항 구현은 우리 코드 어디에서도
    /// 호출되지 않지만 프레임워크가 호출한다.
    private func externalRelationReason(
        for node: GraphNode,
        symbolsWithExternalBase: Set<String>
    ) -> RetentionReason? {
        guard let usr = node.usr, symbolsWithExternalBase.contains(usr) else { return nil }
        // 증인 멤버만 보존한다. 타입 자신에게 이 규칙을 적용하면 "이 타입이 한 번이라도
        // 만들어지는가" 를 묻지 않고 살리게 된다. `struct NeverUsed: Equatable {}` 나 아무도
        // 그리지 않는 `View` 가 그래서 한 번도 보고되지 않았다. 준수를 만족시키는 멤버
        // (`body`·`encode(to:)`·`==`)는 그대로 보존되므로 프레임워크가 부르는 것은 안전하다.
        //
        // 익스텐션도 같이 막는다. `extension X: View` 로 쓰면 준수가 익스텐션 노드에 붙고,
        // 그 노드의 `extends` 간선이 방금 보존을 뗀 타입을 되살린다. 같은 코드의 두 표기가
        // 반대 답을 내면 판정이 코드가 아니라 작성 취향의 함수가 된다.
        guard !node.kind.isTypeDeclaration, node.kind != .extensionDeclaration else { return nil }
        return node.attributes.contains(.overrideDeclaration) ? .externalOverride : .externalConformance
    }

    /// 부모 타입 본체와 그 익스텐션들이 함께 선언한 준수 표식.
    ///
    /// `extension Money: Codable {}` 처럼 준수를 익스텐션에 선언하는 것은 흔한
    /// 스타일이다. 이때 표식은 익스텐션 쪽에 붙어, 타입 본체만 보면 Codable
    /// 타입의 저장 프로퍼티가 통째로 미사용으로 보고된다.
    ///
    /// 상속/준수 절에서만 나오는 표식으로 한정한다. `@main`, `@propertyWrapper`
    /// 같은 것은 익스텐션에 붙을 수 없어 옮겨 올 이유가 없다.
    private func conformanceAttributes(of parent: GraphNode, in graph: CodeGraph) -> Set<SymbolAttribute> {
        var result = parent.attributes.intersection(Self.conformanceDerivedAttributes)
        for edge in graph.incomingEdges(to: parent.id) where edge.kind == .extends {
            guard let extensionNode = graph.node(edge.source) else { continue }
            result.formUnion(extensionNode.attributes.intersection(Self.conformanceDerivedAttributes))
        }
        return result
    }

    /// 익스텐션에서 타입으로 옮겨 오는 표식.
    static let conformanceDerivedAttributes: Set<SymbolAttribute> = [
        .codable, .codingKey, .rawRepresentable, .caseIterable,
    ]

    /// 포함 관계를 거슬러 의미상의 부모 선언을 찾는다.
    ///
    /// 익스텐션을 건너뛴다. `extension Status { }` 안의 케이스도 열거형 본체의
    /// 성질(원시값, CodingKey)을 따라야 하기 때문이다.
    private func parent(of node: GraphNode, in graph: CodeGraph) -> GraphNode? {
        graph.semanticParent(of: node.id).flatMap { graph.node($0) }
    }

    /// `@propertyWrapper` 규약이 요구하는 멤버 이름.
    static let propertyWrapperMembers: Set<String> = ["wrappedValue", "projectedValue"]
    /// `@main` 타입이 제공해야 하는 진입 메서드 이름.
    static let entryPointMethodName = "main"
}
