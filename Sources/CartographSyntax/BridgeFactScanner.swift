import CartographCore
import Foundation
import SwiftOperators
import SwiftParser
import SwiftSyntax

/// 스캐너가 소스에서 찾은 사실과, 그것을 담고 있는 선언의 구문 정보.
///
/// 구문 분석은 USR 을 모른다. 인덱스와 맞추려면 선언의 이름과 줄이 필요하고,
/// 그 대조는 인덱스를 아는 위층(`CartographKit`)이 한다.
public struct ScannedBridgeFact: Hashable, Sendable {
    public let fact: BridgeFact
    /// 사실을 담고 있는 가장 안쪽 선언. 파일 최상위면 nil.
    public let declaration: EnclosingDeclaration?

    public init(fact: BridgeFact, declaration: EnclosingDeclaration?) {
        self.fact = fact
        self.declaration = declaration
    }
}

/// 사실을 감싸는 선언의 구문 정보.
///
/// 클로저 안의 `case "…"` 는 자기 USR 이 없다. 교환 형식이 정한 대로 "감싸는 함수/타입의
/// USR + 줄" 로 귀속한다. 그러려면 감싸는 선언이 무엇인지 알아야 한다.
public struct EnclosingDeclaration: Hashable, Sendable {
    /// 인덱스 이름과 맞출 기본 이름. `handle(_:result:)` 가 아니라 `handle`.
    public let name: String
    /// 인덱스가 붙이는 인자 라벨까지 포함한 이름. `handle(_:result:)`. 타입은 이름 그대로.
    ///
    /// 기본 이름만으로 맞추면 `handle(_:)` 과 `handle(_:result:)` 가 있을 때 줄이 더 가까운
    /// 쪽에 USR 이 붙는다. 그쪽이 진짜 핸들러가 아니면 isthmus 는 엉뚱한 선언을 살리고
    /// 진짜 핸들러는 죽은 코드로 보고된다.
    public let indexName: String
    /// 바깥 타입부터 이어 붙인 이름. 교환 형식의 `symbol.qualifiedName` 이다(`CameraPlugin.register`).
    public let qualifiedName: String
    public let line: Int

    public init(name: String, indexName: String, qualifiedName: String, line: Int) {
        self.name = name
        self.indexName = indexName
        self.qualifiedName = qualifiedName
        self.line = line
    }
}

/// 파일 하나를 훑은 결과. 사실과, 사실로 만들지 못해 세기만 한 것.
public struct BridgeScanResult: Sendable, Equatable {
    public let facts: [ScannedBridgeFact]
    /// `FlutterEventChannel(name:)` 생성 수. 스트림 브리지는 이 형식의 대상이 아니라 세기만 한다.
    ///
    /// 세지 않으면 이벤트 채널만 쓰는 플러그인이 "브리지 없음" 으로 읽힌다.
    public let unscannedEventChannels: Int
    /// `FlutterBasicMessageChannel(name:)` / `BasicMessageChannel(name:)` 생성 수.
    ///
    /// Pigeon 이 만든 코드는 메서드 채널을 아예 쓰지 않는다. 세지 않으면 Pigeon 플러그인은
    /// 파이프라인을 다 돌고도 핸들러가 계속 죽은 코드로 보고된다.
    public let unscannedMessageChannels: Int

    public init(facts: [ScannedBridgeFact], unscannedEventChannels: Int = 0, unscannedMessageChannels: Int = 0) {
        self.facts = facts
        self.unscannedEventChannels = unscannedEventChannels
        self.unscannedMessageChannels = unscannedMessageChannels
    }
}

/// Swift 소스에서 브리지 사실을 리터럴로 뽑아낸다.
///
/// 인덱스 스토어는 `FlutterMethodChannel(name: "camera")` 의 `"camera"` 를 모른다.
/// 문자열은 심볼이 아니다. 그런데 Dart 와 Swift 를 잇는 유일한 끈이 그 문자열이라,
/// 이것을 읽지 않으면 언어 경계 너머의 호출자는 영원히 보이지 않는다.
///
/// 이 타입은 파일 내용만 입력으로 받으므로 문자열 리터럴로 완전히 테스트된다.
public struct BridgeFactScanner: Sendable {
    public init() {}

    public func scan(source: String, path: String) -> BridgeScanResult {
        // 파서는 `channel = FlutterMethodChannel(…)` 과 `call.method == "x"` 를 접지 않은
        // SequenceExpr 로 남긴다. 연산자 우선순위로 접어야 대입과 비교가 보인다.
        // 접기 오류(알 수 없는 연산자)는 무시한다. 그 표현식만 못 읽을 뿐이다.
        let parsed = Parser.parse(source: source)
        let tree = OperatorTable.standardOperators.foldAll(parsed) { _ in }.as(SourceFileSyntax.self) ?? parsed
        let converter = SourceLocationConverter(fileName: path, tree: tree)

        // 두 번 걷는다. 상수와 채널 변수는 사용 지점보다 뒤에 선언될 수 있다
        // (프로퍼티는 아래, 사용은 위의 `init` 안). 1차 패스는 모으기만 하고 해석은
        // 전부 2차 패스에서 한다. 1차 패스에서 해석하면 아래에 있는 상수를 못 본다.
        let bindings = BindingCollector()
        bindings.walk(tree)

        let collector = BridgeFactCollector(converter: converter, bindings: bindings, path: path)
        collector.walk(tree)
        return BridgeScanResult(
            facts: collector.facts.sorted { $0.fact < $1.fact },
            unscannedEventChannels: bindings.eventChannelCount,
            unscannedMessageChannels: bindings.messageChannelCount
        )
    }
}

// MARK: - 이름 해석

/// 리터럴 또는 표현식으로 표현된 이름.
struct ResolvedName: Hashable {
    let text: String
    let isDynamic: Bool

    static func literal(_ text: String) -> ResolvedName { ResolvedName(text: text, isDynamic: false) }
    static func dynamic(_ text: String) -> ResolvedName { ResolvedName(text: text, isDynamic: true) }
}

/// 이름 하나에 묶인 값. 문자열 리터럴이거나, 채널 생성자의 `name:` 인자다.
///
/// 채널 인자는 바인딩 시점의 문맥과 함께 저장하고 2차 패스에서 그 문맥으로 해석한다.
/// 1차 패스에서 해석하면 아래에 선언된 상수를 못 본다.
enum BoundValue: Equatable {
    case literal(String)
    case channel(argument: ExprSyntax, scopes: [Int], enclosingTypes: [String])
    /// 이 파일이 선언한 타입의 인스턴스(`let instance = CameraPlugin()`).
    case instance(typeName: String)
    /// 리터럴도 채널도 아닌 값. 이 이름이 이 스코프에서 그 값을 가리키므로 바깥의 동명 상수를
    /// 대신 쓰면 안 된다. 그림자다.
    case opaque

    static func == (lhs: BoundValue, rhs: BoundValue) -> Bool {
        switch (lhs, rhs) {
        case let (.literal(a), .literal(b)): a == b
        case let (.channel(a, sa, ta), .channel(b, sb, tb)): a.id == b.id && sa == sb && ta == tb
        case let (.instance(a), .instance(b)): a == b
        case (.opaque, .opaque): true
        default: false
        }
    }
}

/// 파일 안의 문자열 상수와 채널 변수를 모은다.
///
/// 한 단계만 따라간다. `static let name = "…"` 을 `FlutterMethodChannel(name: Self.name)` 에
/// 넣는 것은 흔하고, 그것을 놓치면 채널 대부분이 `dynamic` 으로 나온다. 두 단계
/// 이상(상수가 다른 상수를 참조)은 드물고, 그 경우는 정직하게 `dynamic` 으로 남긴다.
///
/// 이름은 선언된 자리로 구분한다. 지역 이름은 그것을 선언한 함수·클로저의 키로,
/// 멤버는 타입의 키로, 나머지는 파일 최상위로. 같은 키에 다른 값이 두 번 오면 `nil`
/// 로 지워 "모른다"고 한다. 어느 함수의 `let name` 이든 파일 전체의 `name` 을 그
/// 값으로 풀면, 다른 모듈의 것을 가리키는 참조가 이 파일의 무관한 값으로 나간다.
/// `dynamic` 은 안전하지만 틀린 리터럴은 isthmus 의 조인을 오염시킨다.
final class BindingCollector: SyntaxVisitor {
    /// `Type.name`, `<스코프>#name`, 또는 최상위 `name` → 값. 충돌하면 nil.
    private var bindings: [String: BoundValue?] = [:]
    /// 이 파일이 선언하거나 확장한 타입 이름.
    private(set) var declaredTypeNames: Set<String> = []
    /// `@objc(Name)` 클래스 이름 → 모듈 이름과 `@objcMembers` 여부. 익스텐션이 이것을 이어받는다.
    private(set) var reactModules: [String: (name: String, exportsAllMembers: Bool)] = [:]
    /// `FlutterEventChannel(name:)` 생성 수.
    private(set) var eventChannelCount = 0
    /// `FlutterBasicMessageChannel(name:)` / `BasicMessageChannel(name:)` 생성 수.
    private(set) var messageChannelCount = 0
    /// 핸들러로 넘겨진 메서드 이름 → 그 등록 호출의 수신자와 문맥.
    ///
    /// `channel.setMethodCallHandler(handleCall)` 처럼 클로저 대신 메서드 참조를 넘기는
    /// 플러그인이 많다(audioplayers 가 그렇다). 그 메서드 안의 `case "…"` 는 이 채널의
    /// 것인데, 클로저 문맥이 없어 채널을 못 받았다.
    ///
    /// 키는 등록 지점의 타입 사슬과 메서드 이름이다. 이름만으로 맞추면 다른 타입의 동명
    /// 메서드가 이 채널을 받는다. 같은 메서드가 여러 채널에 등록되면 항목이 여럿 쌓이고,
    /// 2차 패스가 채널 이름을 푼 뒤 서로 다르면 "모른다" 고 한다.
    private(set) var handlerFunctions: [String: [(receiver: ExprSyntax, scopes: [Int], enclosingTypes: [String])]] = [:]
    /// `registrar.addMethodCallDelegate(instance, channel:)` 로 델리게이트가 된 타입 → 채널 인자와 문맥.
    ///
    /// FlutterPlugin 표준 형태다. 그 타입의 `handle(_:result:)` 가 이 채널의 핸들러라는 것은
    /// 추측이 아니라 등록 호출이 말해 주는 사실이다. "파일에 채널이 하나" 추측보다 먼저다.
    ///
    /// 기록은 쓰인 그대로다(`Plugin()` 이면 `Plugin`). 어느 선언을 가리키는지는 파일을 다 읽은
    /// 2차 패스에서 등록 지점의 타입 사슬과 선언된 타입 사슬로 푼다. 기록 시점에 풀면 아래에
    /// 선언된 타입을 모르고, 짧은 이름을 그대로 키로 쓰면 최상위 동명 타입에 붙는다.
    private(set) var delegateRegistrations: [(typeName: String, channel: ExprSyntax, scopes: [Int], enclosingTypes: [String])] = []
    /// 이 파일이 선언한 타입의 점으로 이은 전체 이름(`A.Plugin`).
    private(set) var declaredTypeChains: Set<String> = []

    /// 지금 어느 타입 안에 있는지.
    private var typeNames: [String] = []
    /// 지금 어느 함수·클로저 안에 있는지. 바깥부터 쌓인다.
    private var scopes: [Int] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: 스코프 문맥

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_ node: FunctionDeclSyntax) { scopes.removeLast() }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_ node: InitializerDeclSyntax) { scopes.removeLast() }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_ node: ClosureExprSyntax) { scopes.removeLast() }

    private func pushScope(_ node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        scopes.append(Self.scopeKey(node)); return .visitChildren
    }

    /// 함수·클로저를 구분하는 키. 두 패스가 같은 트리를 걸으므로 같은 노드에서 같은 값이다.
    static func scopeKey(_ node: some SyntaxProtocol) -> Int { node.position.utf8Offset }

    // MARK: 타입 문맥

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if let name = BridgeFactCollector.objectiveCName(in: node.attributes) {
            reactModules[node.name.text] = (name, BridgeFactCollector.hasAttribute("objcMembers", in: node.attributes))
        }
        return pushType(node.name.text)
    }
    override func visitPost(_ node: ClassDeclSyntax) { typeNames.removeLast() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node.name.text) }
    override func visitPost(_ node: StructDeclSyntax) { typeNames.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node.name.text) }
    override func visitPost(_ node: EnumDeclSyntax) { typeNames.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node.name.text) }
    override func visitPost(_ node: ActorDeclSyntax) { typeNames.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.extendedType.trimmedDescription)
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeNames.removeLast() }

    private func pushType(_ name: String) -> SyntaxVisitorContinueKind {
        let unescaped = DeclarationCollector.unescaped(name)
        declaredTypeNames.insert(unescaped)
        typeNames.append(unescaped)
        declaredTypeChains.insert(typeNames.joined(separator: "."))
        return .visitChildren
    }

    // MARK: 바인딩 수집

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let value = node.initializer?.value
        else { return .visitChildren }
        bind(name: DeclarationCollector.unescaped(name), to: value, isLocal: DeclarationCollector.isInsideBody(node))
        return .visitChildren
    }

    /// `channel = FlutterMethodChannel(...)` 처럼 대입으로 채널을 만드는 경우. `init` 안이 흔하다.
    ///
    /// `self.name = "…"` 은 프로퍼티라 타입 키로, 본문 안의 `name = "…"` 은 지역 키로 간다.
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.operator.is(AssignmentExprSyntax.self) else { return .visitChildren }
        if let name = Self.identifierName(of: node.leftOperand) {
            let isMember = node.leftOperand.is(MemberAccessExprSyntax.self)
            bind(name: name, to: node.rightOperand, isLocal: !isMember && DeclarationCollector.isInsideBody(node))
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        switch Self.calleeName(of: node) {
        case BridgeFactCollector.flutterEventChannelTypeName: eventChannelCount += 1
        case let name? where BridgeFactCollector.messageChannelTypeNames.contains(name): messageChannelCount += 1
        default: break
        }
        recordHandlerReference(node)
        recordDelegate(node)
        return .visitChildren
    }

    /// `registrar.addMethodCallDelegate(instance, channel: c)` 의 `instance` 가 어느 타입인지 기억한다.
    ///
    /// `T(...)`, `self`, 그리고 이 파일에서 `let x = T(...)` 로 만든 변수를 안다. 그 밖은 모른다.
    private func recordDelegate(_ call: FunctionCallExprSyntax) {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "addMethodCallDelegate",
              let instance = call.arguments.first?.expression,
              let channel = call.arguments.first(where: { $0.label?.text == "channel" })?.expression,
              let typeName = delegateTypeName(of: instance)
        else { return }
        delegateRegistrations.append((typeName, channel, scopes, typeNames))
    }

    /// 쓰인 타입 이름이 어느 선언을 가리키는지. Swift 의 이름 조회처럼 감싸는 타입에서 바깥으로.
    ///
    /// `enum A { class Plugin { … Plugin() … } }` 의 `Plugin` 은 `A.Plugin` 이다. 파일 최상위에
    /// 다른 `Plugin` 이 있어도 그렇다. 어디에도 없으면 다른 모듈의 타입이라 쓰인 그대로 둔다.
    func resolveTypeChain(_ dotted: String, from enclosingTypes: [String]) -> String {
        for depth in stride(from: enclosingTypes.count, through: 0, by: -1) {
            let candidate = (enclosingTypes.prefix(depth) + [dotted]).joined(separator: ".")
            if declaredTypeChains.contains(candidate) { return candidate }
        }
        return dotted
    }

    /// 델리게이트 인스턴스의 타입. `A.Plugin()` 은 `A.Plugin`.
    ///
    /// 이 파일이 선언한 타입인지는 여기서 거르지 않는다. 타입 선언이 등록 호출보다 아래에
    /// 있을 수 있고, 2차 패스는 선언된 타입의 사슬로만 조회하므로 다른 모듈의 타입 이름은
    /// 어디에도 맞지 않는다.
    private func delegateTypeName(of expression: ExprSyntax) -> String? {
        if let call = expression.as(FunctionCallExprSyntax.self), let last = Self.calleeName(of: call),
           last.first?.isUppercase == true {
            return Self.dottedTypeName(of: call.calledExpression)
        }
        if expression.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" { return typeNames.joined(separator: ".") }
        if let name = Self.identifierName(of: expression),
           case let .instance(typeName)?? = binding(named: name, in: Context(scopes: scopes, enclosingTypes: typeNames), membersOnly: false) {
            return typeName
        }
        return nil
    }

    /// `A.Plugin` 처럼 점으로 이은 타입 표현식의 이름. 제네릭 인자는 뗀다.
    static func dottedTypeName(of expression: ExprSyntax) -> String {
        if let specialized = expression.as(GenericSpecializationExprSyntax.self) { return dottedTypeName(of: specialized.expression) }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base {
            return dottedTypeName(of: base) + "." + DeclarationCollector.unescaped(member.declName.baseName.text)
        }
        return identifierName(of: expression) ?? expression.trimmedDescription
    }

    static func handlerKey(_ name: String, enclosingTypes: [String]) -> String {
        (enclosingTypes + [name]).joined(separator: ".")
    }

    /// `receiver.setMethodCallHandler(method)` 의 `method` 가 메서드 참조면 기억한다.
    private func recordHandlerReference(_ call: FunctionCallExprSyntax) {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "setMethodCallHandler",
              let receiver = member.base, call.trailingClosure == nil,
              let argument = call.arguments.first?.expression,
              !argument.is(ClosureExprSyntax.self), !argument.is(NilLiteralExprSyntax.self),
              let name = Self.identifierName(of: argument)
        else { return }
        // `self.handle` 이나 `handle` — 등록 지점을 감싸는 타입의 메서드다. 다른 수신자는 모른다.
        if let member = argument.as(MemberAccessExprSyntax.self),
           let base = member.base, base.as(DeclReferenceExprSyntax.self)?.baseName.text != "self" { return }
        handlerFunctions[Self.handlerKey(name, enclosingTypes: typeNames), default: []].append((receiver, scopes, typeNames))
    }

    private func bind(name: String, to value: ExprSyntax, isLocal: Bool) {
        let bound: BoundValue
        if let literal = Self.stringLiteral(value) {
            bound = .literal(literal)
        } else if let argument = Self.channelNameArgument(value) {
            bound = .channel(argument: argument, scopes: scopes, enclosingTypes: typeNames)
        } else if let call = value.as(FunctionCallExprSyntax.self), let last = Self.calleeName(of: call),
                  last.first?.isUppercase == true, !BridgeFactCollector.channelTypeNames.contains(last) {
            // 대문자 호출은 생성자로 본다. 다른 모듈의 타입이면 어느 지역 타입 사슬에도 맞지 않는다.
            bound = .instance(typeName: Self.dottedTypeName(of: call.calledExpression))
        } else {
            bound = .opaque
        }
        let key = isLocal ? Self.localKey(name, scope: scopes.last) : (typeNames + [name]).joined(separator: ".")
        if let existing = bindings[key] {
            if existing != bound { bindings[key] = .some(nil) }
        } else {
            bindings[key] = bound
        }
    }

    private static func localKey(_ name: String, scope: Int?) -> String {
        "\(scope ?? -1)#\(name)"
    }

    // MARK: 해석 (2차 패스에서 부른다)

    /// 사용 지점의 문맥.
    struct Context {
        let scopes: [Int]
        let enclosingTypes: [String]
    }

    /// 바인딩 조회 결과. 없음(`nil`)과 있는데 모름(`.some(nil)`)을 가른다.
    private func binding(named name: String, in context: Context, membersOnly: Bool) -> BoundValue?? {
        if !membersOnly {
            for scope in context.scopes.reversed() {
                if let found = bindings[Self.localKey(name, scope: scope)] { return found }
            }
        }
        for depth in stride(from: context.enclosingTypes.count, through: 0, by: -1) {
            let key = (context.enclosingTypes.prefix(depth) + [name]).joined(separator: ".")
            if let found = bindings[key] { return found }
        }
        return nil
    }

    /// 채널 변수 이름을 채널 이름으로 푼다. 변수를 모르면 nil, 알지만 못 풀면 `.some(nil)`.
    func channel(named name: String, in context: Context) -> ResolvedName?? {
        guard let found = binding(named: name, in: context, membersOnly: false) else { return nil }
        guard case let .channel(argument, scopes, types)? = found else { return .some(nil) }
        return .some(resolveString(argument, in: Context(scopes: scopes, enclosingTypes: types)))
    }

    /// 파일 안의 채널 생성 전부를 이름으로 푼 것. 핸들러 문맥 밖의 추측에 쓴다.
    func allChannelNames() -> [ResolvedName] {
        bindings.values.compactMap { value in
            guard case let .channel(argument, scopes, types)? = value else { return nil }
            return resolveString(argument, in: Context(scopes: scopes, enclosingTypes: types))
        }
    }

    /// `FlutterMethodChannel(name: …, …)` 호출이면 그 채널 이름.
    func channelConstruction(_ expression: ExprSyntax, in context: Context) -> ResolvedName? {
        Self.channelNameArgument(expression).map { resolveString($0, in: context) }
    }

    /// `FlutterMethodChannel(name: …)` 또는 `FlutterMethodChannel.init(name: …)` 의 `name:` 인자.
    static func channelNameArgument(_ expression: ExprSyntax) -> ExprSyntax? {
        guard let call = expression.as(FunctionCallExprSyntax.self), isChannelConstructor(call.calledExpression),
              let argument = call.arguments.first(where: { $0.label?.text == "name" })
        else { return nil }
        return argument.expression
    }

    private static func isChannelConstructor(_ callee: ExprSyntax) -> Bool {
        if let member = callee.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "init" {
            return member.base.flatMap(identifierName(of:)) == BridgeFactCollector.flutterChannelTypeName
        }
        return identifierName(of: callee) == BridgeFactCollector.flutterChannelTypeName
    }

    /// 문자열 표현식을 리터럴로 푼다. 못 풀면 원문 표현식을 `dynamic` 으로 돌려준다.
    ///
    /// - `name`: 감싸는 클로저·함수에서 바깥으로, 그다음 감싸는 타입에서 바깥으로, 마지막으로
    ///   파일 최상위. 리터럴이 아닌 값에 걸리면 거기서 멈춘다. 그 이름은 그 값이다.
    /// - `Self.name`, `self.name`: 감싸는 타입에서 바깥으로, 마지막으로 파일 최상위.
    /// - `Type.name`: 이 파일이 선언하거나 확장한 `Type` 의 상수만.
    /// - `.name`(암시적 멤버): 수신자 타입은 `String` 이지 이 파일의 어떤 타입도 아니다.
    ///   구문만으로는 어느 확장의 상수인지 알 수 없으므로 `dynamic`.
    func resolveString(_ expression: ExprSyntax, in context: Context) -> ResolvedName {
        if let literal = Self.stringLiteral(expression) { return .literal(literal) }
        if case let .literal(value)?? = constantBinding(for: expression, in: context) { return .literal(value) }
        return .dynamic(expression.trimmedDescription)
    }

    private func constantBinding(for expression: ExprSyntax, in context: Context) -> BoundValue?? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return binding(named: DeclarationCollector.unescaped(reference.baseName.text), in: context, membersOnly: false)
        }
        guard let member = expression.as(MemberAccessExprSyntax.self),
              let base = member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text
        else { return nil }
        let name = DeclarationCollector.unescaped(member.declName.baseName.text)
        if base == "Self" || base == "self" { return binding(named: name, in: context, membersOnly: true) }
        let type = DeclarationCollector.unescaped(base)
        guard declaredTypeNames.contains(type) else { return nil }
        return bindings[type + "." + name]
    }

    /// 보간이 없는 문자열 리터럴의 내용.
    static func stringLiteral(_ expression: ExprSyntax) -> String? {
        guard let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }
        var result = ""
        for segment in literal.segments {
            guard case let .stringSegment(text) = segment else { return nil }
            result += text.content.text
        }
        return result
    }

    /// `x`, `self.x`, `Self.x`, `Type.x`, `.x`, `x?`, `x!` 에서 `x`.
    ///
    /// 채널 변수와 호출된 타입을 찾는 용도다. 문자열 상수는 수신자를 보는 `resolveString` 을 쓴다.
    static func identifierName(of expression: ExprSyntax) -> String? {
        // `channel?.setMethodCallHandler` 와 `channel!.…` 의 수신자는 한 겹 감싸여 있다.
        if let chained = expression.as(OptionalChainingExprSyntax.self) {
            return identifierName(of: chained.expression)
        }
        if let forced = expression.as(ForceUnwrapExprSyntax.self) {
            return identifierName(of: forced.expression)
        }
        // `BasicMessageChannel<Any?>(name:)` 의 호출 대상은 제네릭 특수화 노드에 싸여 있다.
        if let specialized = expression.as(GenericSpecializationExprSyntax.self) {
            return identifierName(of: specialized.expression)
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return DeclarationCollector.unescaped(reference.baseName.text)
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            return DeclarationCollector.unescaped(member.declName.baseName.text)
        }
        return nil
    }

    /// 호출된 함수의 마지막 이름. `Foo(...)` 와 `Module.Foo(...)` 모두 `Foo`.
    static func calleeName(of call: FunctionCallExprSyntax) -> String? {
        identifierName(of: call.calledExpression)
    }
}

// MARK: - 사실 수집

/// 브리지 사실을 실제로 뽑아내는 방문자.
final class BridgeFactCollector: SyntaxVisitor {
    /// Flutter 가 Swift 쪽에 제공하는 채널 타입 이름.
    static let flutterChannelTypeName = "FlutterMethodChannel"
    /// 스트림 브리지의 채널 타입. 읽지 않고 세기만 한다.
    static let flutterEventChannelTypeName = "FlutterEventChannel"
    /// 메시지 브리지(Pigeon 산출물)의 채널 타입. 읽지 않고 세기만 한다.
    static let messageChannelTypeNames: Set<String> = ["FlutterBasicMessageChannel", "BasicMessageChannel"]
    /// 핸들러가 받는 호출 타입. 이 타입의 인자를 가진 함수 안에서만 `call.method` 분기를 믿는다.
    static let flutterMethodCallTypeName = "FlutterMethodCall"
    /// 핸들러를 채널에 다는 메서드 이름들.
    static let handlerRegistrationMethods: Set<String> = ["setMethodCallHandler", "addMethodCallDelegate"]
    /// 채널 타입 이름 전부. 인스턴스 바인딩에서 채널 생성을 뺄 때 쓴다.
    static let channelTypeNames: Set<String> = messageChannelTypeNames.union([flutterChannelTypeName, flutterEventChannelTypeName])

    private(set) var facts: [ScannedBridgeFact] = []
    private let converter: SourceLocationConverter
    private let bindings: BindingCollector
    private let path: String

    /// 감싸는 선언의 스택. 사실을 어느 USR 에 귀속시킬지 정한다.
    private var declarations: [EnclosingDeclaration] = []
    /// 감싸는 타입 이름의 스택. `symbol.qualifiedName` 을 만들고 상수를 찾는 문맥이 된다.
    private var typeNames: [String] = []
    /// 지금 어느 `setMethodCallHandler` 클로저 안에 있는지. 바깥부터 쌓인다.
    private var handlerChannels: [ResolvedName?] = []
    /// `FlutterMethodCall` 인자를 받는 함수 안에 있는 깊이.
    private var methodCallFunctionDepth = 0
    /// `@objc(Name)` 클래스(또는 그 익스텐션) 안에 있으면 그 이름과, 멤버 전부를 내보내는지.
    private var reactModules: [(name: String, exportsAllMembers: Bool)?] = []
    /// `let m = call.method` 로 메서드 이름을 담아 둔 지역 변수들. 함수·클로저마다 한 층.
    ///
    /// `switch m` 을 못 알아보면 그 핸들러의 메서드가 전부 사라진다. 실제 플러그인에서
    /// 드물지 않은 형태다. 파일 전역으로 두면 한 함수의 별칭이 다른 함수의 무관한 `m` 을
    /// 메서드 이름으로 위장시킨다.
    private var aliasScopes: [Set<String>] = [[]]
    /// 지금 어느 함수 본문 안에 있는지. `BindingCollector` 와 같은 키다.
    private var scopes: [Int] = []

    init(converter: SourceLocationConverter, bindings: BindingCollector, path: String) {
        self.converter = converter
        self.bindings = bindings
        self.path = path
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: 선언 문맥

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, node: node)
        let module = bindings.reactModules[DeclarationCollector.unescaped(node.name.text)]
        reactModules.append(module)
        if let module {
            emit(.moduleExport, target: .reactNative, channel: .literal(module.name), at: node.name)
        }
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { popType(); reactModules.removeLast() }

    // 중첩 타입은 바깥 클래스의 Objective-C 노출을 물려받지 않는다.
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, node: node); reactModules.append(nil); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { popType(); reactModules.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, node: node); reactModules.append(nil); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { popType(); reactModules.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, node: node); reactModules.append(nil); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { popType(); reactModules.removeLast() }

    /// `@objc(Name)` 클래스의 익스텐션에 둔 `@objc` 메서드도 JS 에 보인다.
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let typeName = DeclarationCollector.unescaped(node.extendedType.trimmedDescription)
        pushType(typeName, node: node)
        // `private extension` 의 멤버는 전부 private 이라 Objective-C 에 보이지 않는다.
        let module = Self.isFilePrivate(node.modifiers) ? nil : bindings.reactModules[typeName].map {
            (name: $0.name, exportsAllMembers: $0.exportsAllMembers || Self.hasAttribute("objcMembers", in: node.attributes))
        }
        reactModules.append(module)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { popType(); reactModules.removeLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        // 스코프는 지역 함수에도 쌓는다. 1차 패스와 같은 키여야 지역 상수가 맞는다.
        scopes.append(BindingCollector.scopeKey(node)); aliasScopes.append([])
        // 함수 본문 안의 지역 함수는 인덱스에 정점이 없고 Objective-C 에도 보이지 않는다.
        // 감싸는 메서드가 그대로 남는다.
        guard !DeclarationCollector.isInsideBody(node) else { return .visitChildren }
        pushDeclaration(
            name: node.name.text,
            indexName: Self.indexName(node.name.text, parameters: node.signature.parameterClause.parameters),
            node: node
        )
        if Self.takesMethodCall(node) { methodCallFunctionDepth += 1 }
        if let channel = referencedHandlerChannel(of: node) { handlerChannels.append(channel) }
        emitReactMethodIfExported(node)
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) {
        scopes.removeLast(); aliasScopes.removeLast()
        guard !DeclarationCollector.isInsideBody(node) else { return }
        declarations.removeLast()
        if Self.takesMethodCall(node) { methodCallFunctionDepth -= 1 }
        if referencedHandlerChannel(of: node) != nil { handlerChannels.removeLast() }
    }

    /// 이 함수가 어느 채널의 핸들러인지, 등록 호출이 말해 준 것.
    ///
    /// 둘 중 하나다. `setMethodCallHandler(handleCall)` 로 메서드 참조가 넘겨졌거나,
    /// 이 함수가 `addMethodCallDelegate(instance, channel:)` 로 등록된 타입의
    /// `handle(_:result:)` 이거나. 둘 다 추측이 아니다.
    private func referencedHandlerChannel(of node: FunctionDeclSyntax) -> ResolvedName?? {
        // 메서드 참조든 델리게이트든, 핸들러는 FlutterMethodCall 을 받는 함수다. 아니면 동명의
        // 무관한 함수라 `request.method == "DELETE"` 가 이 채널의 사실로 나간다.
        guard Self.takesMethodCall(node) else { return nil }
        let name = DeclarationCollector.unescaped(node.name.text)
        if let entries = bindings.handlerFunctions[BindingCollector.handlerKey(name, enclosingTypes: typeNames)] {
            return .some(Self.single(entries.map { resolveChannel($0.receiver, in: .init(scopes: $0.scopes, enclosingTypes: $0.enclosingTypes)) }))
        }
        // FlutterPlugin 이 요구하는 것은 정확히 `handle(_:result:)` 다. 다른 오버로드는 아니다.
        let indexName = Self.indexName(name, parameters: node.signature.parameterClause.parameters)
        guard indexName == "handle(_:result:)" else { return nil }
        let chain = typeNames.joined(separator: ".")
        let registrations = bindings.delegateRegistrations.filter {
            bindings.resolveTypeChain($0.typeName, from: $0.enclosingTypes) == chain
        }
        guard !registrations.isEmpty else { return nil }
        return .some(Self.single(registrations.map { resolveChannel($0.channel, in: .init(scopes: $0.scopes, enclosingTypes: $0.enclosingTypes)) }))
    }

    /// 등록이 여럿이면 푼 채널 이름이 전부 같을 때만 그 채널이다. 다르면 모른다.
    ///
    /// 텍스트로 비교하면 스코프가 다른 동명 변수(`let channel` 둘)가 같은 채널로 읽힌다.
    private static func single(_ names: [ResolvedName]) -> ResolvedName? {
        Set(names).count == 1 ? names.first : nil
    }

    /// 클로저마다 한 층. 지역 상수와 별칭은 그것을 선언한 클로저 안에서만 보인다.
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(BindingCollector.scopeKey(node)); aliasScopes.append([]); return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) { scopes.removeLast(); aliasScopes.removeLast() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        pushDeclaration(
            name: "init",
            indexName: Self.indexName("init", parameters: node.signature.parameterClause.parameters),
            node: node
        )
        scopes.append(BindingCollector.scopeKey(node)); aliasScopes.append([])
        return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) {
        declarations.removeLast(); scopes.removeLast(); aliasScopes.removeLast()
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // 계산 프로퍼티나 `lazy var channel: … = { … }()` 안의 사실은 그 프로퍼티에 귀속시킨다.
        // 함수 본문 안의 지역 변수는 인덱스에 정점이 없으므로 감싸는 함수가 그대로 남는다.
        guard let name = Self.memberVariableName(node) else { return .visitChildren }
        pushDeclaration(name: name, indexName: name, node: node)
        return .visitChildren
    }
    override func visitPost(_ node: VariableDeclSyntax) {
        if Self.memberVariableName(node) != nil { declarations.removeLast() }
    }

    /// `let m = call.method` 를 기억한다. 핸들러 문맥 안에서만 의미가 있다.
    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
           let value = node.initializer?.value, Self.isMethodMemberAccess(value), currentHandlerChannel != nil {
            aliasScopes[aliasScopes.count - 1].insert(DeclarationCollector.unescaped(name))
        }
        return .visitChildren
    }

    private static func memberVariableName(_ node: VariableDeclSyntax) -> String? {
        guard let name = node.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              !DeclarationCollector.isInsideBody(node)
        else { return nil }
        return DeclarationCollector.unescaped(name)
    }

    /// 인덱스가 붙이는 이름. `handle(_:result:)`, `init(messenger:)`.
    static func indexName(_ base: String, parameters: FunctionParameterListSyntax) -> String {
        DeclarationCollector.unescaped(base) + "("
            + parameters.map { DeclarationCollector.unescaped($0.firstName.text) + ":" }.joined() + ")"
    }

    /// `FlutterMethodCall` 인자를 받는 함수인지. `FlutterPlugin.handle(_:result:)` 가 그렇다.
    ///
    /// `FlutterMethodCall?` 과 `Flutter.FlutterMethodCall` 도 같은 타입이다.
    private static func takesMethodCall(_ node: FunctionDeclSyntax) -> Bool {
        node.signature.parameterClause.parameters.contains {
            let type = $0.type.trimmedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "?!"))
            return type == flutterMethodCallTypeName || type.hasSuffix("." + flutterMethodCallTypeName)
        }
    }

    // MARK: Flutter

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              Self.handlerRegistrationMethods.contains(member.declName.baseName.text),
              // `setMethodCallHandler(nil)` 은 등록 해제다. 등록 사실이 아니다.
              !(node.arguments.first?.expression.is(NilLiteralExprSyntax.self) ?? false)
        else { return .visitChildren }

        let channel = registeredChannel(of: node, receiver: member.base)
        emit(.channelRegister, target: .flutter, channel: channel, at: node)

        // 핸들러 클로저 안의 `case "…"` 는 이 채널의 메서드다. 클로저를 방문하는 동안만
        // 채널을 스택에 올린다. 클로저가 없으면(델리게이트 등록) 올릴 것이 없다.
        guard let closure = Self.handlerClosure(of: node) else { return .visitChildren }
        handlerChannels.append(channel)
        walk(closure)
        handlerChannels.removeLast()
        // 클로저는 이미 걸었다. 수신자와 나머지 인자를 다시 걷되 그 클로저만 건너뛴다.
        if let base = member.base { walk(base) }
        for argument in node.arguments where argument.expression.id != closure.id {
            walk(argument.expression)
        }
        return .skipChildren
    }

    /// `setMethodCallHandler` 의 수신자 또는 `addMethodCallDelegate(_, channel:)` 의 인자에서 채널.
    private func registeredChannel(of call: FunctionCallExprSyntax, receiver: ExprSyntax?) -> ResolvedName? {
        if let argument = call.arguments.first(where: { $0.label?.text == "channel" }) {
            return resolveChannel(argument.expression)
        }
        return receiver.map(resolveChannel)
    }

    /// 채널 표현식을 이름으로 푼다. 인라인 생성, 변수, 그 밖의 표현식 순으로 본다.
    private func resolveChannel(_ expression: ExprSyntax) -> ResolvedName {
        resolveChannel(expression, in: context)
    }

    private func resolveChannel(_ expression: ExprSyntax, in context: BindingCollector.Context) -> ResolvedName {
        if let inline = bindings.channelConstruction(expression, in: context) { return inline }
        if let name = BindingCollector.identifierName(of: expression), let bound = bindings.channel(named: name, in: context) {
            return bound ?? .dynamic(expression.trimmedDescription)
        }
        return .dynamic(expression.trimmedDescription)
    }

    /// 지금 사용 지점의 문맥. 바인딩 조회에 넘긴다.
    private var context: BindingCollector.Context {
        BindingCollector.Context(scopes: scopes, enclosingTypes: typeNames)
    }

    /// 후행 클로저 또는 마지막 클로저 인자.
    private static func handlerClosure(of call: FunctionCallExprSyntax) -> ClosureExprSyntax? {
        if let trailing = call.trailingClosure { return trailing }
        return call.arguments.last?.expression.as(ClosureExprSyntax.self)
    }

    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        guard let switchExpression = Self.enclosingSwitch(of: node),
              isMethodNameExpression(switchExpression.subject),
              case let .case(label) = node.label,
              let (channel, inferred) = currentHandlerChannel
        else { return .visitChildren }
        for item in label.caseItems {
            guard let expression = item.pattern.as(ExpressionPatternSyntax.self)?.expression else { continue }
            emit(
                .methodHandle, target: .flutter, channel: channel,
                method: bindings.resolveString(expression, in: context), inferred: inferred, at: item
            )
        }
        return .visitChildren
    }

    /// `case` 를 감싸는 `switch`. `#if` 로 감싼 케이스는 사이에 조건 컴파일 노드가 끼어 있다.
    private static func enclosingSwitch(of node: SwitchCaseSyntax) -> SwitchExprSyntax? {
        var current = node.parent
        for _ in 0..<6 {
            guard let syntax = current else { return nil }
            if let found = syntax.as(SwitchExprSyntax.self) { return found }
            current = syntax.parent
        }
        return nil
    }

    /// `if call.method == "takePhoto"` 형태의 분기.
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard let op = node.operator.as(BinaryOperatorExprSyntax.self), op.operator.text == "==",
              let (channel, inferred) = currentHandlerChannel
        else { return .visitChildren }
        let sides = [(node.leftOperand, node.rightOperand), (node.rightOperand, node.leftOperand)]
        for (subject, value) in sides where isMethodNameExpression(subject) {
            emit(
                .methodHandle, target: .flutter, channel: channel,
                method: bindings.resolveString(value, in: context), inferred: inferred, at: value
            )
            break
        }
        return .visitChildren
    }

    /// `call.method` 처럼 메서드 이름을 읽는 표현식이거나, 그것을 담은 지역 변수인지.
    ///
    /// 수신자 이름은 보지 않는다. `call`, `methodCall`, `$0` 모두 쓰인다. 대신 문맥으로
    /// 거른다. 핸들러 클로저나 `FlutterMethodCall` 을 받는 함수 밖의 `.method` 는
    /// StoreKit 의 `transaction.method` 처럼 전혀 다른 것일 수 있다. 수신자 없는 `.method`
    /// 는 열거형 케이스라 제외한다.
    private func isMethodNameExpression(_ expression: ExprSyntax) -> Bool {
        let expression = Self.unparenthesized(expression)
        if Self.isMethodMemberAccess(expression) { return true }
        guard let reference = expression.as(DeclReferenceExprSyntax.self) else { return false }
        let name = DeclarationCollector.unescaped(reference.baseName.text)
        return aliasScopes.contains { $0.contains(name) }
    }

    private static func isMethodMemberAccess(_ expression: ExprSyntax) -> Bool {
        guard let member = unparenthesized(expression).as(MemberAccessExprSyntax.self) else { return false }
        return member.base != nil && member.declName.baseName.text == "method"
    }

    /// `switch (call.method)` 의 괄호를 벗긴다. 공개 플러그인(sensors_plus)이 실제로 이렇게 쓴다.
    private static func unparenthesized(_ expression: ExprSyntax) -> ExprSyntax {
        guard let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
              let only = tuple.elements.first, only.label == nil
        else { return expression }
        return unparenthesized(only.expression)
    }

    /// 지금 안에 있는 핸들러의 채널과, 그것이 추측인지.
    ///
    /// 클로저 안이면 그 채널이다. `FlutterPlugin` 스타일은 `handle(_:result:)` 메서드에서
    /// 분기하고 채널은 `register(with:)` 에서 따로 만든다. 그 함수 안이면 파일에 채널이
    /// 하나일 때 그것을 추측으로 붙이고, 아니면 채널 없이 낸다. 둘 다 아니면 이 분기는
    /// 브리지와 무관하므로 사실이 아니다.
    private var currentHandlerChannel: (ResolvedName?, Bool)? {
        if let inside = handlerChannels.last { return (inside, false) }
        guard methodCallFunctionDepth > 0 else { return nil }
        let known = Set(bindings.allChannelNames())
        return known.count == 1 ? (known.first, true) : (nil, false)
    }

    // MARK: React Native

    /// `@objc(Name)` 의 `Name`. 이름 없는 `@objc` 는 nil.
    static func objectiveCName(in attributes: AttributeListSyntax) -> String? {
        for element in attributes {
            guard case let .attribute(attribute) = element,
                  attribute.attributeName.trimmedDescription == "objc",
                  case let .objCName(pieces) = attribute.arguments
            else { continue }
            // 셀렉터는 콜론까지 이어 붙인다. 부르는 쪽에서 첫 조각만 잘라 쓴다.
            let name = pieces.map { ($0.name?.text ?? "") + ($0.colon?.text ?? "") }.joined()
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// `@objc(Name)` 클래스 안의 `@objc` 메서드는 JS 가 `NativeModules.Name.method()` 로 부른다.
    /// 클래스가 `@objcMembers` 면 표식 없는 메서드도 노출되지만, `@nonobjc` 는 아니고,
    /// `private`/`fileprivate` 은 명시적 `@objc` 가 있을 때만(SE-0186) Objective-C 에 보인다.
    /// `static`/`class` 메서드는 클래스 메서드라 RN 이 인스턴스에서 찾는 목록에 없다.
    private func emitReactMethodIfExported(_ node: FunctionDeclSyntax) {
        let explicit = Self.hasAttribute("objc", in: node.attributes)
        guard let module = reactModules.last ?? nil,
              !Self.hasAttribute("nonobjc", in: node.attributes),
              explicit || !Self.isFilePrivate(node.modifiers),
              !node.modifiers.contains(where: { $0.name.text == "static" || $0.name.text == "class" }),
              module.exportsAllMembers || explicit
        else { return }
        let selector = Self.objectiveCName(in: node.attributes)
        let method = selector.map { String($0.prefix { $0 != ":" }) } ?? DeclarationCollector.unescaped(node.name.text)
        emit(.methodHandle, target: .reactNative, channel: .literal(module.name), method: .literal(method), at: node.name)
    }

    private static func isFilePrivate(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == "private" || $0.name.text == "fileprivate" }
    }

    static func hasAttribute(_ name: String, in attributes: AttributeListSyntax) -> Bool {
        attributes.contains { element in
            guard case let .attribute(attribute) = element else { return false }
            return attribute.attributeName.trimmedDescription == name
        }
    }

    // MARK: 공통

    private func pushType(_ name: String, node: some SyntaxProtocol) {
        let unescaped = DeclarationCollector.unescaped(name)
        typeNames.append(unescaped)
        pushDeclaration(name: unescaped, indexName: unescaped, node: node, qualified: typeNames.joined(separator: "."))
    }

    private func popType() {
        typeNames.removeLast()
        declarations.removeLast()
    }

    private func pushDeclaration(name: String, indexName: String, node: some SyntaxProtocol, qualified: String? = nil) {
        let base = DeclarationCollector.unescaped(name)
        declarations.append(
            EnclosingDeclaration(
                name: base,
                indexName: indexName,
                qualifiedName: qualified ?? (typeNames + [base]).joined(separator: "."),
                line: node.startLocation(converter: converter).line
            )
        )
    }

    private func emit(
        _ kind: BridgeFact.Kind,
        target: BridgeFact.Target,
        channel: ResolvedName?,
        method: ResolvedName? = nil,
        inferred: Bool = false,
        at node: some SyntaxProtocol
    ) {
        let location = node.startLocation(converter: converter)
        let fact = BridgeFact(
            kind: kind,
            target: target,
            channel: channel?.text,
            method: method?.text,
            isDynamic: (channel?.isDynamic ?? false) || (method?.isDynamic ?? false),
            isChannelInferred: inferred,
            location: SourceLocation(path: path, line: location.line, column: location.column)
        )
        facts.append(ScannedBridgeFact(fact: fact, declaration: declarations.last))
    }
}
