import CartographCore
import SwiftOperators
import SwiftParser
import SwiftSyntax

/// Swift 소스에서 Objective-C 런타임과 알림 경계를 자동으로 찾는다.
///
/// 이 단계는 구문으로 확인한 후보만 만든다. 같은 이름의 사용자 API와 시스템 API를
/// 구분하고 정확한 USR을 붙이는 일은 컴파일러 인덱스를 가진 상위 계층이 맡는다.
public struct RuntimeFactScanner: Sendable {
    public init() {}

    /// 소스를 한 번 파싱해 런타임 선언과 경계 후보를 만든다.
    public func scan(source: String, path: String) -> RuntimeFileFacts {
        scan(tree: Parser.parse(source: source), path: path)
    }

    /// 이미 파싱한 트리를 재사용한다. SwiftSyntaxAnalyzer가 같은 파일을 두 번 파싱하지 않게 한다.
    func scan(tree parsed: SourceFileSyntax, path: String) -> RuntimeFileFacts {
        let tree = OperatorTable.standardOperators.foldAll(parsed) { _ in }
            .as(SourceFileSyntax.self) ?? parsed
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let bindings = RuntimeBindingCollector(converter: converter)
        bindings.walk(tree)
        let collector = RuntimeFactCollector(path: path, converter: converter, bindings: bindings)
        collector.walk(tree)
        let declarations = collector.declarations.sorted(by: RuntimeFactOrder.declaration)
        let coreData = CoreDataSourceScanner().scan(tree: tree, path: path)
        let registry = RuntimeRegistryScanner().scan(tree: tree, path: path)
        return RuntimeFileFacts(
            path: path,
            declarations: declarations,
            boundaries: Self.normalizedSelectors(
                collector.boundaries + coreData.boundaries + registry.boundaries, declarations: declarations
            )
                .sorted(by: RuntimeFactOrder.boundary),
            limitations: collector.limitations + coreData.limitations + registry.limitations
        )
    }

    /// Swift 이름과 Objective-C selector가 다를 수 있으므로 선언 근거가 있을 때만 문자열을 확정한다.
    private static func normalizedSelectors(
        _ boundaries: [RuntimeBoundary],
        declarations: [RuntimeDeclaration]
    ) -> [RuntimeBoundary] {
        return boundaries.map { boundary in
            guard boundary.nameOrigin == .selector,
                  boundary.referencedTargetLocation != nil,
                  let member = boundary.targetMemberName
            else { return boundary }
            let parameterCount = boundary.name?.count(where: { $0 == ":" })
            let matches = declarations.filter { declaration in
                guard declaration.name == member else { return false }
                if let receiver = boundary.receiverTypeName {
                    let owner = declaration.qualifiedName.split(separator: ".").dropLast().joined(separator: ".")
                    guard owner == receiver || owner.hasSuffix("." + receiver) else { return false }
                }
                guard let parameterCount else { return true }
                return declaration.indexName.count(where: { $0 == ":" }) == parameterCount
            }
            let names = Set(matches.compactMap(\.objectiveCName))
            let name = names.count == 1 ? names.first : nil
            return RuntimeBoundary(
                kind: boundary.kind, api: boundary.api, location: boundary.location,
                calleeLocation: boundary.calleeLocation,
                enclosingDeclarationLocation: boundary.enclosingDeclarationLocation,
                name: name, nameOrigin: .selector,
                receiverTypeName: boundary.receiverTypeName,
                receiverOrigin: boundary.receiverOrigin,
                receiverTypeLocation: boundary.receiverTypeLocation,
                referencedTargetLocation: boundary.referencedTargetLocation,
                targetMemberName: boundary.targetMemberName,
                targetUSR: boundary.targetUSR,
                resourceObjectID: boundary.resourceObjectID,
                coreDataCodeGeneration: boundary.coreDataCodeGeneration,
                coreDataModelName: boundary.coreDataModelName,
                coreDataSuperentityName: boundary.coreDataSuperentityName,
                coreDataContainerLocation: boundary.coreDataContainerLocation,
                coreDataContextLocation: boundary.coreDataContextLocation,
                coreDataRequestLocation: boundary.coreDataRequestLocation,
                coreDataResultTypeLocation: boundary.coreDataResultTypeLocation,
                registryDeclarationLocation: boundary.registryDeclarationLocation,
                registryReferenceLocation: boundary.registryReferenceLocation,
                notificationName: boundary.notificationName,
                notificationNameLocation: boundary.notificationNameLocation,
                notificationCenterLocation: boundary.notificationCenterLocation,
                notificationCenterOwnerLocation: boundary.notificationCenterOwnerLocation,
                notificationObjectIsNil: boundary.notificationObjectIsNil,
                notificationObjectLocation: boundary.notificationObjectLocation,
                notificationRemovalReferences: boundary.notificationRemovalReferences,
                notificationCancellationReferences: boundary.notificationCancellationReferences,
                keyPaths: boundary.keyPaths,
                nameAPIReferences: boundary.nameAPIReferences,
                subscriptionConsumer: boundary.subscriptionConsumer,
                reason: name == nil ? "selector-name-requires-index-resolution" : boundary.reason
            )
        }
    }
}

private enum RuntimeFactOrder {
    static func declaration(_ lhs: RuntimeDeclaration, _ rhs: RuntimeDeclaration) -> Bool {
        (lhs.location, lhs.kind.rawValue, lhs.indexName) < (rhs.location, rhs.kind.rawValue, rhs.indexName)
    }

    static func boundary(_ lhs: RuntimeBoundary, _ rhs: RuntimeBoundary) -> Bool {
        (lhs.location, lhs.kind.rawValue, lhs.api) < (rhs.location, rhs.kind.rawValue, rhs.api)
    }
}

/// 선언 문맥과 실제 런타임 API 후보를 한 패스에서 함께 수집한다.
private final class RuntimeFactCollector: SyntaxVisitor {
    private(set) var declarations: [RuntimeDeclaration] = []
    private(set) var boundaries: [RuntimeBoundary] = []
    private var unsupportedSelectorRegistrations = 0
    private var unsupportedNotificationStreams = 0
    private var unsupportedReflectionCalls = 0
    private var enclosingDeclarations: [CartographCore.SourceLocation] = []
    private var typeNames: [String] = []
    private var typeLocations: [CartographCore.SourceLocation] = []
    private var objectiveCExposure: [Bool] = []
    private var scopes: [Int] = []
    private let notificationLifecycle = RuntimeNotificationLifecycleTracker()
    private var deferredExecutionScopes: [[Int]] = []
    private var plainDoBodyScopes: [[Int]] = []
    private var conditionalCompilationDepth = 0
    private let path: String
    private let converter: SourceLocationConverter
    private let bindings: RuntimeBindingCollector

    init(path: String, converter: SourceLocationConverter, bindings: RuntimeBindingCollector) {
        self.path = path
        self.converter = converter
        self.bindings = bindings
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(
            name: node.name, kind: .classType, node: node, attributes: node.attributes,
            inheritsObjectiveC: SyntaxAttributes.has("objcMembers", in: node.attributes),
            isFinal: node.modifiers.contains { $0.name.text == "final" }
        )
    }
    override func visitPost(_: ClassDeclSyntax) { popType() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(name: node.name, kind: .structType, node: node, attributes: node.attributes)
    }
    override func visitPost(_: StructDeclSyntax) { popType() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(name: node.name, kind: .enumType, node: node, attributes: node.attributes)
    }
    override func visitPost(_: EnumDeclSyntax) { popType() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(
            name: node.name, kind: .protocolType, node: node, attributes: node.attributes,
            inheritsObjectiveC: SyntaxAttributes.has("objc", in: node.attributes)
        )
    }
    override func visitPost(_: ProtocolDeclSyntax) { popType() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(name: node.name, kind: .classType, node: node, attributes: node.attributes)
    }
    override func visitPost(_: ActorDeclSyntax) { popType() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let type = node.extendedType
        let name = SyntaxIdentifiers.unescaped(type.trimmedDescription)
        let location = sourceLocation(type)
        appendDeclaration(
            name: name, indexName: name, qualifiedName: name, kind: .extensionDeclaration,
            location: location, endLocation: endLocation(node), attributes: node.attributes,
            objectiveCName: nil, isTypeMember: false
        )
        typeNames.append(name)
        typeLocations.append(location)
        objectiveCExposure.append(
            SyntaxAttributes.has("objcMembers", in: node.attributes)
                || SyntaxAttributes.has("objc", in: node.attributes)
                || bindings.exposesObjectiveCMembers(typeName: name)
        )
        enclosingDeclarations.append(location)
        return .visitChildren
    }
    override func visitPost(_: ExtensionDeclSyntax) { popType() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        guard !DeclarationCollector.isInsideBody(node) else { return .visitChildren }
        let name = SyntaxIdentifiers.unescaped(node.name.text)
        let location = sourceLocation(node.name)
        let indexName = RuntimeSyntaxNames.indexName(name, parameters: node.signature.parameterClause.parameters)
        let attributes = DeclarationCollector.attributes(from: node.attributes)
        appendDeclaration(
            name: name, indexName: indexName, qualifiedName: (typeNames + [name]).joined(separator: "."),
            kind: typeNames.isEmpty ? .function : .method, location: location,
            endLocation: endLocation(node), attributes: node.attributes,
            objectiveCName: objectiveCName(node, attributes: attributes),
            isTypeMember: !typeNames.isEmpty,
            isStatic: node.modifiers.contains { ["static", "class"].contains($0.name.text) }
        )
        enclosingDeclarations.append(location)
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) {
        scopes.removeLast()
        if !DeclarationCollector.isInsideBody(node) { enclosingDeclarations.removeLast() }
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        let location = sourceLocation(node.initKeyword)
        let indexName = RuntimeSyntaxNames.indexName("init", parameters: node.signature.parameterClause.parameters)
        appendDeclaration(
            name: "init", indexName: indexName, qualifiedName: (typeNames + ["init"]).joined(separator: "."),
            kind: .initializer, location: location, endLocation: endLocation(node), attributes: node.attributes,
            objectiveCName: nil, isTypeMember: !typeNames.isEmpty
        )
        enclosingDeclarations.append(location)
        return .visitChildren
    }
    override func visitPost(_: InitializerDeclSyntax) {
        scopes.removeLast()
        enclosingDeclarations.removeLast()
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        return .visitChildren
    }
    override func visitPost(_: ClosureExprSyntax) { scopes.removeLast() }
    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        return .visitChildren
    }
    override func visitPost(_: AccessorBlockSyntax) { scopes.removeLast() }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        return .visitChildren
    }
    override func visitPost(_: AccessorDeclSyntax) { scopes.removeLast() }
    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        return .visitChildren
    }
    override func visitPost(_: CodeBlockSyntax) { scopes.removeLast() }
    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        return .visitChildren
    }
    override func visitPost(_: IfExprSyntax) { scopes.removeLast() }
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        return .visitChildren
    }
    override func visitPost(_: WhileStmtSyntax) { scopes.removeLast() }
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        return .visitChildren
    }
    override func visitPost(_: ForStmtSyntax) { scopes.removeLast() }
    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        return .visitChildren
    }
    override func visitPost(_: SwitchExprSyntax) { scopes.removeLast() }
    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        return .visitChildren
    }
    override func visitPost(_: SwitchCaseSyntax) { scopes.removeLast() }
    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        return .visitChildren
    }
    override func visitPost(_: CatchClauseSyntax) { scopes.removeLast() }
    override func visit(_: DeferStmtSyntax) -> SyntaxVisitorContinueKind {
        deferredExecutionScopes.append(scopes)
        return .visitChildren
    }
    override func visitPost(_: DeferStmtSyntax) { deferredExecutionScopes.removeLast() }
    override func visit(_ node: DoStmtSyntax) -> SyntaxVisitorContinueKind {
        plainDoBodyScopes.append(scopes + [node.body.position.utf8Offset])
        return .visitChildren
    }
    override func visitPost(_: DoStmtSyntax) {
        notificationLifecycle.activateDeferredTerminations(
            from: plainDoBodyScopes.removeLast(),
            in: scopes
        )
    }
    override func visit(_: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        conditionalCompilationDepth += 1
        return .visitChildren
    }
    override func visitPost(_: IfConfigDeclSyntax) { conditionalCompilationDepth -= 1 }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        guard DeclarationCollector.isInsideBody(node),
              let identifier = node.pattern.as(IdentifierPatternSyntax.self)?.identifier
        else { return .visitChildren }
        let name = SyntaxIdentifiers.unescaped(identifier.text)
        guard conditionalCompilationDepth == 0,
              let declaration = node.parent?.parent?.as(VariableDeclSyntax.self),
              declaration.bindingSpecifier.tokenKind == .keyword(.let),
              node.accessorBlock == nil,
              let initializer = node.initializer?.value,
              let source = RuntimeSyntaxNames.unparenthesized(initializer).as(DeclReferenceExprSyntax.self)
        else {
            notificationLifecycle.bindOpaque(name: name, scopes: scopes)
            return .visitChildren
        }
        notificationLifecycle.bindAlias(
            name: name,
            source: SyntaxIdentifiers.unescaped(source.baseName.text),
            scopes: scopes
        )
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !DeclarationCollector.isInsideBody(node) else { return .visitChildren }
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else { continue }
            let name = SyntaxIdentifiers.unescaped(identifier.text)
            let declarationAttributes = DeclarationCollector.attributes(from: node.attributes)
            let isObjectiveCExposed = declarationAttributes.contains(.objc)
                || declarationAttributes.contains(.interfaceBuilderOutlet)
            let valueType = explicitValueType(binding.typeAnnotation?.type)
            appendDeclaration(
                name: name, indexName: name, qualifiedName: (typeNames + [name]).joined(separator: "."),
                kind: typeNames.isEmpty ? .variable : .property, location: sourceLocation(identifier),
                endLocation: endLocation(node), attributes: node.attributes,
                objectiveCName: SyntaxAttributes.has("nonobjc", in: node.attributes) ? nil
                    : (SyntaxAttributes.objectiveCName(in: node.attributes) ?? (isObjectiveCExposed ? name : nil)),
                isTypeMember: !typeNames.isEmpty,
                isStatic: node.modifiers.contains { ["static", "class"].contains($0.name.text) },
                isImmutable: node.bindingSpecifier.tokenKind == .keyword(.let)
                    && binding.accessorBlock == nil,
                isSettable: isSettable(node, binding: binding),
                valueTypeName: valueType?.name,
                valueTypeLocation: valueType.map { sourceLocation($0.token) }
            )
        }
        return .visitChildren
    }

    private func isSettable(_ declaration: VariableDeclSyntax, binding: PatternBindingSyntax) -> Bool {
        guard declaration.bindingSpecifier.tokenKind == .keyword(.var),
              !declaration.modifiers.contains(where: {
                  ["private", "fileprivate"].contains($0.name.text) && $0.detail?.detail.text == "set"
              })
        else { return false }
        guard let block = binding.accessorBlock else { return true }
        guard case .accessors(let accessors) = block.accessors else { return false }
        return accessors.contains { ["set", "willSet", "didSet"].contains($0.accessorSpecifier.text) }
    }

    private func explicitValueType(_ rawType: TypeSyntax?) -> (name: String, token: TokenSyntax)? {
        guard let rawType else { return nil }
        let type: TypeSyntax
        if let optional = rawType.as(OptionalTypeSyntax.self) { type = optional.wrappedType }
        else { type = rawType }
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil,
           !["Any", "AnyObject"].contains(identifier.name.text) {
            return (identifier.name.text, identifier.name)
        }
        if let member = type.as(MemberTypeSyntax.self), member.genericArgumentClause == nil {
            return (type.trimmedDescription, member.name)
        }
        return nil
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.macroName.text == "selector",
              let resolved = bindings.resolveName(ExprSyntax(node), in: context)
        else { return .visitChildren }
        emit(
            kind: .selectorReference, api: "#selector", callee: node.macroName,
            nameExpression: node, resolved: resolved, receiver: selectorReceiver(resolved)
        )
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let api = RuntimeSyntaxNames.calleeName(node),
              let callee = RuntimeSyntaxNames.calleeToken(node.calledExpression)
        else { return .visitChildren }

        if emitLookup(node, api: api, callee: callee) { return .visitChildren }
        if api == "perform" || api == "performSelector" {
            emitSelectorInvocation(node, api: api, callee: callee)
            return .visitChildren
        }
        if emitNotificationSelectorObserver(node, api: api, callee: callee) { return .visitChildren }
        if emitNotificationSubscription(node, api: api, callee: callee) { return .visitChildren }
        if emitSelectorRegistration(node, api: api, callee: callee) { return .visitChildren }
        if emitPredicateEvaluation(node, api: api, callee: callee) { return .visitChildren }
        if emitKeyValueAccess(node, api: api, callee: callee) { return .visitChildren }
        if recordNotificationTermination(node, api: api, callee: callee) { return .visitChildren }
        countUnsupportedBoundary(node, api: api)
        emitNotification(node, api: api, callee: callee)
        return .visitChildren
    }

    var limitations: [String] {
        var result: [String] = []
        appendLimitation(
            count: unsupportedSelectorRegistrations,
            message: "Selector registration calls using APIs outside the supported runtime registry",
            to: &result
        )
        appendLimitation(
            count: unsupportedNotificationStreams,
            message: "Notification stream registration calls not yet modeled",
            to: &result
        )
        appendLimitation(
            count: unsupportedReflectionCalls,
            message: "Key-value or predicate reflection calls not yet modeled",
            to: &result
        )
        return result
    }

    private func appendLimitation(count: Int, message: String, to result: inout [String]) {
        guard count > 0 else { return }
        result.append("\(message): \(count).")
    }

    private func emitLookup(_ call: FunctionCallExprSyntax, api: String, callee: TokenSyntax) -> Bool {
        let kind: RuntimeBoundaryKind
        switch api {
        case "NSClassFromString", "objc_getClass", "objc_lookUpClass", "classNamed": kind = .classLookup
        case "NSProtocolFromString", "objc_getProtocol": kind = .protocolLookup
        case "NSSelectorFromString", "sel_registerName", "sel_getUid", "Selector": kind = .selectorLookup
        default: return false
        }
        guard let argument = call.arguments.first?.expression else { return true }
        emit(
            kind: kind, api: api, callee: callee, nameExpression: argument,
            resolved: bindings.resolveName(argument, in: context), receiver: nil
        )
        return true
    }

    private func emitSelectorInvocation(_ call: FunctionCallExprSyntax, api: String, callee: TokenSyntax) {
        guard let argument = call.arguments.first?.expression else { return }
        let receiver = call.calledExpression.as(MemberAccessExprSyntax.self)?.base
            .map { bindings.receiverHint($0, in: context) }
            ?? bindings.receiverHint(ExprSyntax(DeclReferenceExprSyntax(baseName: .keyword(.self))), in: context)
        emit(
            kind: .selectorInvocation, api: api, callee: callee, nameExpression: argument,
            resolved: bindings.resolveName(argument, in: context), receiver: receiver
        )
    }

    private func emitSelectorRegistration(
        _ call: FunctionCallExprSyntax,
        api: String,
        callee: TokenSyntax
    ) -> Bool {
        let selector = call.arguments.first { ["selector", "action"].contains($0.label?.text ?? "") }
        guard let selector else { return false }
        guard !selector.expression.is(ClosureExprSyntax.self) else { return false }
        guard isSupportedSelectorRegistration(call, api: api) else {
            unsupportedSelectorRegistrations += 1
            return false
        }
        let target = call.arguments.first { $0.label?.text == "target" }?.expression
            ?? (["addTarget", "addObserver"].contains(api)
                ? call.arguments.first(where: { $0.label == nil })?.expression : nil)
        let baseHint = target.map { bindings.receiverHint($0, in: context) }
        let receiver = RuntimeReceiverHint(
            typeName: baseHint?.typeName, origin: .explicitTarget, typeLocation: baseHint?.typeLocation
        )
        emit(
            kind: .selectorRegistration, api: api, callee: callee,
            nameExpression: selector.expression,
            resolved: bindings.resolveName(selector.expression, in: context), receiver: receiver
        )
        return true
    }

    private func emitNotificationSelectorObserver(
        _ call: FunctionCallExprSyntax,
        api: String,
        callee: TokenSyntax
    ) -> Bool {
        guard api == "addObserver",
              let selector = call.arguments.first(where: { $0.label?.text == "selector" }),
              let event = call.arguments.first(where: { $0.label?.text == "name" })
        else { return false }
        let target = call.arguments.first(where: { $0.label == nil })?.expression
        let targetHint = target.map { bindings.receiverHint($0, in: context) }
        let receiver = RuntimeReceiverHint(
            typeName: targetHint?.typeName,
            origin: .explicitTarget,
            typeLocation: targetHint?.typeLocation
        )
        let selectorName = bindings.resolveName(selector.expression, in: context)
        let notificationName = bindings.resolveName(event.expression, in: context)
        let center = bindings.notificationCenterEvidence(for: call, in: context)
        let references = (selectorName?.apiReferences ?? []) + (notificationName?.apiReferences ?? [])
        boundaries.append(RuntimeBoundary(
            kind: .notificationObserver,
            api: api,
            location: sourceLocation(selector.expression),
            calleeLocation: sourceLocation(callee),
            enclosingDeclarationLocation: enclosingDeclarations.last,
            name: selectorName?.text,
            nameOrigin: selectorName?.origin ?? .dynamic,
            receiverTypeName: receiver.typeName ?? selectorName?.receiverTypeName,
            receiverOrigin: receiver.origin,
            receiverTypeLocation: receiver.typeLocation ?? selectorName?.receiverTypeLocation,
            referencedTargetLocation: selectorName?.referencedTargetLocation,
            targetMemberName: selectorName?.targetMemberName,
            notificationName: notificationName?.text,
            notificationNameLocation: bindings.nameEvidenceLocation(event.expression, in: context),
            notificationCenterLocation: center?.location,
            notificationCenterOwnerLocation: center?.ownerLocation,
            notificationObjectIsNil: objectIsNil(call),
            notificationObjectLocation: bindings.notificationObjectLocation(for: call, in: context),
            nameAPIReferences: references.isEmpty ? nil : references,
            reason: selectorName?.reason
        ))
        return true
    }

    private func emitKeyValueAccess(
        _ call: FunctionCallExprSyntax,
        api: String,
        callee: TokenSyntax
    ) -> Bool {
        let access: (label: String, kind: RuntimeBoundaryKind)
        if api == "value", call.arguments.contains(where: { $0.label?.text == "forKey" }) {
            access = ("forKey", .keyValueRead)
        } else if api == "setValue", call.arguments.contains(where: { $0.label?.text == "forKey" }) {
            access = ("forKey", .keyValueWrite)
        } else if api == "value", call.arguments.contains(where: { $0.label?.text == "forKeyPath" }) {
            access = ("forKeyPath", .keyPathRead)
        } else if api == "setValue", call.arguments.contains(where: { $0.label?.text == "forKeyPath" }) {
            access = ("forKeyPath", .keyPathWrite)
        } else { return false }
        guard let keyExpression = call.arguments.first(where: { $0.label?.text == access.label })?.expression,
              let key = keyExpression.as(StringLiteralExprSyntax.self)?.representedLiteralValue,
              let components = RuntimeKeyPath.components(of: key),
              access.label == "forKeyPath" || components.count == 1,
              let receiverExpression = call.calledExpression.as(MemberAccessExprSyntax.self)?.base
        else { return false }
        let receiver = bindings.receiverHint(receiverExpression, in: context)
        guard let receiverType = receiver.typeName,
              !["Any", "AnyObject"].contains(receiverType)
        else { return false }
        boundaries.append(RuntimeBoundary(
            kind: access.kind,
            api: api,
            location: sourceLocation(keyExpression),
            calleeLocation: sourceLocation(callee),
            enclosingDeclarationLocation: enclosingDeclarations.last,
            name: key,
            nameOrigin: .literal,
            receiverTypeName: receiver.typeName,
            receiverOrigin: receiver.origin,
            receiverTypeLocation: receiver.typeLocation,
            keyPaths: access.label == "forKeyPath" ? [key] : nil
        ))
        return true
    }

    private func emitPredicateEvaluation(
        _ call: FunctionCallExprSyntax,
        api: String,
        callee: TokenSyntax
    ) -> Bool {
        guard api == "evaluate" else { return false }
        guard let root = call.arguments.first(where: { $0.label?.text == "with" })?.expression,
              let predicate = call.calledExpression.as(MemberAccessExprSyntax.self)?.base
        else { return false }
        guard let fact = predicateFact(predicate) else {
            unsupportedReflectionCalls += 1
            return true
        }
        if fact.keyPaths.isEmpty { return true }
        let receiver = bindings.receiverHint(root, in: context)
        guard let receiverType = receiver.typeName, !["Any", "AnyObject"].contains(receiverType) else {
            unsupportedReflectionCalls += 1
            return true
        }
        boundaries.append(RuntimeBoundary(
            kind: .keyPathRead,
            api: api,
            location: sourceLocation(root),
            calleeLocation: sourceLocation(callee),
            enclosingDeclarationLocation: enclosingDeclarations.last,
            nameOrigin: .literal,
            receiverTypeName: receiver.typeName,
            receiverOrigin: receiver.origin,
            receiverTypeLocation: receiver.typeLocation,
            keyPaths: fact.keyPaths,
            nameAPIReferences: [fact.constructorReference]
        ))
        return true
    }

    private func predicateFact(
        _ rawExpression: ExprSyntax,
        in predicateContext: RuntimeBindingCollector.Context? = nil,
        remaining: Int = 64
    ) -> RuntimePredicateFact? {
        guard remaining > 0 else { return nil }
        let expression = RuntimeSyntaxNames.unparenthesized(rawExpression)
        let activeContext = predicateContext ?? context
        if expression.is(DeclReferenceExprSyntax.self),
           let bound = bindings.immutableExpression(expression, in: activeContext) {
            return predicateFact(bound.0, in: bound.1, remaining: remaining - 1)
        }
        guard let call = expression.as(FunctionCallExprSyntax.self),
              let fullName = RuntimeSyntaxNames.dottedName(call.calledExpression),
              fullName == "NSPredicate" || fullName.hasSuffix(".NSPredicate")
                || fullName == "NSPredicate.init" || fullName.hasSuffix(".NSPredicate.init"),
              let callee = RuntimeSyntaxNames.calleeToken(call.calledExpression),
              let formatIndex = call.arguments.firstIndex(where: { $0.label?.text == "format" }),
              let format = call.arguments[formatIndex].expression.as(StringLiteralExprSyntax.self)?
                .representedLiteralValue,
              let arguments = predicateArguments(call, after: formatIndex),
              let keyPaths = RuntimePredicateFormatParser.keyPaths(in: format, arguments: arguments)
        else { return nil }
        return RuntimePredicateFact(
            keyPaths: keyPaths,
            constructorReference: RuntimeNameAPIReference(
                api: "NSPredicate.format", location: sourceLocation(callee)
            )
        )
    }

    private func predicateArguments(
        _ call: FunctionCallExprSyntax,
        after formatIndex: LabeledExprListSyntax.Index
    ) -> [String?]? {
        let remaining = call.arguments[call.arguments.index(after: formatIndex)...]
        if let arrayArgument = remaining.first(where: { $0.label?.text == "argumentArray" }) {
            guard remaining.count == 1,
                  let array = arrayArgument.expression.as(ArrayExprSyntax.self)
            else { return nil }
            return array.elements.map { literalString($0.expression) }
        }
        guard remaining.allSatisfy({ $0.label == nil }) else { return nil }
        return remaining.map { literalString($0.expression) }
    }

    private func literalString(_ expression: ExprSyntax) -> String? {
        expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
    }

    private func emitNotificationSubscription(
        _ call: FunctionCallExprSyntax,
        api: String,
        callee: TokenSyntax
    ) -> Bool {
        let label: String
        if api == "publisher" { label = "for" }
        else if api == "notifications" { label = "named" }
        else { return false }
        guard let name = call.arguments.first(where: { $0.label?.text == label })?.expression else { return false }
        let consumer = api == "notifications" ? asyncSequenceConsumer(of: call) : subscriptionConsumer(of: call)
        guard api != "notifications" || consumer != nil else { return false }
        let resolved = bindings.resolveName(name, in: context)
        let center = bindings.notificationCenterEvidence(for: call, in: context)
        boundaries.append(RuntimeBoundary(
            kind: .notificationSubscription,
            api: api,
            location: sourceLocation(name),
            calleeLocation: sourceLocation(callee),
            enclosingDeclarationLocation: enclosingDeclarations.last,
            name: resolved?.text,
            nameOrigin: resolved?.origin ?? .dynamic,
            notificationName: resolved?.text,
            notificationNameLocation: bindings.nameEvidenceLocation(name, in: context),
            notificationCenterLocation: center?.location,
            notificationCenterOwnerLocation: center?.ownerLocation,
            notificationObjectIsNil: !hasObjectArgument(call)
                ? true : objectIsNil(call),
            notificationObjectLocation: bindings.notificationObjectLocation(for: call, in: context),
            nameAPIReferences: resolved.flatMap { $0.apiReferences.isEmpty ? nil : $0.apiReferences },
            subscriptionConsumer: consumer,
            reason: resolved?.reason
        ))
        if api == "publisher", let consumer { recordSubscriptionToken(call, consumer: consumer) }
        return true
    }

    private func asyncSequenceConsumer(
        of notifications: FunctionCallExprSyntax
    ) -> RuntimeSubscriptionConsumerReference? {
        var ancestor = notifications.parent
        while let syntax = ancestor {
            if let loop = syntax.as(ForStmtSyntax.self) {
                guard loop.awaitKeyword != nil,
                      RuntimeSyntaxNames.unparenthesized(loop.sequence).id == notifications.id
                else { return nil }
                return RuntimeSubscriptionConsumerReference(
                    api: "for-await",
                    location: sourceLocation(loop.forKeyword)
                )
            }
            if syntax.is(CodeBlockItemSyntax.self) || syntax.is(VariableDeclSyntax.self)
                || syntax.is(FunctionDeclSyntax.self) {
                return nil
            }
            ancestor = syntax.parent
        }
        return nil
    }

    private func subscriptionConsumer(
        of publisher: FunctionCallExprSyntax
    ) -> RuntimeSubscriptionConsumerReference? {
        var ancestor = publisher.parent
        for _ in 0..<12 {
            guard let syntax = ancestor else { return nil }
            if let call = syntax.as(FunctionCallExprSyntax.self), call.id != publisher.id,
               let api = RuntimeSyntaxNames.calleeName(call), ["sink", "onReceive"].contains(api),
               let token = RuntimeSyntaxNames.calleeToken(call.calledExpression) {
                return RuntimeSubscriptionConsumerReference(api: api, location: sourceLocation(token))
            }
            if syntax.is(CodeBlockItemSyntax.self) || syntax.is(VariableDeclSyntax.self)
                || syntax.is(FunctionDeclSyntax.self) {
                return nil
            }
            ancestor = syntax.parent
        }
        return nil
    }

    private func recordSubscriptionToken(
        _ publisher: FunctionCallExprSyntax,
        consumer: RuntimeSubscriptionConsumerReference
    ) {
        guard consumer.api == "sink", conditionalCompilationDepth == 0 else { return }
        var ancestor = publisher.parent
        while let syntax = ancestor {
            if let sink = syntax.as(FunctionCallExprSyntax.self), sink.id != publisher.id,
               RuntimeSyntaxNames.calleeName(sink) == "sink",
               let initializer = sink.parent?.as(InitializerClauseSyntax.self),
               let binding = initializer.parent?.as(PatternBindingSyntax.self),
               DeclarationCollector.isInsideBody(binding),
               let declaration = binding.parent?.parent?.as(VariableDeclSyntax.self),
               declaration.bindingSpecifier.tokenKind == .keyword(.let),
               binding.accessorBlock == nil,
               let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier {
                notificationLifecycle.bindToken(
                    name: SyntaxIdentifiers.unescaped(identifier.text),
                    token: RuntimeNotificationToken(
                        registrationLocation: sourceLocation(
                            publisher.arguments.first { $0.label?.text == "for" }?.expression ?? ExprSyntax(publisher)
                        ),
                        kind: .subscription
                    ),
                    scopes: scopes
                )
                return
            }
            if syntax.is(CodeBlockItemSyntax.self) || syntax.is(VariableDeclSyntax.self)
                || syntax.is(FunctionDeclSyntax.self) { return }
            ancestor = syntax.parent
        }
    }

    private func hasObjectArgument(_ call: FunctionCallExprSyntax) -> Bool {
        call.arguments.contains { $0.label?.text == "object" }
    }

    private func isSupportedSelectorRegistration(_ call: FunctionCallExprSyntax, api: String) -> Bool {
        if ["addTarget", "scheduledTimer", "addObserver", "Timer", "CADisplayLink", "NSMenuItem"]
            .contains(api) || api.hasSuffix("GestureRecognizer") {
            return true
        }
        guard api == "init", let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              let base = member.base.flatMap(RuntimeSyntaxNames.dottedName)
        else { return false }
        return ["Timer", "CADisplayLink", "NSMenuItem"].contains(base)
            || base.hasSuffix("GestureRecognizer")
    }

    private func countUnsupportedBoundary(_ call: FunctionCallExprSyntax, api: String) {
        let labels = Set(call.arguments.compactMap { $0.label?.text })
        if api == "notifications",
           !labels.intersection(["for", "named"]).isEmpty {
            unsupportedNotificationStreams += 1
        }
        let keyValue = ["value", "setValue", "validateValue", "addObserver", "removeObserver"]
            .contains(api) && !labels.intersection(["forKey", "forKeyPath"]).isEmpty
        let predicate = api == "NSSortDescriptor"
            && !labels.intersection(["format", "key"]).isEmpty
        if keyValue || predicate { unsupportedReflectionCalls += 1 }
    }

    private func emitNotification(_ call: FunctionCallExprSyntax, api: String, callee: TokenSyntax) {
        let name = call.arguments.first(where: {
            ["name", "forName"].contains($0.label?.text ?? "")
        })
        if let name, api == "post" || api == "addObserver" {
            emitNamedNotification(call, api: api, callee: callee, nameExpression: name.expression)
            return
        }
        guard api == "post", let payload = call.arguments.first(where: { $0.label == nil })?.expression
        else { return }
        emitNotificationPayload(call, callee: callee, payload: payload)
    }

    private func emitNamedNotification(
        _ call: FunctionCallExprSyntax,
        api: String,
        callee: TokenSyntax,
        nameExpression: ExprSyntax
    ) {
        let resolved = bindings.resolveName(nameExpression, in: context)
        let kind: RuntimeBoundaryKind = api == "post" ? .notificationPost : .notificationObserver
        let center = bindings.notificationCenterEvidence(for: call, in: context)
        let location = sourceLocation(nameExpression)
        let removals = kind == .notificationPost
            ? notificationLifecycle.visibleRemovals(scopes: scopes) : nil
        let cancellations = kind == .notificationPost
            ? notificationLifecycle.visibleCancellations(scopes: scopes) : nil
        boundaries.append(RuntimeBoundary(
            kind: kind,
            api: api,
            location: location,
            calleeLocation: sourceLocation(callee),
            enclosingDeclarationLocation: enclosingDeclarations.last,
            name: resolved?.text,
            nameOrigin: resolved?.origin ?? .dynamic,
            notificationName: resolved?.text,
            notificationNameLocation: bindings.nameEvidenceLocation(nameExpression, in: context),
            notificationCenterLocation: center?.location,
            notificationCenterOwnerLocation: center?.ownerLocation,
            notificationObjectIsNil: objectIsNil(call),
            notificationObjectLocation: bindings.notificationObjectLocation(for: call, in: context),
            notificationRemovalReferences: removals,
            notificationCancellationReferences: cancellations,
            nameAPIReferences: resolved.flatMap { $0.apiReferences.isEmpty ? nil : $0.apiReferences },
            reason: resolved?.reason
        ))
        if kind == .notificationObserver {
            recordNotificationToken(call, registrationLocation: location)
        }
    }

    private func emitNotificationPayload(
        _ call: FunctionCallExprSyntax,
        callee: TokenSyntax,
        payload: ExprSyntax
    ) {
        let constructor = payload.as(FunctionCallExprSyntax.self)
        let nameExpression = constructor?.arguments.first(where: { $0.label?.text == "name" })?.expression
        let name = nameExpression.flatMap { bindings.resolveName($0, in: context) }
        let constructorReference = constructor.flatMap(notificationConstructorReference)
        let isResolvedPayload = nameExpression != nil && constructorReference != nil
        let references = (name?.apiReferences ?? []) + (constructorReference.map { [$0] } ?? [])
        let center = bindings.notificationCenterEvidence(for: call, in: context)
        let removals = notificationLifecycle.visibleRemovals(scopes: scopes)
        let cancellations = notificationLifecycle.visibleCancellations(scopes: scopes)
        boundaries.append(RuntimeBoundary(
            kind: .notificationPost,
            api: "post",
            location: sourceLocation(payload),
            calleeLocation: sourceLocation(callee),
            enclosingDeclarationLocation: enclosingDeclarations.last,
            name: isResolvedPayload ? name?.text : nil,
            nameOrigin: isResolvedPayload ? (name?.origin ?? .dynamic) : .dynamic,
            notificationName: isResolvedPayload ? name?.text : nil,
            notificationNameLocation: nameExpression.map {
                bindings.nameEvidenceLocation($0, in: context)
            },
            notificationCenterLocation: center?.location,
            notificationCenterOwnerLocation: center?.ownerLocation,
            notificationObjectIsNil: constructor.flatMap { objectIsNil($0) },
            notificationObjectLocation: constructor.flatMap {
                bindings.notificationObjectLocation(for: $0, in: context)
            },
            notificationRemovalReferences: removals,
            notificationCancellationReferences: cancellations,
            nameAPIReferences: references.isEmpty ? nil : references,
            reason: isResolvedPayload
                ? name?.reason : "runtime-notification-payload-not-statically-resolved"
        ))
    }

    private func recordNotificationToken(
        _ call: FunctionCallExprSyntax,
        registrationLocation: CartographCore.SourceLocation
    ) {
        guard conditionalCompilationDepth == 0,
              let initializer = call.parent?.as(InitializerClauseSyntax.self),
              let binding = initializer.parent?.as(PatternBindingSyntax.self),
              DeclarationCollector.isInsideBody(binding),
              let declaration = binding.parent?.parent?.as(VariableDeclSyntax.self),
              declaration.bindingSpecifier.tokenKind == .keyword(.let),
              binding.accessorBlock == nil,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
              let receiverText = notificationReceiverText(call)
        else { return }
        let name = SyntaxIdentifiers.unescaped(identifier.text)
        notificationLifecycle.bindToken(name: name, token: RuntimeNotificationToken(
            registrationLocation: registrationLocation,
            kind: .observer(receiverText: receiverText)
        ), scopes: scopes)
    }

    private func recordNotificationTermination(
        _ call: FunctionCallExprSyntax,
        api: String,
        callee: TokenSyntax
    ) -> Bool {
        if api == "removeObserver" {
            recordNotificationRemoval(call, callee: callee)
            return true
        }
        if api == "cancel" {
            recordNotificationCancellation(call, callee: callee)
            return true
        }
        return false
    }

    private func recordNotificationRemoval(_ call: FunctionCallExprSyntax, callee: TokenSyntax) {
        guard conditionalCompilationDepth == 0, call.arguments.count == 1,
              let argument = call.arguments.first, argument.label == nil,
              let token = RuntimeSyntaxNames.unparenthesized(argument.expression)
                .as(DeclReferenceExprSyntax.self),
              let registration = notificationLifecycle.token(
                named: SyntaxIdentifiers.unescaped(token.baseName.text), scopes: scopes
              ),
              case .observer(let registeredReceiver) = registration.kind,
              let receiverText = notificationReceiverText(call), receiverText == registeredReceiver,
              let center = bindings.notificationCenterEvidence(for: call, in: context)
        else { return }
        notificationLifecycle.recordRemoval(
            RuntimeNotificationRemovalReference(
                registrationLocation: registration.registrationLocation,
                removalLocation: sourceLocation(callee),
                notificationCenterLocation: center.location,
                notificationCenterOwnerLocation: center.ownerLocation
            ),
            scopes: scopes,
            deferredUntilScopeExit: deferredExecutionScopes.last
        )
    }

    private func recordNotificationCancellation(_ call: FunctionCallExprSyntax, callee: TokenSyntax) {
        guard conditionalCompilationDepth == 0, call.arguments.isEmpty,
              let receiver = call.calledExpression.as(MemberAccessExprSyntax.self)?.base,
              let reference = RuntimeSyntaxNames.unparenthesized(receiver).as(DeclReferenceExprSyntax.self),
              let registration = notificationLifecycle.token(
                named: SyntaxIdentifiers.unescaped(reference.baseName.text), scopes: scopes
              ),
              registration.kind == .subscription
        else { return }
        notificationLifecycle.recordCancellation(
            RuntimeNotificationCancellationReference(
                registrationLocation: registration.registrationLocation,
                cancellationLocation: sourceLocation(callee)
            ),
            scopes: scopes,
            deferredUntilScopeExit: deferredExecutionScopes.last
        )
    }

    private func notificationReceiverText(_ call: FunctionCallExprSyntax) -> String? {
        guard let receiver = call.calledExpression.as(MemberAccessExprSyntax.self)?.base else { return nil }
        return RuntimeSyntaxNames.unparenthesized(receiver).trimmedDescription
    }

    private func notificationConstructorReference(
        _ call: FunctionCallExprSyntax
    ) -> RuntimeNameAPIReference? {
        guard let fullName = RuntimeSyntaxNames.dottedName(call.calledExpression),
              let token = RuntimeSyntaxNames.calleeToken(call.calledExpression)
        else { return nil }
        let baseName = fullName.hasSuffix(".init")
            ? String(fullName.dropLast(".init".count)) : fullName
        guard baseName == "Notification" || baseName.hasSuffix(".Notification") else { return nil }
        return RuntimeNameAPIReference(api: "Notification", location: sourceLocation(token))
    }

    private func objectIsNil(_ call: FunctionCallExprSyntax) -> Bool? {
        guard let object = call.arguments.first(where: { $0.label?.text == "object" })?.expression
        else { return nil }
        return RuntimeSyntaxNames.isNil(object)
    }

    private func selectorReceiver(_ resolved: RuntimeResolvedName) -> RuntimeReceiverHint? {
        guard resolved.receiverTypeName != nil else { return nil }
        return RuntimeReceiverHint(
            typeName: resolved.receiverTypeName, origin: .enclosingType,
            typeLocation: resolved.receiverTypeLocation
        )
    }

    private func emit(
        kind: RuntimeBoundaryKind,
        api: String,
        callee: TokenSyntax,
        nameExpression: some SyntaxProtocol,
        resolved: RuntimeResolvedName?,
        receiver: RuntimeReceiverHint?
    ) {
        let location = sourceLocation(nameExpression)
        boundaries.append(RuntimeBoundary(
            kind: kind,
            api: api,
            location: location,
            calleeLocation: sourceLocation(callee),
            enclosingDeclarationLocation: enclosingDeclarations.last,
            name: resolved?.text,
            nameOrigin: resolved?.origin ?? .dynamic,
            receiverTypeName: receiver != nil ? receiver?.typeName : resolved?.receiverTypeName,
            receiverOrigin: receiver?.origin ?? .unknown,
            receiverTypeLocation: receiver != nil ? receiver?.typeLocation : resolved?.receiverTypeLocation,
            referencedTargetLocation: resolved?.referencedTargetLocation,
            targetMemberName: resolved?.targetMemberName,
            nameAPIReferences: resolved.flatMap { $0.apiReferences.isEmpty ? nil : $0.apiReferences },
            reason: resolved?.reason
                ?? (resolved == nil ? "runtime-name-not-statically-resolved" : nil)
        ))
    }

    private var context: RuntimeBindingCollector.Context {
        RuntimeBindingCollector.Context(scopes: scopes, types: typeNames)
    }

    private func pushType(
        name token: TokenSyntax,
        kind: SymbolKind,
        node: some SyntaxProtocol,
        attributes: AttributeListSyntax,
        inheritsObjectiveC: Bool = false,
        isFinal: Bool = false
    ) -> SyntaxVisitorContinueKind {
        let name = SyntaxIdentifiers.unescaped(token.text)
        let location = sourceLocation(token)
        appendDeclaration(
            name: name, indexName: name, qualifiedName: (typeNames + [name]).joined(separator: "."),
            kind: kind, location: location, endLocation: endLocation(node), attributes: attributes,
            objectiveCName: declaredObjectiveCName(attributes: attributes),
            isTypeMember: !typeNames.isEmpty,
            isFinal: isFinal
        )
        typeNames.append(name)
        typeLocations.append(location)
        objectiveCExposure.append(inheritsObjectiveC)
        enclosingDeclarations.append(location)
        return .visitChildren
    }

    private func popType() {
        typeNames.removeLast()
        typeLocations.removeLast()
        objectiveCExposure.removeLast()
        enclosingDeclarations.removeLast()
    }

    private func appendDeclaration(
        name: String,
        indexName: String,
        qualifiedName: String,
        kind: SymbolKind,
        location: CartographCore.SourceLocation,
        endLocation: CartographCore.SourceLocation,
        attributes: AttributeListSyntax,
        objectiveCName: String?,
        isTypeMember: Bool,
        isStatic: Bool = false,
        isImmutable: Bool = false,
        isSettable: Bool = false,
        isFinal: Bool = false,
        valueTypeName: String? = nil,
        valueTypeLocation: CartographCore.SourceLocation? = nil
    ) {
        declarations.append(RuntimeDeclaration(
            name: name, indexName: indexName, qualifiedName: qualifiedName, kind: kind,
            location: location, endLocation: endLocation, parentLocation: enclosingDeclarations.last,
            objectiveCName: objectiveCName,
            attributes: DeclarationCollector.attributes(from: attributes),
            isTypeMember: isTypeMember,
            isStatic: isStatic,
            isImmutable: isImmutable,
            isSettable: isSettable,
            isFinal: isFinal,
            valueTypeName: valueTypeName,
            valueTypeLocation: valueTypeLocation
        ))
    }

    private func declaredObjectiveCName(attributes: AttributeListSyntax) -> String? {
        // @objc만 붙인 클래스도 기본 런타임 이름은 Module.Type이다. 별칭은 괄호가 있을 때만 안다.
        SyntaxAttributes.objectiveCName(in: attributes)
    }

    private func objectiveCName(
        _ node: FunctionDeclSyntax,
        attributes: Set<SymbolAttribute>
    ) -> String? {
        guard !SyntaxAttributes.has("nonobjc", in: node.attributes), node.genericParameterClause == nil else {
            return nil
        }
        if let explicit = SyntaxAttributes.objectiveCName(in: node.attributes) { return explicit }
        let explicitExposure = attributes.contains(.objc) || attributes.contains(.interfaceBuilderAction)
        let isExposed = explicitExposure || (objectiveCExposure.last ?? false)
        guard isExposed else { return nil }
        let parameters = node.signature.parameterClause.parameters
        if !explicitExposure {
            // @objcMembers는 ObjC로 표현할 수 없는 메서드를 건너뛴다. 일반 타입의 표현 가능성을
            // 구문만으로 단정하지 않고, 인자·반환값이 없는 경우만 자동 이름을 부여한다.
            let returnType = node.signature.returnClause?.type.trimmedDescription
            guard parameters.isEmpty, returnType == nil || ["Void", "()"].contains(returnType!) else { return nil }
        }
        guard parameters.allSatisfy({ $0.firstName.text == "_" }) else {
            return parameters.isEmpty ? SyntaxIdentifiers.unescaped(node.name.text) : nil
        }
        return SyntaxIdentifiers.unescaped(node.name.text) + String(repeating: ":", count: parameters.count)
    }

    private func sourceLocation(_ node: some SyntaxProtocol) -> CartographCore.SourceLocation {
        let location = node.startLocation(converter: converter)
        return CartographCore.SourceLocation(path: path, line: location.line, column: location.column)
    }

    private func endLocation(_ node: some SyntaxProtocol) -> CartographCore.SourceLocation {
        let location = converter.location(for: node.endPositionBeforeTrailingTrivia)
        return CartographCore.SourceLocation(path: path, line: location.line, column: location.column)
    }
}
