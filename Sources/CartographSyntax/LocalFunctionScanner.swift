import CartographCore
import SwiftSyntax

/// 이미 파싱한 트리에서 지역 함수의 범위와 참조 위치를 모은다.
struct LocalFunctionScanner {
    /// 스캐너를 만든다.
    init() {}

    /// 소스 트리에서 local function facts를 만든다.
    func scan(tree: SourceFileSyntax, path: String) -> [LocalFunctionScopeFacts] {
        let collector = LocalFunctionRoots(path: path,
            converter: SourceLocationConverter(fileName: path, tree: tree),
            remapsLocations: tree.tokens(viewMode: .sourceAccurate).contains { $0.text == "#sourceLocation" })
        collector.walk(tree)
        return collector.scopes.sorted { $0.ownerLocation < $1.ownerLocation }
    }
}

private final class LocalFunctionRoots: SyntaxVisitor {
    let path: String
    let converter: SourceLocationConverter
    let remapsLocations: Bool
    var scopes: [LocalFunctionScopeFacts] = []

    init(path: String, converter: SourceLocationConverter, remapsLocations: Bool) {
        self.path = path
        self.converter = converter
        self.remapsLocations = remapsLocations
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
        guard body != nil, token.presence == .present, !DeclarationCollector.isInsideBody(node) else {
            return .skipChildren
        }
        let collector = LocalFunctionBody(root: Syntax(node), path: path, converter: converter)
        collector.walk(node)
        let contextReason = unsupportedReason(node)
        let reason = LocalFunctionBody.preferred([
            remapsLocations ? .sourceLocationRemapping : nil,
            collector.reason,
            contextReason,
            collector.hasUnsupportedSyntax ? .unsupportedSyntax : nil
        ].compactMap { $0 })
        if !collector.functions.isEmpty {
            scopes.append(LocalFunctionScopeFacts(ownerName: DeclarationCollector.unescaped(name),
                ownerLocation: collector.location(token.positionAfterSkippingLeadingTrivia),
                functions: collector.functions,
                references: collector.references.values.sorted { $0.location < $1.location },
                blockedNames: collector.blockedNames,
                hasUnsupportedSyntax: reason != nil,
                reason: reason))
        }
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
