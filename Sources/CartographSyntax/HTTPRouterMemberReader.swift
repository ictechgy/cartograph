import CartographCore
import SwiftSyntax

/// 라우터 타입(Moya `TargetType`, Alamofire `URLRequestConvertible`)의 멤버를 case 별 분기 표로 읽는다.
///
/// 읽는 모양은 좁다. 본문이 `switch self` 하나이거나 식 하나(또는 `return` 하나)일 때만 분기를 값으로
/// 읽고, 그 밖은 값을 모르는 행으로 남긴다. 모르는 행의 case 는 dynamic 사실이 된다 — 추측한 경로는
/// isthmus 의 조인을 오염시키지만 dynamic 은 소비자가 공백으로 센다.
extension HTTPRouteCallCollector {
    /// `var path`·`var method`·`var baseURL` 멤버를 표로 기록한다.
    func recordRouterMember(_ node: VariableDeclSyntax, name: String) {
        guard let member = HTTPTargetMemberTable.Member(rawValue: name), !chain.isEmpty,
              surface.ownsRouterMembers(chain.joined(separator: ".")),
              let binding = node.bindings.first, node.bindings.count == 1 else { return }
        let owner = chain.joined(separator: ".")
        if let block = binding.accessorBlock {
            let arms = routerArms(HTTPRouterBody.statements(of: block), member: member, fallback: node)
            routerTables.append(.init(owner: owner, member: member, arms: arms, isTestSource: isTestSource))
        } else if let value = binding.initializer?.value {
            routerTables.append(.init(owner: owner, member: member, arms: [arm(for: value, cases: nil, member: member)],
                                      isTestSource: isTestSource))
        } else {
            // 초기식 없는 저장 프로퍼티는 생성 지점이 값을 넣는 기술자 타입이다.
            routerTables.append(.init(owner: owner, member: member, arms: [.init(cases: nil, value: nil, location: location(of: node))],
                                      isStoredWithoutValue: true, isTestSource: isTestSource))
        }
    }

    /// 본문 문장들을 분기 행으로 읽는다.
    private func routerArms(_ statements: CodeBlockItemListSyntax?, member: HTTPTargetMemberTable.Member, fallback: some SyntaxProtocol) -> [HTTPTargetMemberTable.Arm] {
        guard let statements else { return [.init(cases: nil, value: nil, location: location(of: fallback))] }
        if let switchExpression = HTTPRouterBody.selfSwitch(statements) {
            return switchExpression.cases.map { caseArm($0, member: member) }
        }
        guard let expression = HTTPRouterBody.singleResult(statements) else {
            return [.init(cases: nil, value: nil, location: location(of: statements.first.map(Syntax.init) ?? Syntax(fallback)))]
        }
        return [arm(for: expression, cases: nil, member: member)]
    }

    /// `switch self` 의 분기 하나. `where` 가 붙었거나 읽지 못한 패턴이면 값을 모르는 행이다.
    private func caseArm(_ element: SwitchCaseListSyntax.Element, member: HTTPTargetMemberTable.Member) -> HTTPTargetMemberTable.Arm {
        guard case let .switchCase(switchCase) = element else {
            return .init(cases: nil, value: nil, location: location(of: element))
        }
        let names: Set<String>?
        var isConditional = false
        switch switchCase.label {
        case .default: names = nil
        case let .case(label):
            let items = label.caseItems.map { HTTPRouterBody.caseName(of: $0.pattern) }
            isConditional = label.caseItems.contains { $0.whereClause != nil }
            names = items.contains(nil) ? nil : Set(items.compactMap { $0 })
            if items.contains(nil) { isConditional = true }
        }
        guard let expression = HTTPRouterBody.singleResult(switchCase.statements) else {
            return .init(cases: names, value: nil, location: location(of: switchCase.statements.first.map(Syntax.init) ?? Syntax(switchCase)))
        }
        guard !isConditional else {
            // 조건부 분기의 값은 그 조건이 참일 때만의 사실이다. 원문만 남기고 값은 모른다고 한다.
            return .init(cases: names, value: nil, dynamicText: member == .path ? HTTPSyntax.sanitizedText(expression) : nil,
                         location: location(of: expression))
        }
        return arm(for: expression, cases: names, member: member)
    }

    /// 분기 식 하나를 값으로 읽는다.
    private func arm(for expression: ExprSyntax, cases: Set<String>?, member: HTTPTargetMemberTable.Member) -> HTTPTargetMemberTable.Arm {
        let context = HTTPSyntax.context(of: expression)
        let value: HTTPTargetValue?
        switch member {
        case .path: value = .path(routerPathParts(expression, context: context))
        case .method: value = libraryVerbExpression(expression) ? .verb(libraryVerb(expression, context: context)) : nil
        case .baseURL: value = urlParts(expression, context: context, depth: 0)
            .map { .url(HTTPTargetURL(parts: $0.parts.map(\.part), join: $0.join)) }
        }
        return .init(cases: cases, value: value, dynamicText: member == .path ? HTTPSyntax.sanitizedText(expression) : nil,
                     location: location(of: expression))
    }

    /// 경로 식의 조각. `rawValue`·`self.rawValue` 는 case 의 원시값 자리다.
    private func routerPathParts(_ expression: ExprSyntax, context: BindingCollector.Context) -> [HTTPTargetPathPart] {
        let value = HTTPSyntax.unwrapped(expression)
        if HTTPRouterBody.isSelfMember(value, named: "rawValue") { return [.selfRawValue] }
        return parts(of: value, context: context).map { .part($0.part) }
    }

    /// 동사 식으로 읽을 수 있는 모양인지(`.get`, `HTTPMethod.get`, `HTTPMethod(rawValue:)`).
    /// 모양조차 아니면 값을 모르는 행이고, 모양이지만 계약 동사가 아니면(`.connect`) `methodDynamic` 이다.
    private func libraryVerbExpression(_ expression: ExprSyntax) -> Bool {
        let value = HTTPSyntax.unwrapped(expression)
        if value.is(MemberAccessExprSyntax.self) { return true }
        return value.as(FunctionCallExprSyntax.self)?.arguments.first?.label?.text == "rawValue"
    }

    // MARK: - Alamofire asURLRequest

    /// `func asURLRequest()` 의 요청 조립 방식을 레시피로 기록한다. 읽지 못하면 기록하지 않는다
    /// (문서 단위에서 레시피 없는 라우터로 센다).
    func recordRouterRequestBuilder(_ node: FunctionDeclSyntax, name: String) {
        guard name == "asURLRequest", node.signature.parameterClause.parameters.isEmpty, !chain.isEmpty,
              surface.ownsRouterMembers(chain.joined(separator: ".")), let body = node.body else { return }
        let finder = HTTPRequestConstructionFinder()
        finder.walk(body)
        guard finder.constructions.count == 1, let construction = finder.constructions.first,
              let url = construction.arguments.first(where: { $0.label?.text == "url" })?.expression,
              let recipe = routerRecipe(url: url, construction: construction, body: body) else { return }
        routerRecipes.append(recipe)
    }

    /// `URLRequest(url: X)` 의 `X` 가 `path` 멤버를 base 에 붙이는 방식.
    private func routerRecipe(url: ExprSyntax, construction: FunctionCallExprSyntax, body: CodeBlockSyntax) -> HTTPRouterRecipe? {
        let context = HTTPSyntax.context(of: url)
        var value = HTTPSyntax.unwrapped(url)
        if let reference = value.as(DeclReferenceExprSyntax.self),
           let bound = locals.urlExpression(named: SyntaxIdentifiers.unescaped(reference.baseName.text), scopes: context.scopes) {
            value = HTTPSyntax.unwrapped(bound)
        }
        guard let call = value.as(FunctionCallExprSyntax.self),
              let (join, baseExpression) = recipeJoin(call) else { return nil }
        let base: HTTPTargetURL?
        switch join {
        case .concatenation:
            base = baseExpression.map { HTTPTargetURL(parts: parts(of: $0, context: context).map(\.part), join: .absoluteURL) }
        default:
            base = baseExpression.flatMap { urlParts($0, context: context, depth: 0) }
                .map { HTTPTargetURL(parts: $0.parts.map(\.part), join: $0.join) }
        }
        return HTTPRouterRecipe(owner: chain.joined(separator: "."), join: join, base: base,
                                method: recipeMethod(construction, body: body))
    }

    /// 결합 방식과 base 식. `path` 멤버를 그대로 붙일 때만 레시피다.
    private func recipeJoin(_ call: FunctionCallExprSyntax) -> (HTTPRouterRecipe.Join, ExprSyntax?)? {
        if let appended = HTTPSyntax.appendedComponent(of: call) {
            guard HTTPRouterBody.isSelfMember(HTTPSyntax.unwrapped(appended.component), named: "path") else { return nil }
            return (call.arguments.first?.label?.text == "component" ? .appendingComponent : .appendingPathComponent, appended.base)
        }
        guard HTTPSyntax.isFoundationInitializer(call, type: "URL"), let string = call.arguments.first,
              string.label?.text == "string" else { return nil }
        if let relative = call.arguments.dropFirst().first, relative.label?.text == "relativeTo" {
            guard HTTPRouterBody.isSelfMember(HTTPSyntax.unwrapped(string.expression), named: "path") else { return nil }
            return (.relativeTo, relative.expression)
        }
        // `URL(string: base + path)` — 연결의 마지막 피연산자가 `path` 멤버여야 한다.
        guard let infix = HTTPSyntax.unwrapped(string.expression).as(InfixOperatorExprSyntax.self),
              infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "+",
              HTTPRouterBody.isSelfMember(HTTPSyntax.unwrapped(infix.rightOperand), named: "path") else { return nil }
        return (.concatenation, infix.leftOperand)
    }

    /// 요청 동사의 출처. 생성 인자 `method:` 나 같은 본문의 `method`·`httpMethod` 대입이다.
    private func recipeMethod(_ construction: FunctionCallExprSyntax, body: CodeBlockSyntax) -> HTTPRouterRecipe.MethodSource {
        let context = HTTPSyntax.context(of: construction)
        var sources: [HTTPRouterRecipe.MethodSource] = []
        if let argument = construction.arguments.first(where: { $0.label?.text == "method" })?.expression {
            sources.append(methodSource(argument, isLibrary: true, context: context))
        }
        if let name = construction.parent?.as(InitializerClauseSyntax.self)?.parent?.as(PatternBindingSyntax.self)?
            .pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
            let assignments = HTTPMethodAssignmentCollector(name: SyntaxIdentifiers.unescaped(name))
            assignments.walk(body)
            sources += assignments.values.map { methodSource($0.value, isLibrary: $0.isLibraryMethod, context: context) }
        }
        guard let last = sources.last else { return .fixed("GET") }
        // 대입은 차례로 덮어쓴다. 서로 다른 출처가 섞이면 어느 것이 마지막에 남는지 구문으로 증명하지 않는다.
        return sources.allSatisfy { $0 == last } ? last : .fixed(nil)
    }

    private func methodSource(_ expression: ExprSyntax, isLibrary: Bool, context: BindingCollector.Context) -> HTTPRouterRecipe.MethodSource {
        let value = HTTPSyntax.unwrapped(expression)
        if HTTPRouterBody.isSelfMember(value, named: "method") { return .member }
        if let member = value.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "rawValue",
           let base = member.base, HTTPRouterBody.isSelfMember(HTTPSyntax.unwrapped(base), named: "method") {
            return .member
        }
        return .fixed(isLibrary ? libraryVerb(value, context: context) : stringVerb(value, context: context))
    }

    /// 호출이 라우터 `asURLRequest()` 본문 안에 있는지. 그 요청은 case 별 사실로 이미 다룬다.
    func isInsideRouterRequestBuilder(_ node: some SyntaxProtocol) -> Bool {
        var current = node.parent
        while let syntax = current, HTTPSyntax.typeName(of: syntax) == nil {
            if let function = syntax.as(FunctionDeclSyntax.self), function.name.text == "asURLRequest" {
                return !chain.isEmpty && surface.ownsRouterMembers(chain.joined(separator: "."))
            }
            current = syntax.parent
        }
        return false
    }

    private func location(of node: some SyntaxProtocol) -> CartographCore.SourceLocation {
        let resolved = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return CartographCore.SourceLocation(path: path, line: resolved.line, column: resolved.column)
    }
}

/// 라우터 멤버 본문의 모양 판정. 상태가 없다.
enum HTTPRouterBody {
    /// 계산 프로퍼티의 읽기 본문.
    static func statements(of block: AccessorBlockSyntax) -> CodeBlockItemListSyntax? {
        switch block.accessors {
        case let .getter(items): return items
        case let .accessors(list):
            return list.first { $0.accessorSpecifier.tokenKind == .keyword(.get) }?.body?.statements
        }
    }

    /// 본문이 `switch self { … }` 하나(또는 `return switch self`)이면 그 식.
    static func selfSwitch(_ statements: CodeBlockItemListSyntax) -> SwitchExprSyntax? {
        guard statements.count == 1, let item = statements.first?.item else { return nil }
        let expression = item.as(ExprSyntax.self) ?? item.as(ReturnStmtSyntax.self)?.expression
            ?? item.as(ExpressionStmtSyntax.self)?.expression
        guard let switchExpression = expression?.as(SwitchExprSyntax.self),
              switchExpression.subject.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" else { return nil }
        return switchExpression
    }

    /// 결과 식 하나. 식 문장 하나, `return` 하나, 또는 최상위 `return` 이 정확히 하나인 본문이다.
    static func singleResult(_ statements: CodeBlockItemListSyntax) -> ExprSyntax? {
        if statements.count == 1, let item = statements.first?.item {
            if let expression = item.as(ExprSyntax.self) { return expression }
            if let expression = item.as(ExpressionStmtSyntax.self)?.expression { return expression }
        }
        let returns = statements.compactMap { $0.item.as(ReturnStmtSyntax.self) }
        guard returns.count == 1, !containsNestedReturn(statements) else { return nil }
        return returns.first?.expression
    }

    /// 최상위가 아닌 곳(`if`·`guard` 안)에 `return` 이 있는지. 있으면 결과가 하나라고 할 수 없다.
    private static func containsNestedReturn(_ statements: CodeBlockItemListSyntax) -> Bool {
        let finder = HTTPNestedReturnFinder()
        for statement in statements where !statement.item.is(ReturnStmtSyntax.self) {
            finder.walk(statement)
        }
        return finder.found
    }

    /// `case .a`, `case .b(let x)`, `case let .c(x)`, `case API.d` 의 case 이름. 다른 패턴이면 nil.
    static func caseName(of pattern: PatternSyntax) -> String? {
        var current = pattern
        if let binding = current.as(ValueBindingPatternSyntax.self) { current = binding.pattern }
        guard var expression = current.as(ExpressionPatternSyntax.self)?.expression else { return nil }
        if let call = expression.as(FunctionCallExprSyntax.self) { expression = call.calledExpression }
        guard let member = expression.as(MemberAccessExprSyntax.self) else { return nil }
        return SyntaxIdentifiers.unescaped(member.declName.baseName.text)
    }

    /// `name` 또는 `self.name` 인지.
    static func isSelfMember(_ expression: ExprSyntax, named name: String) -> Bool {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return SyntaxIdentifiers.unescaped(reference.baseName.text) == name
        }
        guard let member = expression.as(MemberAccessExprSyntax.self),
              member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" else { return false }
        return SyntaxIdentifiers.unescaped(member.declName.baseName.text) == name
    }
}

/// 중첩된 `return` 을 찾는다. 클로저·지역 함수 안의 `return` 은 그 본문의 것이라 세지 않는다.
private final class HTTPNestedReturnFinder: SyntaxVisitor {
    private(set) var found = false

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        found = true
        return .skipChildren
    }

    override func visit(_: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

/// 본문의 `URLRequest(url:…)` 생성식을 모은다.
private final class HTTPRequestConstructionFinder: SyntaxVisitor {
    private(set) var constructions: [FunctionCallExprSyntax] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if HTTPSyntax.isFoundationInitializer(node, type: "URLRequest"), node.arguments.contains(where: { $0.label?.text == "url" }) {
            constructions.append(node)
        }
        return .visitChildren
    }
}
