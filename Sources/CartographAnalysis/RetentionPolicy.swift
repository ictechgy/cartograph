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

    public init(options: RetentionOptions = .default) {
        self.options = options
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
        if node.attributes.contains(.ignoreComment) { return .ignoreComment }
        if isUserRetained(node) { return .userConfigured }
        if node.attributes.contains(.implicit) { return .compilerSynthesized }
        if node.attributes.contains(.entryPoint) { return .entryPoint }

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

        if let reason = parentDrivenReason(for: node, in: graph) { return reason }
        if let reason = externalRelationReason(for: node, symbolsWithExternalBase: symbolsWithExternalBase) {
            return reason
        }
        return nil
    }

    // MARK: - 개별 규칙

    private func isUserRetained(_ node: GraphNode) -> Bool {
        if let path = node.location?.path, options.retainedFiles.matchesAny(path) { return true }
        return options.retainedNames.matchesAny(node.name)
            || options.retainedNames.matchesAny(node.qualifiedName)
    }

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

        if node.kind == .enumCase {
            if parent.attributes.contains(.codingKey) { return .codingKey }
            if options.retainRawRepresentableEnumCases, parent.attributes.contains(.rawRepresentable) {
                return .rawRepresentableEnumCase
            }
        }
        if parent.attributes.contains(.propertyWrapper), Self.propertyWrapperMembers.contains(node.name) {
            return .propertyWrapperRequirement
        }
        if parent.attributes.contains(.resultBuilder), node.name.hasPrefix("build") {
            return .resultBuilderRequirement
        }
        if options.retainCodableProperties, parent.attributes.contains(.codable), node.kind == .property {
            return .codableProperty
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
        return node.attributes.contains(.overrideDeclaration) ? .externalOverride : .externalConformance
    }

    /// 포함 관계 간선을 거슬러 부모 선언을 찾는다.
    private func parent(of node: GraphNode, in graph: CodeGraph) -> GraphNode? {
        graph.incomingEdges(to: node.id)
            .first { $0.kind == .member }
            .flatMap { graph.node($0.source) }
    }

    /// `@propertyWrapper` 규약이 요구하는 멤버 이름.
    static let propertyWrapperMembers: Set<String> = ["wrappedValue", "projectedValue"]
}
