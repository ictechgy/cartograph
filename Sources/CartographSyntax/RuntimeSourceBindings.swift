import CartographCore
import SwiftSyntax

struct RuntimeResolvedName {
    static let maximumByteCount = 4_096

    let text: String?
    let origin: RuntimeNameOrigin
    let referencedTargetLocation: CartographCore.SourceLocation?
    let targetMemberName: String?
    let receiverTypeName: String?
    let receiverTypeLocation: CartographCore.SourceLocation?
    let apiReferences: [RuntimeNameAPIReference]
    let reason: String?

    static func resolved(
        _ text: String,
        origin: RuntimeNameOrigin,
        referencedTargetLocation: CartographCore.SourceLocation? = nil,
        targetMemberName: String? = nil,
        receiverTypeName: String? = nil,
        receiverTypeLocation: CartographCore.SourceLocation? = nil,
        apiReferences: [RuntimeNameAPIReference] = []
    ) -> RuntimeResolvedName {
        guard text.utf8.count <= maximumByteCount else {
            return RuntimeResolvedName(
                text: nil, origin: .dynamic,
                referencedTargetLocation: referencedTargetLocation,
                targetMemberName: targetMemberName,
                receiverTypeName: receiverTypeName,
                receiverTypeLocation: receiverTypeLocation,
                apiReferences: apiReferences,
                reason: "runtime-name-exceeds-4096-bytes"
            )
        }
        return RuntimeResolvedName(
            text: text, origin: origin,
            referencedTargetLocation: referencedTargetLocation,
            targetMemberName: targetMemberName,
            receiverTypeName: receiverTypeName,
            receiverTypeLocation: receiverTypeLocation,
            apiReferences: apiReferences,
            reason: nil
        )
    }

    func addingAPIReference(_ reference: RuntimeNameAPIReference) -> RuntimeResolvedName {
        return RuntimeResolvedName(
            text: text, origin: origin,
            referencedTargetLocation: referencedTargetLocation,
            targetMemberName: targetMemberName,
            receiverTypeName: receiverTypeName,
            receiverTypeLocation: receiverTypeLocation,
            apiReferences: apiReferences + [reference],
            reason: reason
        )
    }

    func throughAlias() -> RuntimeResolvedName {
        let aliasedOrigin: RuntimeNameOrigin
        if origin == .selector { aliasedOrigin = .selector }
        else if origin == .dynamic { aliasedOrigin = .dynamic }
        else { aliasedOrigin = .constant }
        return RuntimeResolvedName(
            text: text,
            origin: aliasedOrigin,
            referencedTargetLocation: referencedTargetLocation,
            targetMemberName: targetMemberName,
            receiverTypeName: receiverTypeName,
            receiverTypeLocation: receiverTypeLocation,
            apiReferences: apiReferences,
            reason: reason
        )
    }
}

struct RuntimeReceiverHint {
    let typeName: String?
    let origin: RuntimeReceiverOrigin
    let typeLocation: CartographCore.SourceLocation?
}

struct RuntimeNotificationCenterEvidence {
    let location: CartographCore.SourceLocation
    let ownerLocation: CartographCore.SourceLocation?
}

struct RuntimePredicateFact {
    let keyPaths: [String]
    let constructorReference: RuntimeNameAPIReference
}

private enum RuntimeBoundValue {
    case immutable(expression: ExprSyntax, scopes: [Int], types: [String])
    case opaque
}

private struct RuntimeStoredValue {
    let value: RuntimeBoundValue
    let declaredAt: Int
    let availableFrom: Int?
}

private struct RuntimeReceiverBinding {
    let typeName: String
    let origin: RuntimeReceiverOrigin
    let typeLocation: CartographCore.SourceLocation
}

private struct RuntimeStoredReceiver {
    let receiver: RuntimeReceiverBinding
    let declaredAt: Int
    let availableFrom: Int?
}

/// 두 번째 패스가 앞뒤 선언 순서와 무관하게 상수와 수신자 타입을 풀 수 있게 한다.
final class RuntimeBindingCollector: SyntaxVisitor {
    struct Context {
        let scopes: [Int]
        let types: [String]
    }

    private var values: [String: [RuntimeStoredValue]] = [:]
    private var receivers: [String: [RuntimeStoredReceiver]] = [:]
    private var objectiveCMemberTypes: Set<String> = []
    private var scopes: [Int] = []
    private var types: [String] = []
    private var conditionalCompilationDepth = 0
    private let converter: SourceLocationConverter

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if SyntaxAttributes.has("objcMembers", in: node.attributes) {
            objectiveCMemberTypes.insert((types + [node.name.text]).joined(separator: "."))
        }
        return pushType(node.name.text)
    }
    override func visitPost(_: ClassDeclSyntax) { types.removeLast() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node.name.text) }
    override func visitPost(_: StructDeclSyntax) { types.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node.name.text) }
    override func visitPost(_: EnumDeclSyntax) { types.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node.name.text) }
    override func visitPost(_: ActorDeclSyntax) { types.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.extendedType.trimmedDescription)
    }
    override func visitPost(_: ExtensionDeclSyntax) { types.removeLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_: FunctionDeclSyntax) { scopes.removeLast() }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_: InitializerDeclSyntax) { scopes.removeLast() }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_: ClosureExprSyntax) { scopes.removeLast() }
    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_: AccessorBlockSyntax) { scopes.removeLast() }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_: AccessorDeclSyntax) { scopes.removeLast() }
    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_: CodeBlockSyntax) { scopes.removeLast() }
    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_: IfExprSyntax) { scopes.removeLast() }
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_: WhileStmtSyntax) { scopes.removeLast() }
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_: ForStmtSyntax) { scopes.removeLast() }
    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_: SwitchExprSyntax) { scopes.removeLast() }
    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_: SwitchCaseSyntax) { scopes.removeLast() }
    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_: CatchClauseSyntax) { scopes.removeLast() }
    override func visit(_: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        conditionalCompilationDepth += 1
        return .visitChildren
    }
    override func visitPost(_: IfConfigDeclSyntax) { conditionalCompilationDepth -= 1 }

    private func pushType(_ name: String) -> SyntaxVisitorContinueKind {
        types.append(SyntaxIdentifiers.unescaped(name))
        return .visitChildren
    }

    private func pushScope(_ node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        return .visitChildren
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        guard let identifier = node.pattern.as(IdentifierPatternSyntax.self)?.identifier,
              identifier.text != "_"
        else { return .visitChildren }
        let name = SyntaxIdentifiers.unescaped(identifier.text)
        let isLocal = DeclarationCollector.isInsideBody(node)
        let key = bindingKey(name, isLocal: isLocal)
        let declaration = node.parent?.parent?.as(VariableDeclSyntax.self)
        let isImmutable = declaration?.bindingSpecifier.tokenKind == .keyword(.let)
            && node.accessorBlock == nil
        let declaredAt = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let availableFrom = isLocal ? node.endPosition.utf8Offset : nil
        let value: RuntimeBoundValue
        if conditionalCompilationDepth > 0 {
            value = .opaque
        } else if let expression = node.initializer?.value, isImmutable {
            value = .immutable(expression: expression, scopes: scopes, types: types)
        } else {
            value = .opaque
        }
        values[key, default: []].append(RuntimeStoredValue(
            value: value, declaredAt: declaredAt, availableFrom: availableFrom
        ))
        if conditionalCompilationDepth == 0, let hint = receiverHint(binding: node) {
            receivers[key, default: []].append(RuntimeStoredReceiver(
                receiver: hint, declaredAt: declaredAt, availableFrom: availableFrom
            ))
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        let name = (node.secondName ?? node.firstName).text
        shadow(name, at: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        recordParameterReceiver(name: name, type: node.type, at: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        let name = (node.secondName ?? node.firstName).text
        shadow(name, at: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        if let type = node.type {
            recordParameterReceiver(name: name, type: type, at: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        }
        return .visitChildren
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        if node.parent?.is(PatternBindingSyntax.self) != true {
            shadow(node.identifier.text, at: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        }
        return .visitChildren
    }

    private func shadow(_ rawName: String, at offset: Int) {
        let name = SyntaxIdentifiers.unescaped(rawName)
        guard name != "_" else { return }
        values[localKey(name, scope: scopes.last), default: []].append(RuntimeStoredValue(
            value: .opaque, declaredAt: offset, availableFrom: nil
        ))
    }

    private func recordParameterReceiver(name rawName: String, type: TypeSyntax, at offset: Int) {
        let name = SyntaxIdentifiers.unescaped(rawName)
        guard name != "_", conditionalCompilationDepth == 0 else { return }
        let receiver = RuntimeReceiverBinding(
            typeName: type.trimmedDescription,
            origin: .annotation,
            typeLocation: location(type)
        )
        receivers[localKey(name, scope: scopes.last), default: []].append(RuntimeStoredReceiver(
            receiver: receiver, declaredAt: offset, availableFrom: nil
        ))
    }

    private func receiverHint(binding: PatternBindingSyntax) -> RuntimeReceiverBinding? {
        if let type = binding.typeAnnotation?.type {
            return RuntimeReceiverBinding(
                typeName: type.trimmedDescription,
                origin: .annotation,
                typeLocation: location(type)
            )
        }
        guard let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
              let token = RuntimeSyntaxNames.calleeToken(call.calledExpression),
              token.text.first?.isUppercase == true
        else { return nil }
        return RuntimeReceiverBinding(
            typeName: RuntimeSyntaxNames.dottedName(call.calledExpression) ?? token.text,
            origin: .construction,
            typeLocation: location(token)
        )
    }

    private func bindingKey(_ name: String, isLocal: Bool) -> String {
        isLocal ? localKey(name, scope: scopes.last) : (types + [name]).joined(separator: ".")
    }

    private func localKey(_ name: String, scope: Int?) -> String { "\(scope ?? -1)#\(name)" }

    private func binding(named name: String, at offset: Int, in context: Context) -> RuntimeBoundValue? {
        for scope in context.scopes.reversed() {
            if let entries = values[localKey(name, scope: scope)] {
                return selectedValue(entries, at: offset, blocksOuterWhenFuture: true)
            }
        }
        for depth in stride(from: context.types.count, through: 0, by: -1) {
            let key = (context.types.prefix(depth) + [name]).joined(separator: ".")
            if let entries = values[key] { return selectedValue(entries, at: offset) }
        }
        return nil
    }

    private func selectedValue(
        _ entries: [RuntimeStoredValue],
        at offset: Int,
        blocksOuterWhenFuture: Bool = false
    ) -> RuntimeBoundValue? {
        let eligible = entries.filter { entry in
            entry.availableFrom.map { $0 <= offset } ?? true
        }
        guard !eligible.isEmpty else { return blocksOuterWhenFuture ? .opaque : nil }
        if !blocksOuterWhenFuture, eligible.count != 1 { return .opaque }
        return eligible.max { $0.declaredAt < $1.declaredAt }?.value
    }

    private func receiver(named name: String, at offset: Int, in context: Context) -> RuntimeReceiverBinding? {
        for scope in context.scopes.reversed() {
            let key = localKey(name, scope: scope)
            if let entries = receivers[key] {
                return selectedReceiver(entries, at: offset)
            }
            if values[key] != nil { return nil }
        }
        for depth in stride(from: context.types.count, through: 0, by: -1) {
            let key = (context.types.prefix(depth) + [name]).joined(separator: ".")
            if let entries = receivers[key] { return selectedReceiver(entries, at: offset, requireUnique: true) }
            if values[key] != nil { return nil }
        }
        return nil
    }

    private func selectedReceiver(
        _ entries: [RuntimeStoredReceiver],
        at offset: Int,
        requireUnique: Bool = false
    ) -> RuntimeReceiverBinding? {
        let eligible = entries.filter { $0.availableFrom.map { $0 <= offset } ?? true }
        guard !eligible.isEmpty, !requireUnique || eligible.count == 1 else { return nil }
        return eligible.max { $0.declaredAt < $1.declaredAt }?.receiver
    }

    func resolveName(_ expression: ExprSyntax, in context: Context) -> RuntimeResolvedName? {
        resolveName(RuntimeSyntaxNames.unparenthesized(expression), in: context, remaining: 64)
    }

    func immutableExpression(_ rawExpression: ExprSyntax, in context: Context) -> (ExprSyntax, Context)? {
        let expression = RuntimeSyntaxNames.unparenthesized(rawExpression)
        guard let bound = boundValue(for: expression, in: context),
              case let .immutable(value, scopes, types) = bound
        else { return nil }
        return (value, Context(scopes: scopes, types: types))
    }

    func nameEvidenceLocation(_ expression: ExprSyntax, in context: Context) -> CartographCore.SourceLocation {
        nameEvidenceLocation(expression, in: context, remaining: 64) ?? location(expression)
    }

    private func nameEvidenceLocation(
        _ rawExpression: ExprSyntax,
        in context: Context,
        remaining: Int
    ) -> CartographCore.SourceLocation? {
        guard remaining > 0 else { return nil }
        let expression = RuntimeSyntaxNames.unparenthesized(rawExpression)
        if let bound = boundValue(for: expression, in: context),
           case let .immutable(value, scopes, types) = bound {
            return nameEvidenceLocation(
                value,
                in: Context(scopes: scopes, types: types),
                remaining: remaining - 1
            )
        }
        if let call = expression.as(FunctionCallExprSyntax.self),
           RuntimeSyntaxNames.nameAPI(call.calledExpression) != nil,
           let argument = call.arguments.first?.expression {
            return nameEvidenceLocation(argument, in: context, remaining: remaining - 1)
        }
        if let member = expression.as(MemberAccessExprSyntax.self) { return location(member.declName.baseName) }
        if let reference = expression.as(DeclReferenceExprSyntax.self) { return location(reference.baseName) }
        return location(expression)
    }

    func notificationCenterEvidence(
        for call: FunctionCallExprSyntax,
        in context: Context
    ) -> RuntimeNotificationCenterEvidence? {
        guard let receiver = call.calledExpression.as(MemberAccessExprSyntax.self)?.base else { return nil }
        if let stable = stableCenterEvidence(receiver, in: context, remaining: 64) { return stable }
        guard let location = identityConstructionLocation(receiver, in: context, remaining: 64) else { return nil }
        return RuntimeNotificationCenterEvidence(location: location, ownerLocation: nil)
    }

    private func stableCenterEvidence(
        _ rawExpression: ExprSyntax,
        in context: Context,
        remaining: Int
    ) -> RuntimeNotificationCenterEvidence? {
        guard remaining > 0 else { return nil }
        let expression = RuntimeSyntaxNames.unparenthesized(rawExpression)
        if let member = expression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "default" {
            return RuntimeNotificationCenterEvidence(
                location: location(member.declName.baseName), ownerLocation: nil
            )
        }
        if let center = expression.as(MemberAccessExprSyntax.self),
           center.declName.baseName.text == "notificationCenter",
           let shared = center.base?.as(MemberAccessExprSyntax.self),
           shared.declName.baseName.text == "shared",
           let workspace = shared.base,
           RuntimeSyntaxNames.dottedName(workspace).map({
               $0 == "NSWorkspace" || $0.hasSuffix(".NSWorkspace")
           }) == true {
            return RuntimeNotificationCenterEvidence(
                location: location(center.declName.baseName),
                ownerLocation: location(shared.declName.baseName)
            )
        }
        guard let bound = boundValue(for: expression, in: context),
              case let .immutable(value, scopes, types) = bound
        else { return nil }
        return stableCenterEvidence(
            value,
            in: Context(scopes: scopes, types: types),
            remaining: remaining - 1
        )
    }

    func notificationObjectLocation(
        for call: FunctionCallExprSyntax,
        in context: Context
    ) -> CartographCore.SourceLocation? {
        guard let object = call.arguments.first(where: { $0.label?.text == "object" })?.expression,
              !RuntimeSyntaxNames.isNil(object)
        else { return nil }
        return identityConstructionLocation(object, in: context, remaining: 64)
    }

    private func identityConstructionLocation(
        _ rawExpression: ExprSyntax,
        in context: Context,
        remaining: Int
    ) -> CartographCore.SourceLocation? {
        guard remaining > 0 else { return nil }
        let expression = RuntimeSyntaxNames.unparenthesized(rawExpression)
        if let call = expression.as(FunctionCallExprSyntax.self),
           let token = RuntimeSyntaxNames.calleeToken(call.calledExpression),
           token.text.first?.isUppercase == true {
            return location(token)
        }
        guard let bound = boundValue(for: expression, in: context),
              case let .immutable(value, scopes, types) = bound,
              scopes == context.scopes, types == context.types
        else { return nil }
        return identityConstructionLocation(
            value,
            in: Context(scopes: scopes, types: types),
            remaining: remaining - 1
        )
    }

    private func resolveName(
        _ expression: ExprSyntax,
        in context: Context,
        remaining: Int
    ) -> RuntimeResolvedName? {
        guard remaining > 0 else { return nil }
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            if let value = literal.representedLiteralValue { return .resolved(value, origin: .literal) }
            if let interpolated = resolveInterpolation(literal, in: context, remaining: remaining - 1) {
                return .resolved(
                    interpolated.text,
                    origin: .constant,
                    apiReferences: interpolated.apiReferences
                )
            }
        }
        if let selector = expression.as(MacroExpansionExprSyntax.self), selector.macroName.text == "selector" {
            return selectorValue(selector, enclosingTypes: context.types)
        }
        if let infix = expression.as(InfixOperatorExprSyntax.self),
           let plus = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator,
           plus.text == "+",
           let lhs = resolveName(infix.leftOperand, in: context, remaining: remaining - 1),
           let rhs = resolveName(infix.rightOperand, in: context, remaining: remaining - 1),
           let lhsText = lhs.text, let rhsText = rhs.text,
           lhs.referencedTargetLocation == nil, rhs.referencedTargetLocation == nil {
            return .resolved(
                lhsText + rhsText,
                origin: .constant,
                apiReferences: lhs.apiReferences + rhs.apiReferences + [
                    RuntimeNameAPIReference(api: "String.+", location: location(plus))
                ]
            )
        }
        if let call = expression.as(FunctionCallExprSyntax.self),
           let constructor = RuntimeSyntaxNames.nameAPI(call.calledExpression),
           let argument = call.arguments.first?.expression,
           let resolved = resolveName(argument, in: context, remaining: remaining - 1) {
            return resolved.addingAPIReference(RuntimeNameAPIReference(
                api: constructor.api,
                location: location(constructor.token)
            ))
        }
        guard let bound = boundValue(for: expression, in: context) else { return nil }
        guard case let .immutable(value, scopes, types) = bound,
              let resolved = resolveName(value, in: Context(scopes: scopes, types: types), remaining: remaining - 1)
        else { return nil }
        return resolved.throughAlias()
    }

    private func resolveInterpolation(
        _ literal: StringLiteralExprSyntax,
        in context: Context,
        remaining: Int
    ) -> (text: String, apiReferences: [RuntimeNameAPIReference])? {
        guard remaining > 0 else { return nil }
        var text = ""
        var references: [RuntimeNameAPIReference] = []
        for segment in literal.segments {
            switch segment {
            case let .stringSegment(value):
                let content = value.content.text
                guard !content.contains("\\"), !content.contains("\n"), !content.contains("\r") else { return nil }
                text += content
            case let .expressionSegment(value):
                guard value.expressions.count == 1,
                      let expression = value.expressions.first?.expression,
                      let primitive = primitiveInterpolationValue(
                        expression,
                        in: context,
                        remaining: remaining - 1
                      )
                else { return nil }
                text += primitive.text
                references += primitive.apiReferences
            }
        }
        return (text, references)
    }

    private func primitiveInterpolationValue(
        _ rawExpression: ExprSyntax,
        in context: Context,
        remaining: Int
    ) -> (text: String, apiReferences: [RuntimeNameAPIReference])? {
        guard remaining > 0 else { return nil }
        let expression = RuntimeSyntaxNames.unparenthesized(rawExpression)
        if let string = expression.as(StringLiteralExprSyntax.self) {
            if let value = string.representedLiteralValue { return (value, []) }
            return resolveInterpolation(string, in: context, remaining: remaining - 1)
        }
        if let integer = expression.as(IntegerLiteralExprSyntax.self)?.representedLiteralValue {
            return (String(integer), [])
        }
        if let floating = expression.as(FloatLiteralExprSyntax.self)?.representedLiteralValue {
            return (String(floating), [])
        }
        if let boolean = expression.as(BooleanLiteralExprSyntax.self) {
            return (boolean.literal.text, [])
        }
        if expression.is(InfixOperatorExprSyntax.self),
           let resolved = resolveName(expression, in: context, remaining: remaining - 1),
           let text = resolved.text {
            return (text, resolved.apiReferences)
        }
        guard let bound = boundValue(for: expression, in: context),
              case let .immutable(value, scopes, types) = bound
        else { return nil }
        return primitiveInterpolationValue(
            value,
            in: Context(scopes: scopes, types: types),
            remaining: remaining - 1
        )
    }

    private func boundValue(for expression: ExprSyntax, in context: Context) -> RuntimeBoundValue? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return binding(
                named: SyntaxIdentifiers.unescaped(reference.baseName.text),
                at: expression.position.utf8Offset,
                in: context
            )
        }
        guard let member = expression.as(MemberAccessExprSyntax.self), let base = member.base,
              let baseName = RuntimeSyntaxNames.dottedName(base)
        else { return nil }
        let name = SyntaxIdentifiers.unescaped(member.declName.baseName.text)
        if ["self", "Self"].contains(baseName) {
            return values[(context.types + [name]).joined(separator: ".")].flatMap {
                selectedValue($0, at: expression.position.utf8Offset)
            }
        }
        return values[baseName + "." + name].flatMap {
            selectedValue($0, at: expression.position.utf8Offset)
        }
    }

    func receiverHint(_ expression: ExprSyntax, in context: Context) -> RuntimeReceiverHint {
        let expression = RuntimeSyntaxNames.unparenthesized(expression)
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            let name = SyntaxIdentifiers.unescaped(reference.baseName.text)
            if name == "self" {
                return RuntimeReceiverHint(
                    typeName: context.types.last, origin: .enclosingType,
                    typeLocation: context.types.isEmpty ? nil : location(reference.baseName)
                )
            }
            if let hint = receiver(named: name, at: expression.position.utf8Offset, in: context) {
                return RuntimeReceiverHint(
                    typeName: hint.typeName, origin: hint.origin, typeLocation: hint.typeLocation
                )
            }
        }
        if let call = expression.as(FunctionCallExprSyntax.self),
           let token = RuntimeSyntaxNames.calleeToken(call.calledExpression),
           token.text.first?.isUppercase == true {
            return RuntimeReceiverHint(
                typeName: RuntimeSyntaxNames.dottedName(call.calledExpression) ?? token.text,
                origin: .construction, typeLocation: location(token)
            )
        }
        return RuntimeReceiverHint(typeName: nil, origin: .unknown, typeLocation: nil)
    }

    func exposesObjectiveCMembers(typeName: String) -> Bool {
        objectiveCMemberTypes.contains(typeName)
            || objectiveCMemberTypes.contains(where: { $0.hasSuffix("." + typeName) })
    }

    private func selectorValue(
        _ selector: MacroExpansionExprSyntax,
        enclosingTypes: [String]
    ) -> RuntimeResolvedName? {
        guard let target = selector.arguments.first?.expression,
              let descriptor = RuntimeSyntaxNames.selectorTarget(target)
        else { return nil }
        let receiver = descriptor.receiverType ?? enclosingTypes.last
        return .resolved(
            descriptor.selector,
            origin: .selector,
            referencedTargetLocation: location(descriptor.token),
            targetMemberName: descriptor.member,
            receiverTypeName: receiver,
            receiverTypeLocation: descriptor.receiverToken.map(location)
        )
    }

    private func location(_ node: some SyntaxProtocol) -> CartographCore.SourceLocation {
        let value = node.startLocation(converter: converter)
        return CartographCore.SourceLocation(path: value.file, line: value.line, column: value.column)
    }
}
