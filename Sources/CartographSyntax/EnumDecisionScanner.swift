import CartographCore
import SwiftSyntax

/// 컴파일러 바인딩 전의 이름과 정확한 토큰 위치를 함께 보존한다.
public struct EnumCaseTokenFacts: Codable, Sendable, Equatable {
    public let name: String
    public let location: CartographCore.SourceLocation

    /// 이름만으로 다른 열거형의 동명 케이스와 합쳐지지 않게 한다.
    public init(name: String, location: CartographCore.SourceLocation) {
        self.name = name
        self.location = location
    }
}

/// 소스에서 보인 케이스 목록이 전체 목록인지 별도로 보존한다.
public struct EnumInventorySyntaxFacts: Codable, Sendable, Equatable {
    public let name: String
    public let nameLocation: CartographCore.SourceLocation
    public let range: SourceRange
    public let cases: [EnumCaseTokenFacts]
    public let isComplete: Bool
    public let limitations: [String]

    /// 조건부 컴파일·매크로·파싱 오류가 있는 목록을 완전한 목록으로 쓰지 않게 한다.
    public init(
        name: String, nameLocation: CartographCore.SourceLocation, range: SourceRange,
        cases: [EnumCaseTokenFacts], isComplete: Bool, limitations: [String]
    ) {
        self.name = name
        self.nameLocation = nameLocation
        self.range = range
        self.cases = cases
        self.isComplete = isComplete
        self.limitations = limitations
    }
}

/// 구문 모양만 표현하며 contains나 !의 표준 라이브러리 의미를 보증하지 않는다.
public enum EnumDecisionSyntaxKind: String, Codable, Sendable {
    case switchDefault
    case switchUnknownDefault
    case literalMembership
    case negatedLiteralMembership
}

/// 지역 참조를 추측하지 않고 명시적 함수 파라미터의 타입 표기와 조인한다.
public struct EnumSubjectParameterSyntaxFacts: Codable, Sendable, Equatable {
    public let parameterName: String
    public let subjectLocation: CartographCore.SourceLocation
    public let parameterNameLocation: CartographCore.SourceLocation
    public let typeNameLocation: CartographCore.SourceLocation
    public let functionRange: SourceRange

    /// 타입 이름의 컴파일러 참조와 파라미터의 소유 함수를 함께 검증하게 한다.
    public init(
        parameterName: String, subjectLocation: CartographCore.SourceLocation,
        parameterNameLocation: CartographCore.SourceLocation,
        typeNameLocation: CartographCore.SourceLocation, functionRange: SourceRange
    ) {
        self.parameterName = parameterName
        self.subjectLocation = subjectLocation
        self.parameterNameLocation = parameterNameLocation
        self.typeNameLocation = typeNameLocation
        self.functionRange = functionRange
    }
}

/// 분기 본문의 참조와 패턴의 참조를 섞지 않고 정확한 바인딩 지점을 넘긴다.
public struct EnumDecisionSyntaxFacts: Codable, Sendable, Equatable {
    public let kind: EnumDecisionSyntaxKind
    public let range: SourceRange
    public let subjectRange: SourceRange?
    public let subjectParameter: EnumSubjectParameterSyntaxFacts?
    public let explicitCases: [EnumCaseTokenFacts]
    public let guardedCases: [EnumCaseTokenFacts]
    public let fallbackLocations: [CartographCore.SourceLocation]
    public let operationLocation: CartographCore.SourceLocation?
    public let negationLocation: CartographCore.SourceLocation?
    public let limitations: [String]

    /// 제한이 없어도 구문 후보일 뿐이며 컴파일러 심볼·신선도 검증이 필요하다.
    public init(
        kind: EnumDecisionSyntaxKind, range: SourceRange, subjectRange: SourceRange?,
        explicitCases: [EnumCaseTokenFacts], guardedCases: [EnumCaseTokenFacts],
        fallbackLocations: [CartographCore.SourceLocation],
        operationLocation: CartographCore.SourceLocation? = nil,
        negationLocation: CartographCore.SourceLocation? = nil,
        subjectParameter: EnumSubjectParameterSyntaxFacts? = nil,
        limitations: [String] = []
    ) {
        self.kind = kind
        self.range = range
        self.subjectRange = subjectRange
        self.subjectParameter = subjectParameter
        self.explicitCases = explicitCases
        self.guardedCases = guardedCases
        self.fallbackLocations = fallbackLocations
        self.operationLocation = operationLocation
        self.negationLocation = negationLocation
        self.limitations = limitations
    }
}

/// 빈 결과와 아직 수집하지 않은 예전 캐시를 구분할 수 있게 파일 단위로 묶는다.
public struct EnumDecisionScanFacts: Codable, Sendable, Equatable {
    public let inventories: [EnumInventorySyntaxFacts]
    public let decisions: [EnumDecisionSyntaxFacts]
    public let limitations: [String]

    /// 숨은 확장이나 오류 때문에 스캔하지 못한 부분도 호출자에게 전달한다.
    public init(
        inventories: [EnumInventorySyntaxFacts], decisions: [EnumDecisionSyntaxFacts],
        limitations: [String] = []
    ) {
        self.inventories = inventories
        self.decisions = decisions
        self.limitations = limitations
    }
}

/// default 분기와 직접 배열 리터럴의 contains만 좁게 수집한다.
///
/// if-case·동등 비교·임의 함수·사용자 연산자의 분기 의미는 해석하지 않는다.
/// 동적 컬렉션과 allCases/filter 기반 contains는 제한이 있는 후보로 남긴다.
struct EnumDecisionScanner {
    func scan(
        tree: SourceFileSyntax, path: String, converter: SourceLocationConverter
    ) -> EnumDecisionScanFacts {
        let collector = EnumDecisionCollector(path: path, converter: converter)
        collector.walk(tree)
        return EnumDecisionScanFacts(
            inventories: collector.inventories,
            decisions: collector.decisions,
            limitations: collector.fileLimitations.sorted()
        )
    }
}

/// 재귀 방문은 후보 발견에만 쓰며 각 후보의 근거는 자신의 패턴에서만 읽는다.
private final class EnumDecisionCollector: SyntaxVisitor {
    private let path: String
    private let converter: SourceLocationConverter
    private(set) var inventories: [EnumInventorySyntaxFacts] = []
    private(set) var decisions: [EnumDecisionSyntaxFacts] = []
    private(set) var fileLimitations: Set<String> = []

    init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
        if node.hasError { fileLimitations.insert("enum-decision-source-parse-errors") }
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        fileLimitations.insert("enum-decision-unexpanded-macro")
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        fileLimitations.insert("enum-decision-unexpanded-macro")
        return .visitChildren
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        if !EnumDecisionShape.knownAttributes.contains(node.attributeName.trimmedDescription) {
            fileLimitations.insert("enum-decision-unresolved-attribute")
        }
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.presence == .present else {
            fileLimitations.insert("enum-inventory-missing-name")
            return .visitChildren
        }
        var reasons = contextLimitations(node)
        if node.hasError { reasons.insert("enum-inventory-parse-errors") }
        var tokens: [EnumCaseTokenFacts] = []
        inventoryMembers(node.memberBlock.members, tokens: &tokens, reasons: &reasons)
        inventories.append(EnumInventorySyntaxFacts(
            name: SyntaxIdentifiers.unescaped(node.name.text),
            nameLocation: location(node.name), range: range(node), cases: tokens,
            isComplete: reasons.isEmpty, limitations: reasons.sorted()
        ))
        return .visitChildren
    }

    private func inventoryMembers(
        _ members: MemberBlockItemListSyntax,
        tokens: inout [EnumCaseTokenFacts], reasons: inout Set<String>
    ) {
        for item in members {
            if EnumDecisionShape.hasUnresolvedAttributes(item.decl) {
                reasons.insert("enum-inventory-unresolved-attribute")
            }
            if let declaration = item.decl.as(EnumCaseDeclSyntax.self) {
                tokens += declaration.elements.compactMap { token($0.name) }
            } else if let conditional = item.decl.as(IfConfigDeclSyntax.self) {
                reasons.insert("enum-inventory-conditional-compilation")
                for clause in conditional.clauses {
                    if case let .decls(nested)? = clause.elements {
                        inventoryMembers(nested, tokens: &tokens, reasons: &reasons)
                    }
                }
            } else if item.decl.is(MacroExpansionDeclSyntax.self) {
                reasons.insert("enum-inventory-unexpanded-macro")
            }
        }
    }

    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        var reasons = contextLimitations(node)
        if node.hasError { reasons.insert("enum-decision-parse-errors") }
        var arms: [SwitchCaseSyntax] = []
        switchArms(node.cases, result: &arms, reasons: &reasons)
        let fallbacks = arms.filter { arm in
            if case .default = arm.label { return true }
            return false
        }
        guard !fallbacks.isEmpty else { return .visitChildren }
        let subjectParameter = parameterEvidence(node.subject, at: node)
        if subjectParameter == nil { reasons.insert("enum-decision-unverified-subject-type") }

        var explicit: [EnumCaseTokenFacts] = []
        var guarded: [EnumCaseTokenFacts] = []
        for arm in arms {
            if let attribute = arm.attribute, attribute.attributeName.trimmedDescription != "unknown" {
                reasons.insert("enum-decision-unsupported-switch-attribute")
            }
            guard case let .case(label) = arm.label else { continue }
            for item in label.caseItems {
                guard let shape = EnumDecisionShape.casePattern(item.pattern),
                      let value = token(shape.token) else {
                    reasons.insert("enum-decision-unsupported-switch-pattern")
                    continue
                }
                if item.whereClause != nil || !shape.coversWholeCase {
                    guarded.append(value)
                } else {
                    explicit.append(value)
                }
            }
        }
        if explicit.isEmpty && guarded.isEmpty { reasons.insert("enum-decision-no-case-tokens") }
        if fallbacks.count != 1 { reasons.insert("enum-decision-multiple-fallbacks") }
        let unknown = fallbacks.allSatisfy { $0.attribute?.attributeName.trimmedDescription == "unknown" }
        decisions.append(EnumDecisionSyntaxFacts(
            kind: unknown ? .switchUnknownDefault : .switchDefault,
            range: range(node), subjectRange: range(node.subject),
            explicitCases: explicit, guardedCases: guarded,
            fallbackLocations: fallbacks.compactMap { arm in
                guard case let .default(label) = arm.label else { return nil }
                return location(label.defaultKeyword)
            },
            subjectParameter: subjectParameter,
            limitations: reasons.sorted()
        ))
        return .visitChildren
    }

    private func switchArms(
        _ list: SwitchCaseListSyntax,
        result: inout [SwitchCaseSyntax], reasons: inout Set<String>
    ) {
        for element in list {
            switch element {
            case let .switchCase(arm):
                result.append(arm)
            case let .ifConfigDecl(conditional):
                reasons.insert("enum-decision-conditional-compilation")
                for clause in conditional.clauses {
                    if case let .switchCases(nested)? = clause.elements {
                        switchArms(nested, result: &result, reasons: &reasons)
                    }
                }
            }
        }
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "contains" else { return .visitChildren }
        var reasons = contextLimitations(node)
        if node.hasError { reasons.insert("enum-decision-parse-errors") }
        let context = EnumDecisionShape.membershipContext(node)
        reasons.formUnion(context.limitations)
        let supportedCall = node.arguments.count == 1
            && node.arguments.first?.label == nil
            && node.trailingClosure == nil && node.additionalTrailingClosures.isEmpty
            && member.declName.argumentNames == nil
        if !supportedCall { reasons.insert("enum-decision-unsupported-membership-call") }
        var explicit: [EnumCaseTokenFacts] = []
        if let base = member.base, let array = EnumDecisionShape.unwrapped(base).as(ArrayExprSyntax.self) {
            if array.elements.isEmpty { reasons.insert("enum-decision-empty-literal") }
            for element in array.elements {
                guard let caseToken = EnumDecisionShape.directMember(element.expression),
                      let value = token(caseToken) else {
                    reasons.insert("enum-decision-unsupported-literal-element")
                    continue
                }
                explicit.append(value)
            }
        } else {
            reasons.insert("enum-decision-nonliteral-membership-receiver")
        }
        let subjectParameter = supportedCall ? node.arguments.first.flatMap {
            parameterEvidence($0.expression, at: node)
        } : nil
        if subjectParameter == nil { reasons.insert("enum-decision-unverified-subject-type") }
        decisions.append(EnumDecisionSyntaxFacts(
            kind: context.negation == nil ? .literalMembership : .negatedLiteralMembership,
            range: range(context.root),
            subjectRange: supportedCall ? node.arguments.first.map { range($0.expression) } : nil,
            explicitCases: explicit, guardedCases: [], fallbackLocations: [],
            operationLocation: location(member.declName.baseName),
            negationLocation: context.negation.map { location($0) },
            subjectParameter: subjectParameter,
            limitations: reasons.sorted()
        ))
        return .visitChildren
    }

    private func parameterEvidence(
        _ subject: ExprSyntax, at use: some SyntaxProtocol
    ) -> EnumSubjectParameterSyntaxFacts? {
        guard let reference = EnumDecisionShape.unwrapped(subject).as(DeclReferenceExprSyntax.self),
              reference.argumentNames == nil,
              let function = EnumDecisionShape.enclosingFunction(use), !function.hasError,
              let body = function.body else { return nil }
        let name = SyntaxIdentifiers.unescaped(reference.baseName.text)
        let parameters = function.signature.parameterClause.parameters.filter {
            SyntaxIdentifiers.unescaped(($0.secondName ?? $0.firstName).text) == name
        }
        guard parameters.count == 1, let parameter = parameters.first, parameter.ellipsis == nil,
              parameter.attributes.isEmpty, parameter.modifiers.isEmpty,
              let typeName = EnumDecisionShape.simpleTypeName(parameter.type) else { return nil }
        let shadow = EnumSubjectShadowFinder(name: name, before: reference.positionAfterSkippingLeadingTrivia)
        shadow.walk(body)
        guard !shadow.found else { return nil }
        return EnumSubjectParameterSyntaxFacts(
            parameterName: name, subjectLocation: location(reference.baseName),
            parameterNameLocation: location(parameter.secondName ?? parameter.firstName),
            typeNameLocation: location(typeName), functionRange: range(function)
        )
    }

    private func contextLimitations(_ node: some SyntaxProtocol) -> Set<String> {
        var reasons: Set<String> = []
        var current: Syntax? = Syntax(node)
        while let syntax = current {
            if syntax.is(IfConfigDeclSyntax.self) { reasons.insert("enum-decision-conditional-compilation") }
            if EnumDecisionShape.hasUnresolvedAttributes(syntax) {
                reasons.insert("enum-decision-unresolved-attribute")
            }
            if syntax.is(MacroExpansionExprSyntax.self) || syntax.is(MacroExpansionDeclSyntax.self) {
                reasons.insert("enum-decision-unexpanded-macro")
            }
            current = syntax.parent
        }
        return reasons
    }

    private func token(_ token: TokenSyntax) -> EnumCaseTokenFacts? {
        guard token.presence == .present, !token.text.isEmpty else { return nil }
        return EnumCaseTokenFacts(name: SyntaxIdentifiers.unescaped(token.text), location: location(token))
    }

    private func location(_ node: some SyntaxProtocol) -> CartographCore.SourceLocation {
        let point = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return CartographCore.SourceLocation(path: path, line: point.line, column: point.column)
    }

    private func range(_ node: some SyntaxProtocol) -> SourceRange {
        let end = converter.location(for: node.endPositionBeforeTrailingTrivia)
        return SourceRange(
            start: location(node),
            end: CartographCore.SourceLocation(path: path, line: end.line, column: end.column)
        )
    }
}

/// 허용한 구문 형태만 벗기며 자식 참조 전체를 수집하지 않는다.
private enum EnumDecisionShape {
    /// 사용자 정의 속성은 멤버·동료 선언을 생성할 수 있으므로 보수적으로 남긴다.
    static let knownAttributes: Set<String> = [
        "available", "frozen", "objc", "objcMembers", "_spi", "unknown",
        "inlinable", "usableFromInline", "_transparent", "_alwaysEmitIntoClient",
        "discardableResult", "inline", "_disfavoredOverload",
    ]

    static func hasUnresolvedAttributes(_ node: some SyntaxProtocol) -> Bool {
        guard let attributed = node.asProtocol(WithAttributesSyntax.self) else { return false }
        return attributed.attributes.contains { element in
            guard case let .attribute(attribute) = element else { return true }
            return !knownAttributes.contains(attribute.attributeName.trimmedDescription)
        }
    }

    static func unwrapped(_ expression: ExprSyntax) -> ExprSyntax {
        var current = expression
        while let tuple = current.as(TupleExprSyntax.self), tuple.elements.count == 1,
              let element = tuple.elements.first, element.label == nil, element.trailingComma == nil {
            current = element.expression
        }
        return current
    }

    static func directMember(_ expression: ExprSyntax) -> TokenSyntax? {
        guard let member = unwrapped(expression).as(MemberAccessExprSyntax.self),
              member.declName.argumentNames == nil,
              member.base.map(isNamePath) ?? true else { return nil }
        return member.declName.baseName
    }

    private static func isNamePath(_ expression: ExprSyntax) -> Bool {
        let expression = unwrapped(expression)
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.argumentNames == nil
        }
        guard let member = expression.as(MemberAccessExprSyntax.self),
              member.declName.argumentNames == nil, let base = member.base else { return false }
        return isNamePath(base)
    }

    static func casePattern(_ pattern: PatternSyntax) -> (token: TokenSyntax, coversWholeCase: Bool)? {
        var pattern = pattern
        var bindsValues = false
        while let binding = pattern.as(ValueBindingPatternSyntax.self) {
            bindsValues = true
            pattern = binding.pattern
        }
        guard let expression = pattern.as(ExpressionPatternSyntax.self)?.expression else { return nil }
        if let name = directMember(expression) { return (name, true) }
        guard let call = unwrapped(expression).as(FunctionCallExprSyntax.self),
              call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty,
              let name = directMember(call.calledExpression) else { return nil }
        let whole = call.arguments.allSatisfy { irrefutable($0.expression, bindsValues: bindsValues) }
        return (name, whole)
    }

    private static func irrefutable(_ expression: ExprSyntax, bindsValues: Bool) -> Bool {
        if expression.is(DiscardAssignmentExprSyntax.self) { return true }
        if let pattern = expression.as(PatternExprSyntax.self)?.pattern {
            return irrefutable(pattern, bindsValues: bindsValues)
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self), bindsValues {
            if case .identifier = reference.baseName.tokenKind { return true }
        }
        if let tuple = expression.as(TupleExprSyntax.self) {
            return tuple.elements.allSatisfy { irrefutable($0.expression, bindsValues: bindsValues) }
        }
        return false
    }

    private static func irrefutable(_ pattern: PatternSyntax, bindsValues: Bool) -> Bool {
        if pattern.is(WildcardPatternSyntax.self) { return true }
        if pattern.is(IdentifierPatternSyntax.self) { return bindsValues }
        if let binding = pattern.as(ValueBindingPatternSyntax.self) {
            return irrefutable(binding.pattern, bindsValues: true)
        }
        if let tuple = pattern.as(TuplePatternSyntax.self) {
            return tuple.elements.allSatisfy { irrefutable($0.pattern, bindsValues: bindsValues) }
        }
        if let expression = pattern.as(ExpressionPatternSyntax.self)?.expression {
            return irrefutable(expression, bindsValues: bindsValues)
        }
        return false
    }

    static func enclosingFunction(_ node: some SyntaxProtocol) -> FunctionDeclSyntax? {
        var current = node.parent
        while let syntax = current {
            if let function = syntax.as(FunctionDeclSyntax.self) { return function }
            if syntax.is(ClosureExprSyntax.self) || syntax.is(AccessorBlockSyntax.self)
                || syntax.is(InitializerDeclSyntax.self) || syntax.is(DeinitializerDeclSyntax.self)
                || syntax.is(SubscriptDeclSyntax.self) || syntax.is(MemberBlockSyntax.self) {
                return nil
            }
            current = syntax.parent
        }
        return nil
    }

    static func simpleTypeName(_ type: TypeSyntax) -> TokenSyntax? {
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil {
            if case .identifier = identifier.name.tokenKind { return identifier.name }
            return nil
        }
        guard let member = type.as(MemberTypeSyntax.self), member.genericArgumentClause == nil,
              simpleTypeName(member.baseType) != nil else { return nil }
        return member.name
    }

    static func membershipContext(
        _ call: FunctionCallExprSyntax
    ) -> (root: Syntax, negation: TokenSyntax?, limitations: Set<String>) {
        var root = throughParentheses(Syntax(call))
        var negation: TokenSyntax?
        var limitations: Set<String> = []
        if let prefix = root.parent?.as(PrefixOperatorExprSyntax.self) {
            root = throughParentheses(Syntax(prefix))
            if prefix.operator.text == "!" {
                negation = prefix.operator
            } else {
                limitations.insert("enum-decision-unsupported-prefix-operator")
            }
            if root.parent?.is(PrefixOperatorExprSyntax.self) == true {
                limitations.insert("enum-decision-multiple-prefix-operators")
            }
        }
        return (root, negation, limitations)
    }

    private static func throughParentheses(_ syntax: Syntax) -> Syntax {
        var current = syntax
        while let element = current.parent?.as(LabeledExprSyntax.self),
              let list = element.parent?.as(LabeledExprListSyntax.self), list.count == 1,
              let tuple = list.parent?.as(TupleExprSyntax.self),
              element.label == nil, element.trailingComma == nil {
            current = Syntax(tuple)
        }
        return current
    }
}


/// 여러 분기의 같은 이름도 보수적으로 거절하며 데이터 흐름을 복원하지 않는다.
private final class EnumSubjectShadowFinder: SyntaxVisitor {
    private let name: String
    private let before: AbsolutePosition
    private(set) var found = false

    init(name: String, before: AbsolutePosition) {
        self.name = name
        self.before = before
        super.init(viewMode: .sourceAccurate)
    }

    private func matches(_ token: TokenSyntax) -> Bool {
        token.positionAfterSkippingLeadingTrivia < before
            && SyntaxIdentifiers.unescaped(token.text) == name
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        if matches(node.identifier) { found = true }
        return .visitChildren
    }

    override func visit(_ node: ValueBindingPatternSyntax) -> SyntaxVisitorContinueKind {
        if node.tokens(viewMode: .sourceAccurate).contains(where: matches) { found = true }
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        if matches(node.secondName ?? node.firstName) { found = true }
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        if matches(node.secondName ?? node.firstName) { found = true }
        return .visitChildren
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        if matches(node.name) { found = true }
        return .visitChildren
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        if name == "error", node.catchItems.isEmpty, node.positionAfterSkippingLeadingTrivia < before {
            found = true
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        // 함수 이름은 선언 전에도 보일 수 있으므로 위치로 거르지 않는다.
        if SyntaxIdentifiers.unescaped(node.name.text) == name { found = true }
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.positionAfterSkippingLeadingTrivia < before { found = true }
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        if node.positionAfterSkippingLeadingTrivia < before { found = true }
        return .visitChildren
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        if node.positionAfterSkippingLeadingTrivia < before,
           !EnumDecisionShape.knownAttributes.contains(node.attributeName.trimmedDescription) {
            found = true
        }
        return .visitChildren
    }
}
