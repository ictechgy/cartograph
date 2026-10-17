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

    /// 상한을 넘어 글자를 끝까지 만들지 않은 보간. 글자를 만들어 `resolved` 에 넘겼을 때와 같은 값이다.
    static func oversized(apiReferences: [RuntimeNameAPIReference]) -> RuntimeResolvedName {
        RuntimeResolvedName(
            text: nil, origin: .dynamic,
            referencedTargetLocation: nil, targetMemberName: nil,
            receiverTypeName: nil, receiverTypeLocation: nil,
            apiReferences: apiReferences,
            reason: "runtime-name-exceeds-4096-bytes"
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
    struct Context: Hashable {
        let scopes: [Int]
        let types: [String]
    }

    /// 해석 결과를 가르는 입력 전부. 바인딩은 첫 패스에서 다 모은 뒤 바뀌지 않으므로 식·문맥·남은 예산이
    /// 같으면 답도 같다. 예산을 키에 넣어, 깊이 상한에 걸린 자리의 nil 이 더 얕은 자리의 답을 덮지 않게 한다.
    private struct ResolutionKey: Hashable {
        enum Step: Hashable { case name, interpolation, primitive }
        let step: Step
        let expression: SyntaxIdentifier
        let context: Context
        let remaining: Int
    }

    /// 펼친 보간. 글자가 이름 상한을 넘었으면 `text` 는 nil 이다(넘친 이름은 결국 동적 이름이 된다).
    private typealias Interpolated = (text: String?, apiReferences: [RuntimeNameAPIReference])

    /// 메모한 답(nil 포함). 상자에 담아 조회·저장이 재귀 한 단계의 스택에 큰 임시 값을 남기지 않게 한다.
    private final class Memoized<Value> {
        let value: Value?
        init(_ value: Value?) { self.value = value }
    }

    private var values: [String: [RuntimeStoredValue]] = [:]
    private var receivers: [String: [RuntimeStoredReceiver]] = [:]
    private var objectiveCMemberTypes: Set<String> = []
    private var scopes: [Int] = []
    private var types: [String] = []
    private var conditionalCompilationDepth = 0
    private let converter: SourceLocationConverter
    /// `x1 = x0 + x0` 처럼 앞 별칭을 두 번 쓰는 사슬은 메모가 없으면 단계마다 해석이 두 배가 된다.
    /// 25줄짜리 파일 하나로 기본 분석 경로가 수십 GB 를 썼다.
    private var resolvedNames: [ResolutionKey: Memoized<RuntimeResolvedName>] = [:]
    private var interpolatedValues: [ResolutionKey: Memoized<Interpolated>] = [:]
    /// 메모에 없어 실제로 계산한 해석 횟수. 테스트가 사슬 길이에 비례하는지 센다.
    private(set) var resolutionCount = 0

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
        let key = ResolutionKey(step: .name, expression: expression.id, context: context, remaining: remaining)
        if let memoized = resolvedNames[key] { return memoized.value }
        resolutionCount += 1
        let resolved = evaluateName(expression, in: context, remaining: remaining)
        resolvedNames[key] = Memoized(resolved)
        return resolved
    }

    /// 식 종류는 서로 겹치지 않고, 갈래가 실패하면 결국 nil 이므로 종류마다 한 갈래만 탄다. 갈래를 함수로 나눠
    /// 재귀 한 단계의 스택에는 탄 갈래의 지역 값만 쌓이게 한다. 메모 단계를 더한 뒤 한 함수에 모든 갈래를 두면
    /// 디버그 빌드에서 예산 64 단계 별칭 사슬이 테스트 스레드 스택을 넘었다.
    private func evaluateName(
        _ expression: ExprSyntax,
        in context: Context,
        remaining: Int
    ) -> RuntimeResolvedName? {
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            return literalName(literal, in: context, remaining: remaining)
        }
        if let macro = expression.as(MacroExpansionExprSyntax.self) {
            return macro.macroName.text == "selector" ? selectorValue(macro, enclosingTypes: context.types) : nil
        }
        if let infix = expression.as(InfixOperatorExprSyntax.self) {
            return concatenatedName(infix, in: context, remaining: remaining)
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return constructedName(call, in: context, remaining: remaining)
        }
        return aliasedName(expression, in: context, remaining: remaining)
    }

    private func literalName(
        _ literal: StringLiteralExprSyntax,
        in context: Context,
        remaining: Int
    ) -> RuntimeResolvedName? {
        if let value = literal.representedLiteralValue { return .resolved(value, origin: .literal) }
        guard let interpolated = resolveInterpolation(literal, in: context, remaining: remaining - 1) else {
            return nil
        }
        guard let text = interpolated.text else { return .oversized(apiReferences: interpolated.apiReferences) }
        return .resolved(text, origin: .constant, apiReferences: interpolated.apiReferences)
    }

    private func concatenatedName(
        _ infix: InfixOperatorExprSyntax,
        in context: Context,
        remaining: Int
    ) -> RuntimeResolvedName? {
        guard let plus = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator,
              plus.text == "+",
              let lhs = resolveName(infix.leftOperand, in: context, remaining: remaining - 1),
              let rhs = resolveName(infix.rightOperand, in: context, remaining: remaining - 1),
              let lhsText = lhs.text, let rhsText = rhs.text,
              lhs.referencedTargetLocation == nil, rhs.referencedTargetLocation == nil
        else { return nil }
        return .resolved(
            lhsText + rhsText,
            origin: .constant,
            apiReferences: Self.distinct(lhs.apiReferences + rhs.apiReferences + [
                RuntimeNameAPIReference(api: "String.+", location: location(plus))
            ])
        )
    }

    private func constructedName(
        _ call: FunctionCallExprSyntax,
        in context: Context,
        remaining: Int
    ) -> RuntimeResolvedName? {
        guard let constructor = RuntimeSyntaxNames.nameAPI(call.calledExpression),
              let argument = call.arguments.first?.expression,
              let resolved = resolveName(argument, in: context, remaining: remaining - 1)
        else { return nil }
        return resolved.addingAPIReference(RuntimeNameAPIReference(
            api: constructor.api,
            location: location(constructor.token)
        ))
    }

    private func aliasedName(
        _ expression: ExprSyntax,
        in context: Context,
        remaining: Int
    ) -> RuntimeResolvedName? {
        guard let bound = boundValue(for: expression, in: context),
              case let .immutable(value, scopes, types) = bound,
              let resolved = resolveName(value, in: Context(scopes: scopes, types: types), remaining: remaining - 1)
        else { return nil }
        return resolved.throughAlias()
    }

    private func resolveInterpolation(
        _ literal: StringLiteralExprSyntax,
        in context: Context,
        remaining: Int
    ) -> Interpolated? {
        guard remaining > 0 else { return nil }
        let key = ResolutionKey(step: .interpolation, expression: literal.id, context: context, remaining: remaining)
        if let memoized = interpolatedValues[key] { return memoized.value }
        resolutionCount += 1
        let value = evaluateInterpolation(literal, in: context, remaining: remaining)
        interpolatedValues[key] = Memoized(value)
        return value
    }

    /// 상한을 넘은 뒤에도 나머지 조각을 끝까지 풀어, 해석 가능 여부와 근거는 상한이 없을 때와 같게 둔다.
    private func evaluateInterpolation(
        _ literal: StringLiteralExprSyntax,
        in context: Context,
        remaining: Int
    ) -> Interpolated? {
        var text: String? = ""
        var references: [RuntimeNameAPIReference] = []
        for segment in literal.segments {
            switch segment {
            case let .stringSegment(value):
                let content = value.content.text
                guard !content.contains("\\"), !content.contains("\n"), !content.contains("\r") else { return nil }
                text = Self.appending(content, to: text)
            case let .expressionSegment(value):
                guard value.expressions.count == 1,
                      let expression = value.expressions.first?.expression,
                      let primitive = primitiveInterpolationValue(
                        expression,
                        in: context,
                        remaining: remaining - 1
                      )
                else { return nil }
                text = primitive.text.flatMap { Self.appending($0, to: text) }
                references += primitive.apiReferences
            }
        }
        return (text, Self.distinct(references))
    }

    private func primitiveInterpolationValue(
        _ rawExpression: ExprSyntax,
        in context: Context,
        remaining: Int
    ) -> Interpolated? {
        guard remaining > 0 else { return nil }
        let key = ResolutionKey(step: .primitive, expression: rawExpression.id, context: context, remaining: remaining)
        if let memoized = interpolatedValues[key] { return memoized.value }
        resolutionCount += 1
        let value = evaluatePrimitiveInterpolation(rawExpression, in: context, remaining: remaining)
        interpolatedValues[key] = Memoized(value)
        return value
    }

    /// 넘친 보간은 글자를 더 붙이지 않는다. 바깥 글자는 안쪽 글자를 그대로 품으므로 한 번 넘치면 끝까지 넘친다.
    /// 셋으로 갈라지는 보간 사슬은 메모가 있어도 3ⁿ 바이트를 만들었다.
    private static func appending(_ piece: String, to text: String?) -> String? {
        guard let text, text.utf8.count + piece.utf8.count <= RuntimeResolvedName.maximumByteCount else { return nil }
        return text + piece
    }

    /// 근거를 처음 나온 순서로 한 번씩만 남긴다. 같은 별칭을 양쪽에서 쓰는 결합이 단계마다 목록을 두 배로
    /// 키우지 않게 한다. 근거는 모두 검증해야 하는 집합이라 중복을 빼도 판정은 같다.
    private static func distinct(_ references: [RuntimeNameAPIReference]) -> [RuntimeNameAPIReference] {
        var seen: Set<RuntimeNameAPIReference> = []
        return references.filter { seen.insert($0).inserted }
    }

    private func evaluatePrimitiveInterpolation(
        _ rawExpression: ExprSyntax,
        in context: Context,
        remaining: Int
    ) -> Interpolated? {
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
