import CartographCore
import SwiftSyntax

/// 이미 파싱한 트리에서 지역 함수의 범위와 참조 위치를 모은다.
struct LocalFunctionScanner {
    /// 스캐너를 만든다.
    init() {}

    /// 소스 트리에서 local function facts를 만든다.
    ///
    /// - Parameters:
    ///   - converter: 분석기가 만든 변환기를 그대로 쓴다. 파일마다 줄 표를 다시 만들지 않는다.
    ///   - onBodyWalk: 바깥 함수 본문을 끝까지 훑을 때마다 불린다. 테스트가 지역 함수 후보가 있는 본문만 훑는지 센다.
    func scan(
        tree: SourceFileSyntax, path: String, converter: SourceLocationConverter,
        onBodyWalk: (() -> Void)? = nil
    ) -> [LocalFunctionScopeFacts] {
        let collector = LocalFunctionRoots(tree: tree, path: path, converter: converter, onBodyWalk: onBodyWalk)
        collector.walk(tree)
        return collector.scopes.sorted { $0.ownerLocation < $1.ownerLocation }
    }
}

private final class LocalFunctionRoots: SyntaxVisitor {
    let path: String
    let converter: SourceLocationConverter
    private let tree: SourceFileSyntax
    private let onBodyWalk: (() -> Void)?
    /// 파일의 모든 토큰을 훑는 검사라 범위가 하나라도 생길 때만 본다.
    private lazy var remapsLocations = tree.tokens(viewMode: .sourceAccurate).contains { $0.text == "#sourceLocation" }
    var scopes: [LocalFunctionScopeFacts] = []

    init(tree: SourceFileSyntax, path: String, converter: SourceLocationConverter, onBodyWalk: (() -> Void)?) {
        self.tree = tree
        self.path = path
        self.converter = converter
        self.onBodyWalk = onBodyWalk
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        collect(node, name: node.name.text, token: node.name, body: node.body)
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        collect(node, name: "init", token: node.initKeyword, body: node.body)
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        collect(node, name: "deinit", token: node.deinitKeyword, body: node.body)
    }

    private func collect(
        _ node: some SyntaxProtocol, name: String, token: TokenSyntax, body: CodeBlockSyntax?
    ) -> SyntaxVisitorContinueKind {
        // 함수 선언 자손이 없으면 본문을 끝까지 훑어도 지역 함수가 하나도 모이지 않는다. 바깥 함수의 99% 가
        // 그렇고, 그 본문마다 참조 위치를 전부 모았다가 버리면 콜드 실행 구문 단계의 약 1/4 을 썼다.
        guard body != nil, token.presence == .present, !DeclarationCollector.isInsideBody(node),
              NestedFunctionProbe.contains(node)
        else { return .skipChildren }
        onBodyWalk?()
        let collector = LocalFunctionBody(root: Syntax(node), path: path, converter: converter)
        collector.walk(node)
        guard !collector.functions.isEmpty else { return .skipChildren }
        let reason = LocalFunctionBody.preferred([
            remapsLocations ? .sourceLocationRemapping : nil,
            collector.reason,
            unsupportedReason(node),
            collector.hasUnsupportedSyntax ? .unsupportedSyntax : nil
        ].compactMap { $0 })
        scopes.append(LocalFunctionScopeFacts(ownerName: DeclarationCollector.unescaped(name),
            ownerLocation: collector.location(token.positionAfterSkippingLeadingTrivia),
            functions: collector.functions,
            references: collector.references.values.sorted { $0.location < $1.location },
            blockedNames: collector.blockedNames,
            hasUnsupportedSyntax: reason != nil,
            reason: reason))
        return .skipChildren
    }

    private func unsupportedReason(_ node: some SyntaxProtocol) -> LocalFunctionSkipReason? {
        var current: Syntax? = Syntax(node)
        while let syntax = current {
            if syntax.is(IfConfigDeclSyntax.self) { return .conditionalCompilation }
            if let attributed = syntax.asProtocol(WithAttributesSyntax.self),
               LocalFunctionBody.hasUnknownAttributes(attributed.attributes) {
                return .unknownAttributes
            }
            current = syntax.parent
        }
        return node.hasError ? .parseError : nil
    }
}

/// 바깥 함수 안에 함수 선언이 하나라도 있는지만 본다. 지역 타입·매크로 안의 func 까지 세는 과대 근사지만,
/// 없다고 답하면 같은 보기 방식으로 훑는 LocalFunctionBody 도 지역 함수를 하나도 모으지 못하므로 결과가 같다.
/// `func` 키워드 토큰으로 보면 파싱 복구로 키워드가 빠진 선언을 놓친다.
private final class NestedFunctionProbe: SyntaxVisitor {
    private let root: SyntaxIdentifier
    private var found = false

    private init(root: SyntaxIdentifier) {
        self.root = root
        super.init(viewMode: .sourceAccurate)
    }

    static func contains(_ node: some SyntaxProtocol) -> Bool {
        let probe = NestedFunctionProbe(root: node.id)
        probe.walk(node)
        return probe.found
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.id != root { found = true }
        return found ? .skipChildren : .visitChildren
    }
}

private final class LocalFunctionBody: SyntaxVisitor {
    let root: Syntax
    let path: String
    let converter: SourceLocationConverter
    var functions: [LocalFunctionFacts] = []
    var references: [CartographCore.SourceLocation: LocalFunctionReferenceFacts] = [:]
    var blockedNames: Set<String> = []
    var hasUnsupportedSyntax = false
    var reason: LocalFunctionSkipReason?
    private var localOwners: [CartographCore.SourceLocation] = []

    init(root: Syntax, path: String, converter: SourceLocationConverter) {
        self.root = root
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    func location(_ position: AbsolutePosition) -> CartographCore.SourceLocation {
        let point = converter.location(for: position)
        return CartographCore.SourceLocation(path: path, line: point.line, column: point.column)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard Syntax(node).id != root.id else { return .visitChildren }
        let point = location(node.name.positionAfterSkippingLeadingTrivia)
        let scope = lexicalScope(of: node)
        let labels = node.signature.parameterClause.parameters.map { $0.firstName.text + ":" }.joined()
        let name = DeclarationCollector.unescaped(node.name.text)
        let reason = Self.preferred([
            node.hasError ? .parseError : nil,
            node.name.presence == .present && node.body != nil ? nil : .unsupportedSyntax,
            Self.hasUnknownAttributes(node.attributes) ? .unknownAttributes : nil
        ].compactMap { $0 })
        functions.append(LocalFunctionFacts(name: name, indexName: "\(name)(\(labels))", location: point,
            parentLocation: localOwners.last, scopeStart: location(scope.positionAfterSkippingLeadingTrivia),
            scopeEnd: location(scope.endPositionBeforeTrailingTrivia),
            isSupported: reason == nil,
            reason: reason))
        localOwners.append(point)
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        if Syntax(node).id != root.id { localOwners.removeLast() }
    }

    private func lexicalScope(of node: FunctionDeclSyntax) -> Syntax {
        var current = node.parent
        while let syntax = current {
            if syntax.is(CodeBlockSyntax.self) || syntax.is(ClosureExprSyntax.self)
                || syntax.is(SwitchCaseSyntax.self) { return syntax }
            current = syntax.parent
        }
        return root
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let parent = node.parent
        let isMember = parent?.as(MemberAccessExprSyntax.self)?.declName.id == node.id
        let callExpression = isMember ? parent : Syntax(node)
        let isCall = callExpression?.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id == callExpression?.id
        let point = location(node.baseName.positionAfterSkippingLeadingTrivia)
        references[point] = LocalFunctionReferenceFacts(name: DeclarationCollector.unescaped(node.baseName.text),
            location: point, localOwner: localOwners.last, isCall: isCall, isUnqualified: !isMember)
        return .visitChildren
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        guard token.presence == .present, let owner = localOwners.last else { return .skipChildren }
        let point = location(token.positionAfterSkippingLeadingTrivia)
        // 생성자·서브스크립트·연산자의 인덱스 이름은 소스 철자와 다르다. 대상을
        // 이름으로 추측하지 않고 실제 토큰 위치의 컴파일러 참조를 이 소유자에 붙인다.
        if references[point] == nil {
            references[point] = LocalFunctionReferenceFacts(name: token.text, location: point,
                localOwner: owner, isCall: false, isUnqualified: false)
        }
        return .skipChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        block((node.secondName ?? node.firstName).text)
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        block((node.secondName ?? node.firstName).text)
        return .visitChildren
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        block(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ClosureCaptureSyntax) -> SyntaxVisitorContinueKind {
        if node.initializer != nil {
            block(node.name.text)
        } else {
            let point = location(node.name.positionAfterSkippingLeadingTrivia)
            references[point] = LocalFunctionReferenceFacts(name: DeclarationCollector.unescaped(node.name.text),
                location: point, localOwner: localOwners.last, isCall: false, isUnqualified: true)
        }
        return .visitChildren
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        block(node.identifier.text)
        return .visitChildren
    }

    private func block(_ name: String) {
        if name != "_" { blockedNames.insert(DeclarationCollector.unescaped(name)) }
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        if Self.hasUnknownAttributes(AttributeListSyntax([.attribute(node)])) {
            markUnsupported(.unknownAttributes)
        }
        return .skipChildren
    }

    static func hasUnknownAttributes(_ list: AttributeListSyntax) -> Bool {
        let remaining = list.filter {
            guard case let .attribute(attribute) = $0 else { return true }
            return attribute.attributeName.trimmedDescription != "Sendable" || attribute.arguments != nil
        }
        return DeclarationCollector.hasUnresolvedAttributes(in: remaining)
    }

    override func visit(_: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        markUnsupported(.conditionalCompilation)
        return .visitChildren
    }

    override func visit(_: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        markUnsupported(.macroExpansion)
        return .skipChildren
    }

    override func visit(_: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        markUnsupported(.macroExpansion)
        return .skipChildren
    }

    override func visit(_: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        markUnsupported(.localType)
        return .skipChildren
    }

    override func visit(_: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        markUnsupported(.localType)
        return .skipChildren
    }

    override func visit(_: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        markUnsupported(.localType)
        return .skipChildren
    }

    override func visit(_: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        markUnsupported(.localType)
        return .skipChildren
    }

    private func markUnsupported(_ reason: LocalFunctionSkipReason) {
        hasUnsupportedSyntax = true
        self.reason = Self.preferred([self.reason, reason].compactMap { $0 })
    }

    static func preferred(_ reasons: [LocalFunctionSkipReason]) -> LocalFunctionSkipReason? {
        reasons.min {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.rawValue < $1.rawValue
        }
    }
}
