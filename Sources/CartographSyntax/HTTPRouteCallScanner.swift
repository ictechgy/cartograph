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
    /// 요청 조립을 읽지 못한 Alamofire 라우터(`URLRequestConvertible`)와 경로 멤버가 없는 Moya 타겟 수.
    public var unmodelledRouters = 0
    /// 요청 URL 을 바꾸는 Moya `endpointClosure` 매핑과 Alamofire 요청 어댑터 수.
    public var urlRewriters = 0
    /// 요청을 읽지 않는 HTTP 클라이언트 모듈 → 그 모듈의 import 문 수(파일마다 하나).
    public var unmodelledClientImports: [String: Int] = [:]
    /// OpenAPI 생성 클라이언트 런타임을 import 한 소스 수.
    public var generatedClientImports = 0

    public init() {}

    /// 파일별 계수를 문서 단위로 합친다.
    public static func + (lhs: Self, rhs: Self) -> Self {
        var result = lhs
        result.undeclaredWrapperSinks += rhs.undeclaredWrapperSinks
        result.unreadableSinks += rhs.unreadableSinks
        result.unprovenReceiverCalls += rhs.unprovenReceiverCalls
        result.unmodelledRouters += rhs.unmodelledRouters
        result.urlRewriters += rhs.urlRewriters
        result.unmodelledClientImports.merge(rhs.unmodelledClientImports, uniquingKeysWith: +)
        result.generatedClientImports += rhs.generatedClientImports
        return result
    }
}

/// 파일 하나를 훑은 결과.
public struct RouteCallScanResult: Hashable, Sendable {
    public let calls: [ScannedRouteCall]
    public let counts: RouteCallScanCounts
    /// 선언별 발견 호출 수. 키는 스캐너에 넘긴 래퍼 목록의 위치다. 0건 래퍼를 한계로 알리는 데 쓴다.
    public let callsByWrapper: [Int: Int]
    /// 라우터 타입 멤버의 분기 표. 멤버가 여러 파일에 흩어질 수 있어 문서 단위로 합쳐
    /// `HTTPRouteCallScanner.routerRouteCalls` 에 넘긴다.
    public let routerTables: [HTTPTargetMemberTable]
    /// Alamofire 라우터의 요청 조립 방식.
    public let routerRecipes: [HTTPRouterRecipe]
}

/// 프로젝트가 선언한 타입과 함수의 구문 표면. 래퍼 선언이 실제 심볼과 맞는지 확인하고,
/// 호출의 인자 레이블이 선언된 시그니처와 맞는지 볼 때 쓴다.
public struct HTTPDeclarationSurface: Hashable, Sendable {
    /// 선언하거나 확장한 타입 사슬(`A.B`).
    public private(set) var typeChains: Set<String> = []
    /// 타입 사슬의 마지막 구성 요소들. "프로젝트가 이 이름의 타입을 선언했는가"를 사슬 전체를 훑지 않고 답한다.
    private(set) var typeLastNames: Set<String> = []
    /// `타입 사슬\0함수 이름` → 오버로드별 외부 레이블(레이블 없음은 nil). 최상위 함수는 빈 사슬이다.
    public private(set) var functions: [String: [[String?]]] = [:]
    /// 타입 사슬 → 명시적 이니셜라이저의 외부 레이블들.
    public private(set) var initializers: [String: [[String?]]] = [:]
    /// 타입 사슬 → 상속 절에 적힌 이름의 마지막 구성 요소(주 선언과 익스텐션을 합친 것).
    public private(set) var inheritedNames: [String: Set<String>] = [:]
    /// 프로토콜로 선언된 타입 사슬.
    public private(set) var protocolChains: Set<String> = []
    /// enum 사슬 → case 선언들(선언 순서).
    public private(set) var enumCases: [String: [HTTPEnumCaseDeclaration]] = [:]
    /// 타입 사슬 → 주 선언 위치. 여러 곳이면 위치가 가장 앞선 것.
    public private(set) var typeSites: [String: HTTPTypeDeclarationSite] = [:]
    /// `타입 사슬.프로퍼티` → 타입 표기의 마지막 구성 요소들. 다른 파일의 익스텐션에서 `session.request` 의
    /// 수신자 타입을 증명하는 데 쓴다.
    public private(set) var memberTypes: [String: Set<String>] = [:]

    public init() {}

    /// 여러 파일의 표면을 합친다. 순서와 무관하게 같은 값이 되도록 집합과 목록만 더한다.
    public mutating func merge(_ other: HTTPDeclarationSurface) {
        typeChains.formUnion(other.typeChains)
        typeLastNames.formUnion(other.typeLastNames)
        functions.merge(other.functions) { $0 + $1 }
        initializers.merge(other.initializers) { $0 + $1 }
        inheritedNames.merge(other.inheritedNames) { $0.union($1) }
        protocolChains.formUnion(other.protocolChains)
        // 같은 파일을 두 번 합치면(스캔이 이 파일의 표면을 다시 더한다) case 가 겹친다. 위치로 중복을 없앤다.
        // 경로 없이 만든 표면(임베더 기본값)은 위치만으로 파일을 가를 수 없어 중복으로 보지 않는다.
        enumCases.merge(other.enumCases) { first, second in
            first + second.filter { candidate in candidate.start.path.isEmpty || !first.contains { $0.start == candidate.start } }
        }
        typeSites.merge(other.typeSites) { $0.start <= $1.start ? $0 : $1 }
        memberTypes.merge(other.memberTypes) { $0.union($1) }
    }

    mutating func addMemberType(_ key: String, type: String) {
        memberTypes[key, default: []].insert(type)
    }

    /// 타입 문맥 안 프로퍼티 이름의 표기된 타입. 바깥 타입부터 안쪽으로 찾고, 두 가지 이상이면 모른다.
    func memberType(named name: String, in enclosingTypes: [String]) -> String? {
        let types = enclosingTypes.flatMap { $0.split(separator: ".").map(String.init) }
        for depth in stride(from: types.count, through: 1, by: -1) {
            guard let found = memberTypes[(types.prefix(depth) + [name]).joined(separator: ".")] else { continue }
            return found.count == 1 ? found.first : nil
        }
        return nil
    }

    mutating func addInheritance(_ chain: String, names: [String], isProtocol: Bool) {
        inheritedNames[chain, default: []].formUnion(names)
        if isProtocol { protocolChains.insert(chain) }
    }

    mutating func addCase(_ chain: String, _ declaration: HTTPEnumCaseDeclaration) {
        enumCases[chain, default: []].append(declaration)
    }

    mutating func addTypeSite(_ chain: String, _ site: HTTPTypeDeclarationSite) {
        if let existing = typeSites[chain], existing.start <= site.start { return }
        typeSites[chain] = site
    }

    mutating func addType(_ chain: [String]) {
        typeChains.insert(chain.joined(separator: "."))
        if let last = chain.last { typeLastNames.insert(last) }
    }

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
    ///
    /// - Parameter path: enum case·라우터 타입의 위치를 적을 경로. 라우터 사실의 심볼을 이 위치로 찾는다.
    public static func declarations(source: String, path: String = "") -> HTTPDeclarationSurface {
        let tree = Parser.parse(source: source)
        let collector = HTTPSurfaceCollector(recorder: HTTPRouterSurfaceRecorder(
            converter: SourceLocationConverter(fileName: path, tree: tree), path: path
        ))
        collector.walk(tree)
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
        let local = HTTPSurfaceCollector(recorder: HTTPRouterSurfaceRecorder(converter: converter, path: path))
        local.walk(tree)
        var surface = self.surface
        surface.merge(local.surface)
        let collector = HTTPRouteCallCollector(
            wrappers: wrappers, converter: converter, bindings: bindings, locals: locals,
            surface: surface, path: path, isTestSource: isTestSource
        )
        collector.walk(tree)
        return RouteCallScanResult(
            calls: collector.calls, counts: collector.counts, callsByWrapper: collector.callsByWrapper,
            routerTables: collector.routerTables, routerRecipes: collector.routerRecipes
        )
    }
}

// MARK: - 선언 표면

/// 타입·함수·이니셜라이저 선언과 외부 레이블을 모은다. 본문 안의 지역 선언은 심볼이 아니라 뺀다.
private final class HTTPSurfaceCollector: SyntaxVisitor {
    private(set) var surface = HTTPDeclarationSurface()
    private var typeNames: [String] = []
    /// 원시 타입이 `String` 인 enum 선언의 깊이별 표시. case 의 암시적 원시값을 정한다.
    private var stringBacked: [Bool] = []
    private let recorder: HTTPRouterSurfaceRecorder

    init(recorder: HTTPRouterSurfaceRecorder) {
        self.recorder = recorder
        super.init(viewMode: .sourceAccurate)
    }

    private var chain: [String] { typeNames.flatMap { $0.split(separator: ".").map(String.init) } }

    private func push(_ name: String, _ node: some DeclSyntaxProtocol, inheritance: InheritanceClauseSyntax?,
                      isProtocol: Bool = false, isExtension: Bool = false, isStringBacked: Bool = false) -> SyntaxVisitorContinueKind {
        typeNames.append(SyntaxIdentifiers.unescaped(name))
        stringBacked.append(isStringBacked)
        surface.addType(chain)
        recorder.recordType(node, chain: chain, inheritance: inheritance, isProtocol: isProtocol,
                            isExtension: isExtension, into: &surface)
        return .visitChildren
    }

    private func pop() {
        typeNames.removeLast()
        stringBacked.removeLast()
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text, node, inheritance: node.inheritanceClause)
    }
    override func visitPost(_: ClassDeclSyntax) { pop() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text, node, inheritance: node.inheritanceClause)
    }
    override func visitPost(_: StructDeclSyntax) { pop() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text, node, inheritance: node.inheritanceClause,
             isStringBacked: HTTPRouterSurfaceRecorder.isStringBacked(node.inheritanceClause))
    }
    override func visitPost(_: EnumDeclSyntax) { pop() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text, node, inheritance: node.inheritanceClause)
    }
    override func visitPost(_: ActorDeclSyntax) { pop() }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text, node, inheritance: node.inheritanceClause, isProtocol: true)
    }
    override func visitPost(_: ProtocolDeclSyntax) { pop() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.extendedType.trimmedDescription, node, inheritance: node.inheritanceClause, isExtension: true)
    }
    override func visitPost(_: ExtensionDeclSyntax) { pop() }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        if !typeNames.isEmpty {
            recorder.recordCases(node, chain: chain, isStringBacked: stringBacked.last ?? false, into: &surface)
        }
        return .skipChildren
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if !typeNames.isEmpty, !DeclarationCollector.isInsideBody(node),
           let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
           let type = node.typeAnnotation.flatMap({ HTTPSyntax.typeBaseName($0.type) }) {
            surface.addMemberType((chain + [SyntaxIdentifiers.unescaped(name)]).joined(separator: "."), type: type)
        }
        return .skipChildren
    }

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
    /// `스코프 키#이름` → `URLComponents(…)` 초기식과 그 선언. 같은 키에 두 번 묶이면 nil.
    private var componentsBindings: [String: (value: ExprSyntax, node: Syntax)?] = [:]
    /// `타입 사슬.이름` → 멤버 URL 상수의 식(`static let base = URL(string: …)`, 단일 식 계산 프로퍼티).
    private var memberURLs: [String: ExprSyntax?] = [:]

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return .visitChildren }
        if let type = node.typeAnnotation?.type { noteType(name, type) }
        if DeclarationCollector.isInsideBody(node) {
            if let value = node.initializer?.value {
                bindURL(name, value, at: node)
                bindComponents(name, value, at: node)
            }
        } else {
            bindMemberURL(name, node)
        }
        return .visitChildren
    }

    /// `var components = URLComponents(…)` 을 기록한다. 사용 지점이 같은 블록의 대입을 다시 읽는다.
    private func bindComponents(_ name: String, _ value: ExprSyntax, at node: some SyntaxProtocol) {
        guard HTTPSyntax.isComponentsConstruction(value) else { return }
        let key = HTTPSyntax.localKey(SyntaxIdentifiers.unescaped(name), scope: HTTPSyntax.innermostScope(of: node))
        componentsBindings[key] = componentsBindings[key] == nil ? .some((value, Syntax(node))) : .some(nil)
    }

    /// 타입 멤버의 URL 상수. 불변 `let` 의 초기식이거나, 본문이 식 하나뿐인 읽기 전용 계산 프로퍼티다.
    ///
    /// `var` 저장 프로퍼티는 어디서든 바뀔 수 있어 상수가 아니다.
    private func bindMemberURL(_ name: String, _ node: PatternBindingSyntax) {
        let declaration = node.parent?.parent?.as(VariableDeclSyntax.self)
        let value: ExprSyntax?
        if let initializer = node.initializer?.value, declaration?.bindingSpecifier.tokenKind == .keyword(.let) {
            value = initializer
        } else if let getter = node.accessorBlock.flatMap(HTTPSyntax.singleGetterExpression) {
            value = getter
        } else {
            value = nil
        }
        guard let value, HTTPSyntax.isURLConstruction(value) else { return }
        let key = (HTTPSyntax.context(of: node).enclosingTypes + [SyntaxIdentifiers.unescaped(name)]).joined(separator: ".")
        memberURLs[key] = memberURLs[key] == nil ? .some(value) : .some(nil)
    }

    /// 사용 지점 문맥에서 이름이 가리키는 `URLComponents` 초기식과 선언.
    func componentsBinding(named name: String, scopes: [Int]) -> (value: ExprSyntax, node: Syntax)? {
        for scope in scopes.reversed() {
            if let found = componentsBindings[HTTPSyntax.localKey(name, scope: scope)] { return found }
        }
        return nil
    }

    /// `baseURL`·`self.baseURL`·`Self.baseURL`·`API.baseURL` 이 가리키는 멤버 URL 상수의 식.
    func memberURLExpression(_ expression: ExprSyntax, enclosingTypes: [String]) -> ExprSyntax? {
        let types = enclosingTypes.flatMap { $0.split(separator: ".").map(String.init) }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            let name = SyntaxIdentifiers.unescaped(reference.baseName.text)
            for depth in stride(from: types.count, through: 1, by: -1) {
                if let found = memberURLs[(types.prefix(depth) + [name]).joined(separator: ".")] { return found }
            }
            return nil
        }
        guard let member = expression.as(MemberAccessExprSyntax.self), let base = member.base,
              let owner = HTTPSyntax.dottedName(base) else { return nil }
        let name = SyntaxIdentifiers.unescaped(member.declName.baseName.text)
        if owner == ["self"] || owner == ["Self"] {
            return memberURLs[(types + [name]).joined(separator: ".")] ?? nil
        }
        let suffix = "." + (owner + [name]).joined(separator: ".")
        let matches = memberURLs.filter { ("." + $0.key).hasSuffix(suffix) }
        return matches.count == 1 ? matches.first?.value ?? nil : nil
    }

    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let value = node.initializer?.value else { return .visitChildren }
        bindURL(name, value, at: node)
        bindComponents(name, value, at: node)
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
    /// 요청 URL 을 만드는 식인지(`URL(string:)`, `…appendingPathComponent(…)`, `x.asURL()`, 그 강제 해제).
    static func isURLConstruction(_ expression: ExprSyntax) -> Bool {
        let value = unwrapped(expression)
        guard let call = value.as(FunctionCallExprSyntax.self) else { return false }
        if isFoundationInitializer(call, type: "URL") {
            return call.arguments.first?.label?.text == "string"
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "asURL",
           call.arguments.isEmpty, member.base != nil {
            return true
        }
        return appendedComponent(of: call) != nil
    }

    /// `URLComponents(…)` 생성식인지.
    static func isComponentsConstruction(_ expression: ExprSyntax) -> Bool {
        unwrapped(expression).as(FunctionCallExprSyntax.self).map { isFoundationInitializer($0, type: "URLComponents") } ?? false
    }

    /// `Type(`·`Type.init(`·`Foundation.Type(`·`Foundation.Type.init(` 처럼 Foundation 타입을 만드는 호출인지.
    ///
    /// 다른 모듈로 한정한 같은 이름(`Other.URLRequest`)은 Foundation 타입이 아니므로 받지 않는다.
    static func isFoundationInitializer(_ call: FunctionCallExprSyntax, type: String) -> Bool {
        guard var name = dottedName(call.calledExpression) else { return false }
        if name.last == "init" { name.removeLast() }
        return name == [type] || name == ["Foundation", type]
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

    /// 괄호·강제 해제·옵셔널 체이닝·`try`·`await` 를 벗긴다.
    static func unwrapped(_ expression: ExprSyntax) -> ExprSyntax {
        var value = BindingCollector.unparenthesized(expression)
        while true {
            if let forced = value.as(ForceUnwrapExprSyntax.self) {
                value = BindingCollector.unparenthesized(forced.expression)
            } else if let optional = value.as(OptionalChainingExprSyntax.self) {
                value = BindingCollector.unparenthesized(optional.expression)
            } else if let attempt = value.as(TryExprSyntax.self) {
                value = BindingCollector.unparenthesized(attempt.expression)
            } else if let awaited = value.as(AwaitExprSyntax.self) {
                value = BindingCollector.unparenthesized(awaited.expression)
            } else {
                return value
            }
        }
    }

    /// 읽기 전용 계산 프로퍼티의 본문이 식 하나(또는 `return` 하나)뿐이면 그 식.
    static func singleGetterExpression(_ block: AccessorBlockSyntax) -> ExprSyntax? {
        let statements: CodeBlockItemListSyntax
        switch block.accessors {
        case let .getter(items): statements = items
        case let .accessors(list):
            guard list.count == 1, let getter = list.first, getter.accessorSpecifier.tokenKind == .keyword(.get),
                  let body = getter.body else { return nil }
            statements = body.statements
        }
        guard statements.count == 1, let item = statements.first?.item else { return nil }
        if let expression = item.as(ExprSyntax.self) { return expression }
        return item.as(ReturnStmtSyntax.self)?.expression
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

    /// dynamic 원문. 문자열 조각을 하나의 흐름으로 가리고, 공백을 한 칸으로 접은 뒤 길이 상한으로 자른다.
    static func sanitizedText(_ expression: some SyntaxProtocol) -> String? {
        var pieces: [HTTPSourceTextSanitizer.Piece] = []
        for token in expression.tokens(viewMode: .sourceAccurate) {
            if !pieces.isEmpty, !token.leadingTrivia.isEmpty { pieces.append(.code(" ")) }
            if case let .stringSegment(raw) = token.tokenKind {
                pieces.append(.literal(raw))
            } else {
                pieces.append(.code(token.text))
            }
            if !token.trailingTrivia.isEmpty { pieces.append(.code(" ")) }
        }
        let text = HTTPSourceTextSanitizer.sanitize(pieces)
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
