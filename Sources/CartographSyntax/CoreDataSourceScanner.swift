import CartographCore
import SwiftOperators
import SwiftParser
import SwiftSyntax

/// Core Data container와 fetch의 제한된 지역 값 흐름을 구문 사실로 만든다.
public struct CoreDataSourceScanner: Sendable {
    public init() {}

    /// 함수의 같은 직선 scope에 있는 불변 container·context·request만 연결한다.
    public func scan(source: String, path: String) -> RuntimeFileFacts {
        let parsed = Parser.parse(source: source)
        let folded = OperatorTable.standardOperators.foldAll(parsed) { _ in }
            .as(SourceFileSyntax.self) ?? parsed
        return scan(tree: folded, path: path)
    }

    /// RuntimeFactScanner가 이미 파싱한 트리를 재사용한다.
    func scan(tree: SourceFileSyntax, path: String) -> RuntimeFileFacts {
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let collector = CoreDataSourceCollector(path: path, converter: converter)
        collector.walk(tree)
        return RuntimeFileFacts(
            path: path,
            boundaries: collector.boundaries.sorted {
                ($0.location, $0.kind.rawValue, $0.api) < ($1.location, $1.kind.rawValue, $1.api)
            }
        )
    }
}

private final class CoreDataSourceCollector: SyntaxVisitor {
    private struct Container {
        let bindingName: String
        let modelName: String
        let constructorLocation: CartographCore.SourceLocation
    }

    private struct Context {
        let container: Container
        let viewContextLocation: CartographCore.SourceLocation
        let scope: Int
    }

    private struct Request {
        let entityName: String
        let constructorLocation: CartographCore.SourceLocation
        let resultTypeLocation: CartographCore.SourceLocation
        let hasConcreteResultType: Bool
    }

    private struct ContainerCall {
        let modelName: String?
        let constructorLocation: CartographCore.SourceLocation
        let reason: String?
    }

    private struct RequestCall {
        let entityName: String?
        let constructorLocation: CartographCore.SourceLocation
        let resultTypeLocation: CartographCore.SourceLocation?
        let resultTypeName: String?
        let reason: String?
    }

    private let path: String
    private let converter: SourceLocationConverter
    private var containers: [Int: [String: Container]] = [:]
    private var contexts: [Int: [String: Context]] = [:]
    private var requests: [Int: [String: Request]] = [:]
    private var invalidContainerContexts: [Int: Set<String>] = [:]
    private var declaredNames: [Int: Set<String>] = [:]
    private var scopes: [Int] = []
    private var functions: [CartographCore.SourceLocation] = []
    private var conditionalDepth = 0
    private var closureDepth = 0
    private(set) var boundaries: [RuntimeBoundary] = []

    init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        functions.append(location(node.name))
        return .visitChildren
    }

    override func visitPost(_: FunctionDeclSyntax) { functions.removeLast() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        functions.append(location(node.initKeyword))
        return .visitChildren
    }

    override func visitPost(_: InitializerDeclSyntax) { functions.removeLast() }

    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.positionAfterSkippingLeadingTrivia.utf8Offset)
        return .visitChildren
    }

    override func visitPost(_: CodeBlockSyntax) {
        if let scope = scopes.popLast() {
            containers.removeValue(forKey: scope)
            contexts.removeValue(forKey: scope)
            requests.removeValue(forKey: scope)
            invalidContainerContexts.removeValue(forKey: scope)
            declaredNames.removeValue(forKey: scope)
        }
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        invalidateCapturedBindings(in: node)
        closureDepth += 1
        return .visitChildren
    }

    override func visitPost(_: ClosureExprSyntax) { closureDepth -= 1 }

    override func visit(_: IfExprSyntax) -> SyntaxVisitorContinueKind { enterConditional() }
    override func visitPost(_: IfExprSyntax) { leaveConditional() }
    override func visit(_: SwitchExprSyntax) -> SyntaxVisitorContinueKind { enterConditional() }
    override func visitPost(_: SwitchExprSyntax) { leaveConditional() }
    override func visit(_: ForStmtSyntax) -> SyntaxVisitorContinueKind { enterConditional() }
    override func visitPost(_: ForStmtSyntax) { leaveConditional() }
    override func visit(_: WhileStmtSyntax) -> SyntaxVisitorContinueKind { enterConditional() }
    override func visitPost(_: WhileStmtSyntax) { leaveConditional() }
    override func visit(_: RepeatStmtSyntax) -> SyntaxVisitorContinueKind { enterConditional() }
    override func visitPost(_: RepeatStmtSyntax) { leaveConditional() }
    override func visit(_: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind { enterConditional() }
    override func visitPost(_: IfConfigDeclSyntax) { leaveConditional() }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.bindings.count == 1,
              let binding = node.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
              let initializer = binding.initializer?.value else { return .visitChildren }
        let name = SyntaxIdentifiers.unescaped(identifier.identifier.text)
        if let scope = currentScope { declaredNames[scope, default: []].insert(name) }
        let immutable = node.bindingSpecifier.text == "let"
        if let call = containerCall(initializer) {
            recordContainer(name: name, call: call, immutable: immutable)
        } else if let context = contextInitializer(initializer) {
            recordContext(name: name, context: context, immutable: immutable)
        } else if let request = requestCall(initializer) {
            recordRequest(name: name, call: request, immutable: immutable)
        } else if let reference = initializer.as(DeclReferenceExprSyntax.self) {
            invalidateBinding(named: SyntaxIdentifiers.unescaped(reference.baseName.text))
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              SyntaxIdentifiers.unescaped(member.declName.baseName.text) == "fetch" else {
            invalidateEscapedArguments(of: node)
            invalidateMutatingReceiver(of: node)
            return .visitChildren
        }
        recordFetch(node, member: member)
        return .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.operator.is(AssignmentExprSyntax.self) else { return .visitChildren }
        invalidateAssignedExpression(node.leftOperand)
        return .visitChildren
    }

    private var currentScope: Int? { scopes.last }
    private var isSupportedScope: Bool {
        currentScope != nil && !functions.isEmpty && conditionalDepth == 0 && closureDepth == 0
    }

    private var enclosingDeclaration: CartographCore.SourceLocation? { functions.last }

    private func recordContainer(name: String, call: ContainerCall, immutable: Bool) {
        let scopeReason = isSupportedScope
            ? nil : "Core Data containers require a straight-line local function scope."
        let bindingReason = immutable ? scopeReason : "Core Data containers must be immutable local bindings."
        let reason = call.reason ?? bindingReason
        boundaries.append(RuntimeBoundary(
            kind: .coreDataContainer,
            api: "NSPersistentContainer.init(name:)",
            location: call.constructorLocation,
            calleeLocation: call.constructorLocation,
            enclosingDeclarationLocation: enclosingDeclaration,
            name: call.modelName,
            nameOrigin: call.modelName == nil ? .dynamic : .literal,
            coreDataModelName: call.modelName,
            coreDataContainerLocation: call.constructorLocation,
            reason: reason
        ))
        guard reason == nil, let scope = currentScope, let modelName = call.modelName else { return }
        containers[scope, default: [:]][name] = Container(
            bindingName: name,
            modelName: modelName,
            constructorLocation: call.constructorLocation
        )
    }

    private func recordContext(name: String, context: Context, immutable: Bool) {
        guard immutable, isSupportedScope, currentScope == context.scope, let scope = currentScope else { return }
        contexts[scope, default: [:]][name] = context
    }

    private func recordRequest(name: String, call: RequestCall, immutable: Bool) {
        guard immutable, isSupportedScope, let scope = currentScope,
              call.reason == nil, let entityName = call.entityName,
              let resultLocation = call.resultTypeLocation,
              let resultType = call.resultTypeName else { return }
        requests[scope, default: [:]][name] = Request(
            entityName: entityName,
            constructorLocation: call.constructorLocation,
            resultTypeLocation: resultLocation,
            hasConcreteResultType: resultType != "NSManagedObject"
        )
    }

    private func recordFetch(_ call: FunctionCallExprSyntax, member: MemberAccessExprSyntax) {
        let fetchLocation = location(member.declName.baseName)
        let request = requestArgument(call)
        let context = member.base.flatMap(contextExpression)
        let unsupported = !isSupportedScope
            ? "Core Data fetches require a straight-line local function scope."
            : (context == nil ? "The fetch context is not derived from a proven local persistent container."
                : (request == nil ? "The fetch request is not a proven immutable local literal request." : nil))
        if request?.hasConcreteResultType == true { return }
        boundaries.append(RuntimeBoundary(
            kind: .coreDataFetch,
            api: "NSManagedObjectContext.fetch(_:)",
            location: fetchLocation,
            calleeLocation: fetchLocation,
            enclosingDeclarationLocation: enclosingDeclaration,
            name: request?.entityName,
            nameOrigin: request == nil ? .dynamic : .literal,
            coreDataModelName: context?.container.modelName,
            coreDataContainerLocation: context?.container.constructorLocation,
            coreDataContextLocation: context?.viewContextLocation,
            coreDataRequestLocation: request?.constructorLocation,
            coreDataResultTypeLocation: request?.resultTypeLocation,
            reason: unsupported
        ))
    }

    private func containerCall(_ expression: ExprSyntax) -> ContainerCall? {
        guard let call = expression.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
              SyntaxIdentifiers.unescaped(callee.baseName.text) == "NSPersistentContainer" else { return nil }
        let location = self.location(callee.baseName)
        guard call.arguments.count == 1, let argument = call.arguments.first,
              argument.label?.text == "name" else {
            return ContainerCall(
                modelName: nil,
                constructorLocation: location,
                reason: "Only NSPersistentContainer(name: <literal>) uses main-bundle build evidence."
            )
        }
        let name = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        return ContainerCall(
            modelName: name,
            constructorLocation: location,
            reason: name == nil ? "The persistent container name is not one string literal." : nil
        )
    }

    private func requestCall(_ expression: ExprSyntax) -> RequestCall? {
        guard let call = expression.as(FunctionCallExprSyntax.self),
              let generic = call.calledExpression.as(GenericSpecializationExprSyntax.self),
              let callee = generic.expression.as(DeclReferenceExprSyntax.self),
              SyntaxIdentifiers.unescaped(callee.baseName.text) == "NSFetchRequest" else { return nil }
        let constructor = location(callee.baseName)
        guard generic.genericArgumentClause.arguments.count == 1,
              let argument = generic.genericArgumentClause.arguments.first,
              case let .type(resultType) = argument.argument,
              call.arguments.count == 1,
              let entity = call.arguments.first,
              entity.label?.text == "entityName" else {
            return RequestCall(
                entityName: nil,
                constructorLocation: constructor,
                resultTypeLocation: nil,
                resultTypeName: nil,
                reason: "Only one typed NSFetchRequest(entityName: <literal>) is supported."
            )
        }
        let entityName = entity.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        return RequestCall(
            entityName: entityName,
            constructorLocation: constructor,
            resultTypeLocation: location(resultType),
            resultTypeName: resultType.trimmedDescription,
            reason: entityName == nil ? "The fetch entity name is not one string literal." : nil
        )
    }

    private func contextExpression(_ expression: ExprSyntax) -> Context? {
        if let reference = expression.as(DeclReferenceExprSyntax.self),
           let scope = currentScope,
           let context = contexts[scope]?[SyntaxIdentifiers.unescaped(reference.baseName.text)],
           invalidContainerContexts[scope]?.contains(context.container.bindingName) != true {
            return context
        }
        guard let access = expression.as(MemberAccessExprSyntax.self),
              SyntaxIdentifiers.unescaped(access.declName.baseName.text) == "viewContext",
              let base = access.base?.as(DeclReferenceExprSyntax.self),
              let scope = currentScope else { return nil }
        let containerName = SyntaxIdentifiers.unescaped(base.baseName.text)
        guard
              invalidContainerContexts[scope]?.contains(containerName) != true,
              let container = containers[scope]?[containerName] else { return nil }
        return Context(container: container, viewContextLocation: location(access.declName.baseName), scope: scope)
    }

    private func contextInitializer(_ expression: ExprSyntax) -> Context? {
        guard expression.is(MemberAccessExprSyntax.self) else { return nil }
        return contextExpression(expression)
    }

    private func requestArgument(_ call: FunctionCallExprSyntax) -> Request? {
        guard call.arguments.count == 1,
              let expression = call.arguments.first?.expression.as(DeclReferenceExprSyntax.self),
              let scope = currentScope else { return nil }
        return requests[scope]?[SyntaxIdentifiers.unescaped(expression.baseName.text)]
    }

    private func invalidateCapturedBindings(in closure: ClosureExprSyntax) {
        let names = Set(closure.tokens(viewMode: .sourceAccurate).compactMap { token -> String? in
            guard case let .identifier(name) = token.tokenKind else { return nil }
            return SyntaxIdentifiers.unescaped(name)
        })
        for name in names { invalidateBinding(named: name) }
    }

    private func invalidateEscapedArguments(of call: FunctionCallExprSyntax) {
        for argument in call.arguments {
            guard let reference = argument.expression.as(DeclReferenceExprSyntax.self) else { continue }
            invalidateBinding(named: SyntaxIdentifiers.unescaped(reference.baseName.text))
        }
    }

    private func invalidateMutatingReceiver(of call: FunctionCallExprSyntax) {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              let reference = member.base?.as(DeclReferenceExprSyntax.self) else { return }
        let name = SyntaxIdentifiers.unescaped(reference.baseName.text)
        guard let scope = currentScope,
              requests[scope]?[name] != nil || contexts[scope]?[name] != nil else { return }
        invalidateBinding(named: name)
    }

    private func invalidateAssignedExpression(_ expression: ExprSyntax) {
        guard let member = expression.as(MemberAccessExprSyntax.self), let base = member.base else { return }
        if let reference = base.as(DeclReferenceExprSyntax.self) {
            invalidateMutableReference(named: SyntaxIdentifiers.unescaped(reference.baseName.text))
            return
        }
        guard let viewContext = base.as(MemberAccessExprSyntax.self),
              SyntaxIdentifiers.unescaped(viewContext.declName.baseName.text) == "viewContext",
              let container = viewContext.base?.as(DeclReferenceExprSyntax.self) else { return }
        invalidateContainerContext(named: SyntaxIdentifiers.unescaped(container.baseName.text))
    }

    private func invalidateBinding(named name: String) {
        for scope in scopes.reversed() where declaredNames[scope]?.contains(name) == true {
            requests[scope]?.removeValue(forKey: name)
            contexts[scope]?.removeValue(forKey: name)
            if containers[scope]?[name] != nil {
                invalidContainerContexts[scope, default: []].insert(name)
            }
            return
        }
    }

    private func invalidateMutableReference(named name: String) {
        for scope in scopes.reversed() where declaredNames[scope]?.contains(name) == true {
            requests[scope]?.removeValue(forKey: name)
            contexts[scope]?.removeValue(forKey: name)
            return
        }
    }

    private func invalidateContainerContext(named name: String) {
        for scope in scopes.reversed() where declaredNames[scope]?.contains(name) == true {
            if containers[scope]?[name] != nil {
                invalidContainerContexts[scope, default: []].insert(name)
            }
            return
        }
    }

    private func enterConditional() -> SyntaxVisitorContinueKind {
        conditionalDepth += 1
        return .visitChildren
    }

    private func leaveConditional() { conditionalDepth -= 1 }

    private func location(_ token: TokenSyntax) -> CartographCore.SourceLocation {
        let value = converter.location(for: token.positionAfterSkippingLeadingTrivia)
        return .init(path: path, line: value.line, column: value.column)
    }

    private func location(_ syntax: some SyntaxProtocol) -> CartographCore.SourceLocation {
        let value = converter.location(for: syntax.positionAfterSkippingLeadingTrivia)
        return .init(path: path, line: value.line, column: value.column)
    }
}
