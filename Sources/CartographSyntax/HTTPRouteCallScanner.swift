import CartographCore
import SwiftOperators
import SwiftParser
import SwiftSyntax

/// 스캐너가 찾은 route-call 과 그것을 감싸는 선언. USR 결합은 인덱스를 아는 위층이 한다.
public struct ScannedRouteCall: Hashable, Sendable {
    public let fact: RouteCallFact
    /// 호출을 감싸는 가장 안쪽 선언. 파일 최상위면 nil.
    public let declaration: EnclosingDeclaration?

    public init(fact: RouteCallFact, declaration: EnclosingDeclaration?) {
        self.fact = fact
        self.declaration = declaration
    }
}

/// 사실로 만들지 못해 세기만 한 것. 문서의 호출 측 한계가 된다.
public struct RouteCallScanCounts: Hashable, Sendable {
    /// 함수 매개변수를 경로로 그대로 흘려보내는 싱크(선언되지 않은 래퍼로 보이는 것).
    public var undeclaredWrapperSinks = 0
    /// 요청 URL 식을 읽지 못한 직접 싱크.
    public var unreadableSinks = 0
    /// 선언된 래퍼 함수와 이름·레이블이 맞지만 수신자 타입을 증명하지 못한 호출.
    public var unprovenReceiverCalls = 0

    public init() {}

    /// 파일별 계수를 문서 단위로 합친다.
    public static func + (lhs: Self, rhs: Self) -> Self {
        var result = lhs
        result.undeclaredWrapperSinks += rhs.undeclaredWrapperSinks
        result.unreadableSinks += rhs.unreadableSinks
        result.unprovenReceiverCalls += rhs.unprovenReceiverCalls
        return result
    }
}

/// 파일 하나를 훑은 결과.
public struct RouteCallScanResult: Hashable, Sendable {
    public let calls: [ScannedRouteCall]
    public let counts: RouteCallScanCounts
    /// 선언별 발견 호출 수. 키는 스캐너에 넘긴 래퍼 목록의 위치다. 0건 래퍼를 한계로 알리는 데 쓴다.
    public let callsByWrapper: [Int: Int]
}

/// 프로젝트가 선언한 타입과 함수의 구문 표면. 래퍼 선언이 실제 심볼과 맞는지 확인하고,
/// 호출의 인자 레이블이 선언된 시그니처와 맞는지 볼 때 쓴다.
public struct HTTPDeclarationSurface: Hashable, Sendable {
    /// 선언하거나 확장한 타입 사슬(`A.B`).
    public private(set) var typeChains: Set<String> = []
    /// `타입 사슬\0함수 이름` → 오버로드별 외부 레이블(레이블 없음은 nil). 최상위 함수는 빈 사슬이다.
    public private(set) var functions: [String: [[String?]]] = [:]
    /// 타입 사슬 → 명시적 이니셜라이저의 외부 레이블들.
    public private(set) var initializers: [String: [[String?]]] = [:]

    public init() {}

    /// 여러 파일의 표면을 합친다. 순서와 무관하게 같은 값이 되도록 집합과 목록만 더한다.
    public mutating func merge(_ other: HTTPDeclarationSurface) {
        typeChains.formUnion(other.typeChains)
        functions.merge(other.functions) { $0 + $1 }
        initializers.merge(other.initializers) { $0 + $1 }
    }

    mutating func addType(_ chain: [String]) { typeChains.insert(chain.joined(separator: ".")) }

    mutating func addFunction(chain: [String], name: String, labels: [String?]) {
        functions[chain.joined(separator: ".") + "\0" + name, default: []].append(labels)
    }

    mutating func addInitializer(chain: [String], labels: [String?]) {
        initializers[chain.joined(separator: "."), default: []].append(labels)
    }

    /// 소유 타입과 맞는 선언된 타입 사슬들.
    func chains(matching declaration: HTTPWrapperDeclaration) -> [String] {
        typeChains.filter { declaration.ownerMatches($0.split(separator: ".").map(String.init)) }.sorted()
    }

    /// 선언이 가리키는 심볼이 이 표면에 있는지. 없으면 `http-wrapper-unresolved:` 근거다.
    public func declares(_ declaration: HTTPWrapperDeclaration) -> Bool {
        let owners = chains(matching: declaration)
        switch declaration.kind {
        case .constructor:
            return declaration.name == "init" && !owners.isEmpty
        case .function:
            let candidates = owners.isEmpty ? [""] : owners
            return candidates.contains { functions[$0 + "\0" + declaration.name] != nil }
        }
    }

    /// 선언이 가리키는 호출 가능한 시그니처들. 모르면 빈 목록이며, 그때는 레이블을 검사하지 않는다.
    func signatures(of declaration: HTTPWrapperDeclaration) -> [[String?]] {
        let owners = chains(matching: declaration)
        switch declaration.kind {
        case .constructor: return owners.flatMap { initializers[$0] ?? [] }
        case .function: return (owners.isEmpty ? [""] : owners).flatMap { functions[$0 + "\0" + declaration.name] ?? [] }
        }
    }
}

/// Swift 소스에서 클라이언트 HTTP 호출(`route-call`)을 찾는다.
///
/// 두 가지를 읽는다. (a) 사용자가 선언한 래퍼(`http-wrappers` v1)의 호출, (b) 동사와 경로를
/// 정적으로 증명할 수 있는 `URLRequest`·`URLSession` 직접 요청. 경로 문자열은 브리지 스캐너와 같은
/// 바인딩 수집기(`BindingCollector`)로 같은 파일 상수를 풀고, 조각(리터럴·보간)으로 펼친 뒤
/// 공통 해석 규칙(`HTTPRouteURLResolver`)에 맡긴다. 규칙 자체는 구문을 모르는 `CartographCore` 에 있다.
public struct HTTPRouteCallScanner: Sendable {
    /// 이 도구가 읽는 Swift 래퍼 선언. 다른 언어의 선언은 위층이 걸러 넘긴다.
    public let wrappers: [HTTPWrapperDeclaration]
    /// 프로젝트 전체의 선언 표면. 래퍼 소유 타입과 시그니처를 확인한다.
    public let surface: HTTPDeclarationSurface

    public init(wrappers: [HTTPWrapperDeclaration], surface: HTTPDeclarationSurface = HTTPDeclarationSurface()) {
        self.wrappers = wrappers
        self.surface = surface
    }

    /// 파일 하나의 선언 표면. 모든 파일을 먼저 훑어 합친 뒤 `scan` 에 넘긴다.
    public static func declarations(source: String) -> HTTPDeclarationSurface {
        let collector = HTTPSurfaceCollector()
        collector.walk(Parser.parse(source: source))
        return collector.surface
    }

    /// 파일 하나에서 route-call 을 찾는다.
    ///
    /// - Parameter resolvedValues: 값 흐름 분석이 증명한 식 위치 → 문자열. 파일 밖 상수를 푼다.
    public func scan(
        source: String, path: String, isTestSource: Bool = false,
        resolvedValues: [CartographCore.SourceLocation: String] = [:]
    ) -> RouteCallScanResult {
        let parsed = Parser.parse(source: source)
        // `a = b` 와 `a + b` 를 읽으려면 연산자를 접어야 한다. 접지 못한 식은 그 식만 못 읽는다.
        let tree = OperatorTable.standardOperators.foldAll(parsed) { _ in }.as(SourceFileSyntax.self) ?? parsed
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let bindings = BindingCollector(converter: converter, resolvedValues: resolvedValues)
        bindings.walk(tree)
        let locals = HTTPLocalCollector()
        locals.walk(tree)
        // 이 파일의 선언은 위층이 모은 표면에 이미 있을 수 있다. 합쳐도 시그니처 목록이 겹칠 뿐이라
        // 판정은 같고, 단독 파일을 넘긴 호출자(테스트·임베더)도 같은 답을 받는다.
        let local = HTTPSurfaceCollector()
        local.walk(tree)
        var surface = self.surface
        surface.merge(local.surface)
        let collector = HTTPRouteCallCollector(
            wrappers: wrappers, converter: converter, bindings: bindings, locals: locals,
            surface: surface, path: path, isTestSource: isTestSource
        )
        collector.walk(tree)
        return RouteCallScanResult(calls: collector.calls, counts: collector.counts, callsByWrapper: collector.callsByWrapper)
    }
}

// MARK: - 선언 표면

/// 타입·함수·이니셜라이저 선언과 외부 레이블을 모은다. 본문 안의 지역 선언은 심볼이 아니라 뺀다.
private final class HTTPSurfaceCollector: SyntaxVisitor {
    private(set) var surface = HTTPDeclarationSurface()
    private var typeNames: [String] = []

    init() { super.init(viewMode: .sourceAccurate) }

    private var chain: [String] { typeNames.flatMap { $0.split(separator: ".").map(String.init) } }

    private func push(_ name: String) -> SyntaxVisitorContinueKind {
        typeNames.append(SyntaxIdentifiers.unescaped(name))
        surface.addType(chain)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text) }
    override func visitPost(_: ClassDeclSyntax) { typeNames.removeLast() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text) }
    override func visitPost(_: StructDeclSyntax) { typeNames.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text) }
    override func visitPost(_: EnumDeclSyntax) { typeNames.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text) }
    override func visitPost(_: ActorDeclSyntax) { typeNames.removeLast() }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text) }
    override func visitPost(_: ProtocolDeclSyntax) { typeNames.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.extendedType.trimmedDescription)
    }
    override func visitPost(_: ExtensionDeclSyntax) { typeNames.removeLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if !DeclarationCollector.isInsideBody(node) {
            surface.addFunction(chain: chain, name: SyntaxIdentifiers.unescaped(node.name.text),
                                labels: HTTPSyntax.labels(node.signature.parameterClause.parameters))
        }
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if !typeNames.isEmpty {
            surface.addInitializer(chain: chain, labels: HTTPSyntax.labels(node.signature.parameterClause.parameters))
        }
        return .skipChildren
    }
}

// MARK: - 지역 URL 바인딩과 타입 표기

/// 함수 안의 `let url = URL(…)`·`guard let url = URL(…)` 과, 이름에 붙은 타입 표기를 모은다.
///
/// 브리지의 바인딩 수집기는 대문자 호출을 인스턴스로만 기록하고 `guard let` 은 그림자로
/// 처리한다. 요청 URL 은 바로 그 두 모양으로 흔히 만들어지므로 따로 모은다.
final class HTTPLocalCollector: SyntaxVisitor {
    /// `스코프 키#이름` → 초기식. 같은 키에 두 번 묶이면 nil 로 지워 모른다고 한다.
    private(set) var urlBindings: [String: ExprSyntax?] = [:]
    /// 이름 → 타입 표기의 마지막 구성 요소들. 파일 안에서 둘 이상이면 증명하지 못한다.
    private(set) var annotatedTypes: [String: Set<String>] = [:]

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return .visitChildren }
        if let type = node.typeAnnotation?.type { noteType(name, type) }
        if let value = node.initializer?.value, DeclarationCollector.isInsideBody(node) { bindURL(name, value, at: node) }
        return .visitChildren
    }

    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let value = node.initializer?.value else { return .visitChildren }
        bindURL(name, value, at: node)
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        noteType((node.secondName ?? node.firstName).text, node.type)
        return .visitChildren
    }

    private func noteType(_ name: String, _ type: TypeSyntax) {
        guard let base = HTTPSyntax.typeBaseName(type) else { return }
        annotatedTypes[SyntaxIdentifiers.unescaped(name), default: []].insert(base)
    }

    private func bindURL(_ name: String, _ value: ExprSyntax, at node: some SyntaxProtocol) {
        guard HTTPSyntax.isURLConstruction(value) else { return }
        let key = HTTPSyntax.localKey(SyntaxIdentifiers.unescaped(name), scope: HTTPSyntax.innermostScope(of: node))
        urlBindings[key] = urlBindings[key] == nil ? .some(value) : .some(nil)
    }

    /// 사용 지점 문맥에서 이름이 가리키는 URL 초기식. 안쪽 스코프부터 찾는다.
    func urlExpression(named name: String, scopes: [Int]) -> ExprSyntax? {
        for scope in scopes.reversed() {
            if let found = urlBindings[HTTPSyntax.localKey(name, scope: scope)] { return found }
        }
        return nil
    }
}

// MARK: - 구문 보조

/// 수집기들이 함께 쓰는 구문 판정. 상태가 없다.
enum HTTPSyntax {
    /// 요청 URL 을 만드는 식인지(`URL(string:)`, `…appendingPathComponent(…)`, 그 강제 해제).
    static func isURLConstruction(_ expression: ExprSyntax) -> Bool {
        let value = unwrapped(expression)
        guard let call = value.as(FunctionCallExprSyntax.self) else { return false }
        if call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "URL" {
            return call.arguments.first?.label?.text == "string"
        }
        return appendedComponent(of: call) != nil
    }

    /// `base.appendingPathComponent(x)`·`base.appending(path:)`·`base.appending(component:)` 의 (base, x).
    static func appendedComponent(of call: FunctionCallExprSyntax) -> (base: ExprSyntax, component: ExprSyntax)? {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base,
              let argument = call.arguments.first else { return nil }
        let name = member.declName.baseName.text
        let label = argument.label?.text
        let isAppend = (name == "appendingPathComponent" && label == nil)
            || (name == "appending" && (label == "path" || label == "component"))
        return isAppend ? (base, argument.expression) : nil
    }

    /// 괄호·강제 해제·옵셔널 체이닝을 벗긴다.
    static func unwrapped(_ expression: ExprSyntax) -> ExprSyntax {
        var value = BindingCollector.unparenthesized(expression)
        while true {
            if let forced = value.as(ForceUnwrapExprSyntax.self) {
                value = BindingCollector.unparenthesized(forced.expression)
            } else if let optional = value.as(OptionalChainingExprSyntax.self) {
                value = BindingCollector.unparenthesized(optional.expression)
            } else {
                return value
            }
        }
    }

    /// 외부 레이블 목록. `_` 는 nil 이다.
    static func labels(_ parameters: FunctionParameterListSyntax) -> [String?] {
        parameters.map { $0.firstName.text == "_" ? nil : SyntaxIdentifiers.unescaped($0.firstName.text) }
    }

    /// 타입 표기의 마지막 구성 요소. 옵셔널·`some`·`any`·속성은 벗긴다.
    static func typeBaseName(_ type: TypeSyntax) -> String? {
        if let identifier = type.as(IdentifierTypeSyntax.self) { return SyntaxIdentifiers.unescaped(identifier.name.text) }
        if let member = type.as(MemberTypeSyntax.self) { return SyntaxIdentifiers.unescaped(member.name.text) }
        if let optional = type.as(OptionalTypeSyntax.self) { return typeBaseName(optional.wrappedType) }
        if let forced = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return typeBaseName(forced.wrappedType) }
        if let some = type.as(SomeOrAnyTypeSyntax.self) { return typeBaseName(some.constraint) }
        if let attributed = type.as(AttributedTypeSyntax.self) { return typeBaseName(attributed.baseType) }
        return nil
    }

    /// 점으로 이은 타입 식의 구성 요소(`A.B` → `["A", "B"]`). 타입 식이 아니면 nil.
    static func dottedName(_ expression: ExprSyntax) -> [String]? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return [SyntaxIdentifiers.unescaped(reference.baseName.text)]
        }
        if let specialized = expression.as(GenericSpecializationExprSyntax.self) { return dottedName(specialized.expression) }
        guard let member = expression.as(MemberAccessExprSyntax.self), let base = member.base,
              let prefix = dottedName(base) else { return nil }
        return prefix + [SyntaxIdentifiers.unescaped(member.declName.baseName.text)]
    }

    static func localKey(_ name: String, scope: Int?) -> String { "\(scope ?? -1)#\(name)" }

    /// 바인딩 수집기와 같은 규칙의 스코프 노드인지. 두 수집기가 같은 키를 써야 문맥이 맞는다.
    static func isScope(_ node: Syntax) -> Bool {
        node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self) || node.is(ClosureExprSyntax.self)
            || node.is(AccessorBlockSyntax.self) || node.is(AccessorDeclSyntax.self)
    }

    /// 노드를 감싸는 가장 안쪽 스코프의 키.
    static func innermostScope(of node: some SyntaxProtocol) -> Int? {
        var current = node.parent
        while let syntax = current {
            if isScope(syntax) { return BindingCollector.scopeKey(syntax) }
            current = syntax.parent
        }
        return nil
    }

    /// 노드의 바인딩 문맥. 바인딩 수집기가 걸으며 쌓는 스코프·타입 스택을 부모 사슬로 복원한다.
    static func context(of node: some SyntaxProtocol) -> BindingCollector.Context {
        var scopes: [Int] = []
        var types: [String] = []
        var current = node.parent
        while let syntax = current {
            if isScope(syntax) { scopes.append(BindingCollector.scopeKey(syntax)) }
            if let name = typeName(of: syntax) { types.append(name) }
            current = syntax.parent
        }
        return BindingCollector.Context(scopes: scopes.reversed(), enclosingTypes: types.reversed())
    }

    /// 바인딩 수집기가 타입 문맥으로 쌓는 선언의 이름. 프로토콜은 쌓지 않는다.
    static func typeName(of syntax: Syntax) -> String? {
        let raw: String? = if let node = syntax.as(ClassDeclSyntax.self) { node.name.text }
            else if let node = syntax.as(StructDeclSyntax.self) { node.name.text }
            else if let node = syntax.as(EnumDeclSyntax.self) { node.name.text }
            else if let node = syntax.as(ActorDeclSyntax.self) { node.name.text }
            else if let node = syntax.as(ExtensionDeclSyntax.self) { node.extendedType.trimmedDescription }
            else { nil }
        return raw.map(SyntaxIdentifiers.unescaped)
    }

    /// 노드를 감싸는 함수·이니셜라이저·클로저의 매개변수 이름 → 타입 표기.
    static func enclosingParameters(of node: some SyntaxProtocol) -> [String: TypeSyntax?] {
        var result: [String: TypeSyntax?] = [:]
        var current = node.parent
        while let syntax = current, typeName(of: syntax) == nil {
            var parameters: [(String, TypeSyntax?)] = []
            if let function = syntax.as(FunctionDeclSyntax.self) {
                parameters = function.signature.parameterClause.parameters.map { (($0.secondName ?? $0.firstName).text, $0.type) }
            } else if let initializer = syntax.as(InitializerDeclSyntax.self) {
                parameters = initializer.signature.parameterClause.parameters.map { (($0.secondName ?? $0.firstName).text, $0.type) }
            } else if let closure = syntax.as(ClosureExprSyntax.self) {
                parameters = closureParameterNames(closure).map { ($0, nil) }
            }
            for (name, type) in parameters where result[SyntaxIdentifiers.unescaped(name)] == nil {
                result[SyntaxIdentifiers.unescaped(name)] = .some(type)
            }
            current = syntax.parent
        }
        return result
    }

    private static func closureParameterNames(_ closure: ClosureExprSyntax) -> [String] {
        switch closure.signature?.parameterClause {
        case let .simpleInput(shorthand)?: shorthand.map(\.name.text)
        case let .parameterClause(clause)?: clause.parameters.map { ($0.secondName ?? $0.firstName).text }
        case nil: []
        }
    }

    /// 식의 뿌리 식별자. 멤버 접근·호출·해제를 벗기고, 문자열이면 첫 보간, 연결이면 왼쪽을 본다.
    static func rootIdentifier(_ expression: ExprSyntax) -> String? {
        let value = unwrapped(expression)
        if let reference = value.as(DeclReferenceExprSyntax.self) { return SyntaxIdentifiers.unescaped(reference.baseName.text) }
        if let member = value.as(MemberAccessExprSyntax.self) { return member.base.flatMap(rootIdentifier) }
        if let call = value.as(FunctionCallExprSyntax.self) { return rootIdentifier(call.calledExpression) }
        if let infix = value.as(InfixOperatorExprSyntax.self) { return rootIdentifier(infix.leftOperand) }
        if let literal = value.as(StringLiteralExprSyntax.self),
           let segment = literal.segments.first?.as(ExpressionSegmentSyntax.self),
           let inner = segment.expressions.first?.expression {
            return rootIdentifier(inner)
        }
        return nil
    }

    /// dynamic 원문. 공백을 한 칸으로 접고 문자열 리터럴 조각을 가린 뒤 길이 상한으로 자른다.
    static func sanitizedText(_ expression: some SyntaxProtocol) -> String? {
        var text = ""
        for token in expression.tokens(viewMode: .sourceAccurate) {
            if !text.isEmpty, !token.leadingTrivia.isEmpty { text += " " }
            if case let .stringSegment(raw) = token.tokenKind {
                text += HTTPRouteTemplate.sanitizeLiteral(raw)
            } else {
                text += token.text
            }
            if !token.trailingTrivia.isEmpty { text += " " }
        }
        // 소비자는 제어 문자가 든 원문을 입력 오류로 거부한다. 공백류는 한 칸으로 접는다.
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            .filter { character in !character.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) } }
        var bounded = ""
        for character in collapsed {
            guard bounded.utf16.count + character.utf16.count <= HTTPRouteTemplate.maxLength else { break }
            bounded.append(character)
        }
        return bounded.isEmpty ? nil : bounded
    }
}
