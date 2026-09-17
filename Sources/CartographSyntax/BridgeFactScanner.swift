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
    /// 같은 선언 안의 모든 handler closure 범위. message 이외의 Flutter handler도 제외 근거다.
    public let handlerScopes: [BridgeFact.HandlerScope]

    public init(
        fact: BridgeFact, declaration: EnclosingDeclaration?, handlerScopes: [BridgeFact.HandlerScope] = []
    ) {
        self.fact = fact
        self.declaration = declaration
        self.handlerScopes = handlerScopes
    }

}

/// 한 선언에 속한 모든 Flutter handler closure 범위.
public struct ScannedBridgeHandlerScopes: Hashable, Sendable {
    public let declaration: EnclosingDeclaration
    public let scopes: [BridgeFact.HandlerScope]

    public init(declaration: EnclosingDeclaration, scopes: [BridgeFact.HandlerScope]) {
        self.declaration = declaration
        self.scopes = scopes
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
    /// 선언 전체 범위. 등록부 바깥 reference를 구분할 때만 사용한다.
    public let start: CartographCore.SourceLocation?
    public let end: CartographCore.SourceLocation?

    public init(
        name: String, indexName: String, qualifiedName: String, line: Int,
        start: CartographCore.SourceLocation? = nil, end: CartographCore.SourceLocation? = nil
    ) {
        self.name = name
        self.indexName = indexName
        self.qualifiedName = qualifiedName
        self.line = line
        self.start = start
        self.end = end
    }
}

/// 파일 하나를 훑은 결과. 사실과, 사실로 만들지 못해 세기만 한 것.
public struct BridgeScanResult: Sendable, Equatable {
    public let facts: [ScannedBridgeFact]
    /// fact마다 복사하지 않고 declaration별로 한 번만 보존한 handler 범위.
    public let handlerScopes: [ScannedBridgeHandlerScopes]
    /// `FlutterEventChannel(name:)` 생성 수. 스트림 브리지는 이 형식의 대상이 아니라 세기만 한다.
    ///
    /// 세지 않으면 이벤트 채널만 쓰는 플러그인이 "브리지 없음" 으로 읽힌다.
    public let unscannedEventChannels: Int
    /// `FlutterBasicMessageChannel(name:)` / `BasicMessageChannel(name:)` 생성 수.
    ///
    /// Pigeon 이 만든 코드는 메서드 채널을 아예 쓰지 않는다. 세지 않으면 Pigeon 플러그인은
    /// 파이프라인을 다 돌고도 핸들러가 계속 죽은 코드로 보고된다.
    public let unscannedMessageChannels: Int
    /// 등록 채널은 알지만 본문을 읽지 못한 핸들러. nil 이 하나라도 있으면 채널 상한을 모른다.
    public let opaqueHandlerChannels: [String?]

    public init(
        facts: [ScannedBridgeFact], handlerScopes: [ScannedBridgeHandlerScopes] = [],
        unscannedEventChannels: Int = 0, unscannedMessageChannels: Int = 0, opaqueHandlerChannels: [String?] = []
    ) {
        self.facts = facts
        self.handlerScopes = handlerScopes
        self.unscannedEventChannels = unscannedEventChannels
        self.unscannedMessageChannels = unscannedMessageChannels
        self.opaqueHandlerChannels = opaqueHandlerChannels
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

    public func scan(source: String, path: String,
                     resolvedValues: [CartographCore.SourceLocation: String] = [:],
                     messages: Bool = false, events: Bool = false) -> BridgeScanResult {
        // 파서는 `channel = FlutterMethodChannel(…)` 과 `call.method == "x"` 를 접지 않은
        // SequenceExpr 로 남긴다. 연산자 우선순위로 접어야 대입과 비교가 보인다.
        // 접기 오류(알 수 없는 연산자)는 무시한다. 그 표현식만 못 읽을 뿐이다.
        let parsed = Parser.parse(source: source)
        let tree = OperatorTable.standardOperators.foldAll(parsed) { _ in }.as(SourceFileSyntax.self) ?? parsed
        let converter = SourceLocationConverter(fileName: path, tree: tree)

        // 두 번 걷는다. 상수와 채널 변수는 사용 지점보다 뒤에 선언될 수 있다
        // (프로퍼티는 아래, 사용은 위의 `init` 안). 1차 패스는 모으기만 하고 해석은
        // 전부 2차 패스에서 한다. 1차 패스에서 해석하면 아래에 있는 상수를 못 본다.
        let bindings = BindingCollector(converter: converter, resolvedValues: resolvedValues)
        bindings.walk(tree)

        let collector = BridgeFactCollector(converter: converter, bindings: bindings, path: path,
                                            messages: messages, events: events)
        collector.walk(tree)
        let handlerScopes = collector.handlerScopesByDeclaration.map { key, scopes in
            ScannedBridgeHandlerScopes(declaration: collector.declaration(for: key), scopes: scopes)
        }.sorted {
            let left = $0.declaration
            let right = $1.declaration
            let leftKey = [left.qualifiedName, String(left.line), left.start?.description ?? "", left.end?.description ?? ""]
                + $0.scopes.map { "\($0.start):\($0.end)" }
            let rightKey = [right.qualifiedName, String(right.line), right.start?.description ?? "", right.end?.description ?? ""]
                + $1.scopes.map { "\($0.start):\($0.end)" }
            return leftKey.joined(separator: "\u{0}") < rightKey.joined(separator: "\u{0}")
        }
        return BridgeScanResult(
            facts: collector.facts.sorted { $0.fact < $1.fact }, handlerScopes: handlerScopes,
            unscannedEventChannels: bindings.eventChannelCount,
            unscannedMessageChannels: bindings.messageChannelCount,
            opaqueHandlerChannels: collector.opaqueHandlerChannels
        )
    }
}

// MARK: - 이름 해석

/// 리터럴 또는 표현식으로 표현된 이름.
struct ResolvedName: Hashable {
    let text: String
    let isDynamic: Bool
    let channelPrefix: String?

    static func literal(_ text: String) -> ResolvedName {
        ResolvedName(text: text, isDynamic: false, channelPrefix: nil)
    }
    static func dynamic(_ text: String, channelPrefix: String? = nil) -> ResolvedName {
        ResolvedName(text: text, isDynamic: true, channelPrefix: channelPrefix)
    }
}

/// 이름 하나에 묶인 값. 문자열 리터럴이거나, 채널 생성자의 `name:` 인자다.
///
/// 채널 인자는 바인딩 시점의 문맥과 함께 저장하고 2차 패스에서 그 문맥으로 해석한다.
/// 1차 패스에서 해석하면 아래에 선언된 상수를 못 본다.
enum BoundValue: Equatable {
    case constant(expression: ExprSyntax, scopes: [Int], enclosingTypes: [String])
    case channel(argument: ExprSyntax, scopes: [Int], enclosingTypes: [String], kind: BridgeChannelKind)
    /// 이 파일이 선언한 타입의 인스턴스(`let instance = CameraPlugin()`).
    case instance(typeName: String)
    /// 리터럴도 채널도 아닌 값. 이 이름이 이 스코프에서 그 값을 가리키므로 바깥의 동명 상수를
    /// 대신 쓰면 안 된다. 그림자다.
    case opaque
    /// 선언은 알지만 아직 초기화 대입을 만나지 않았다. 계산 프로퍼티와 구분한다.
    case uninitialized

    static func == (lhs: BoundValue, rhs: BoundValue) -> Bool {
        switch (lhs, rhs) {
        case let (.constant(a, sa, ta), .constant(b, sb, tb)): a.id == b.id && sa == sb && ta == tb
        case let (.channel(a, sa, ta, ka), .channel(b, sb, tb, kb)):
            a.id == b.id && sa == sb && ta == tb && ka == kb
        case let (.instance(a), .instance(b)): a == b
        case (.opaque, .opaque), (.uninitialized, .uninitialized): true
        default: false
        }
    }
}

/// 파일 안의 문자열 상수와 채널 변수를 모은다.
///
/// 불변 별칭은 선언 문맥에서 제한된 깊이까지 따라간다. 가변 값·계산 프로퍼티·연산자는
/// 실행이나 타입 해석 없이 값을 확정할 수 없으므로 `dynamic` 으로 남긴다.
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
    /// `import ExpoModulesCore` 가 있는지. Expo DSL 인식의 파일 단위 관문이다.
    ///
    /// 이 import 없이 `class X: Module` 이나 `Name("…")` 를 보면 같은 이름의 무관한
    /// 선언일 수 있으므로 Expo 사실로 만들지 않는다.
    private(set) var importsExpoModulesCore = false
    /// `@ExpoModule` 을 달았거나 `Module` 을 상속한 타입의 이름. `extension X: Module`
    /// 처럼 익스텐션에서 준수를 선언한 경우도 포함한다.
    private(set) var expoModuleClasses: Set<String> = []
    /// `expoModuleClasses` 중 이 파일에 `class` 선언이 있는 이름. 익스텐션만으로
    /// Expo 가 표시된 타입은 클래스 방문이 아니라 익스텐션 방문에서 사실을 낸다.
    private(set) var expoClassDeclarations: Set<String> = []
    /// 이 파일에 `class` 선언이 있는 모든 타입 이름. 클래스가 보이는데 Expo 표시가
    /// 없으면 익스텐션의 DSL 호출을 그 타입의 모듈 증거로 쓰지 않기 위한 경계다.
    private(set) var classDeclarations: Set<String> = []
    /// 타입(또는 같은 파일 익스텐션)의 직속 멤버 `func definition` 들. 안쪽 타입 이름이 키다.
    ///
    /// Expo 의 모듈 이름(`Name`)·뷰(`View`)·함수(`Function` 계열) 정의는 이 본문
    /// 안의 결과 빌더 문장에만 있다. 다른 멤버의 동명 호출과 구분하려고 따로 모은다.
    private(set) var definitionFunctions: [String: [FunctionDeclSyntax]] = [:]
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
    /// 함수 키별 선언 수. 오버로드가 있으면 어느 선언인지 구분할 수 없어 위임 귀속을 멈춘다.
    private(set) var functionCounts: [String: Int] = [:]
    private var readableHandlers: Set<String> = []
    /// `FlutterMethodCall` 을 받는 함수의 키 → 인덱스 이름과 선언 타입 사슬.
    ///
    /// `call` 을 그대로 넘기는 한 홉 위임에서 호출자의 등록 채널을 풀 때 쓴다. 같은 이름에
    /// 오버로드가 있으면 마지막 것이 남으므로 쓰는 쪽에서 `functionCounts == 1` 을 확인한다.
    private(set) var methodCallFunctions: [String: (indexName: String, typeChain: String)] = [:]
    /// `FlutterMethodCall` 함수 키 → 그 인자의 본문 이름(`handle(_ call:)` 이면 `call`).
    private(set) var methodCallParams: [String: String] = [:]
    /// `FlutterMethodCall` 함수 키 → 그 인자의 위치와 외부 레이블. 위임 호출이
    /// `call` 을 정확히 그 자리에 넘기는지 2차 패스에서 대조한다.
    private(set) var methodCallSeats: [String: (index: Int, label: String)] = [:]
    /// `call` 을 넘기는 호출로 기록된 한 홉 위임 후보. 피호출 키 → 호출 지점들.
    ///
    /// `handle` 이 `Task { await handleAsync(call, result: r) }` 만 하는 모양이다.
    /// `call` 이 어느 인자 자리로 갔는지 함께 남겨, 피호출 함수의 `FlutterMethodCall`
    /// 인자 위치와 다른 자리로 간 호출은 2차 패스에서 걸러 낸다.
    /// 호출자가 아직 등록 채널로 확인되지 않아도 기록하고, 채널 판정은 2차 패스가 한다.
    private(set) var forwardedCalls: [String: [ForwardingCall]] = [:]
    /// `init` 안의 `self.x = 인자` 로만 채워지는 프로퍼티. `Type.x` → 호출 지점의 외부 레이블들.
    private(set) var initParamLabels: [String: Set<String>] = [:]
    /// 인자 아닌 값이나 `init` 밖 대입이 한 번이라도 온 프로퍼티는 주입이 아니다.
    private var nonInjectedProperties: Set<String> = []
    /// `peer.x = v` 처럼 `self` 아닌 수신자에 대입된 프로퍼티 이름. 수신자 타입을
    /// 모르니 같은 이름의 주입 추론은 전부 무효로 둔다 — 놓치는 쪽이 안전하다.
    private var nonInjectedNames: Set<String> = []
    /// `Type(…)`·`Type.init(…)`·`self.init(…)` 생성자 호출과 그 인자들.
    /// 주입 프로퍼티의 값을 호출 지점에서 푼다. 레이블 없는 호출도 남겨, 주입
    /// 레이블을 쓰지 않는 호출 지점이 있으면 증명이 무산되게 한다.
    private(set) var constructorCalls: [ConstructorCall] = []
    /// 위임 호출 지점 하나. `call` 이 넘어간 인자의 위치와 레이블을 남긴다.
    struct ForwardingCall {
        let caller: String
        let position: Int
        let label: String?
    }
    /// 생성자 호출 지점 하나. 레이블이 없는 인자는 `nil` 레이블로 남는다.
    struct ConstructorCall {
        let typeName: String
        let arguments: [(label: String?, expression: ExprSyntax)]
        let scopes: [Int]
        let enclosingTypes: [String]
    }
    /// `aᵢ = aᵢ₋₁ + aᵢ₋₁` 처럼 갈라지는 별칭 사슬에서 같은 바인딩 표현식을 다시
    /// 풀지 않기 위한 메모. 바인딩이 표현식을 선언 문맥과 함께 저장하므로 같은
    /// 노드면 같은 문맥이다.
    private var constantMemo: [SyntaxIdentifier: ResolvedName?] = [:]
    /// 지금 안에 있는 함수의 키. 지역 함수는 nil — 인덱스 정점이 없어 핸들러가 아니다.
    private var functionKeys: [String?] = []
    /// `functionKeys` 와 나란한, 그 함수가 여는 스코프의 `scopes` 안 위치.
    /// 본문 안 클로저가 `call` 같은 이름을 다시 선언했는지 잡는 데 쓴다.
    private var functionScopeIndices: [Int] = []
    /// 안쪽 이니셜라이저의 `본문 이름 → 외부 레이블`. `init` 안의 `self.x = 인자` 판별에 쓴다.
    private var initParamStack: [[String: String]] = []

    /// 지금 어느 타입 안에 있는지.
    private var typeNames: [String] = []
    /// 지금 어느 함수·클로저 안에 있는지. 바깥부터 쌓인다.
    private var scopes: [Int] = []

    private let converter: SourceLocationConverter
    private let resolvedValues: [CartographCore.SourceLocation: String]

    init(converter: SourceLocationConverter, resolvedValues: [CartographCore.SourceLocation: String]) {
        self.converter = converter
        self.resolvedValues = resolvedValues
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: 스코프 문맥

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        // `import ExpoModulesCore` 와 `import struct ExpoModulesCore.X` 를 함께 잡는다.
        if node.path.first?.name.text == "ExpoModulesCore" { importsExpoModulesCore = true }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        var key: String? = nil
        if !DeclarationCollector.isInsideBody(node) {
            if node.name.text == "definition", let type = typeNames.last {
                definitionFunctions[type, default: []].append(node)
            }
            let handlerKey = Self.handlerKey(DeclarationCollector.unescaped(node.name.text), enclosingTypes: typeNames)
            functionCounts[handlerKey, default: 0] += 1
            if node.body != nil && Self.takesMethodCall(node) {
                readableHandlers.insert(handlerKey)
                methodCallFunctions[handlerKey] = (
                    indexName: RuntimeSyntaxNames.indexName(node.name.text, parameters: node.signature.parameterClause.parameters),
                    typeChain: typeNames.joined(separator: ".")
                )
                let parameters = node.signature.parameterClause.parameters
                if let found = parameters.firstIndex(where: Self.isMethodCallParameter) {
                    let parameter = parameters[found]
                    let internalName = DeclarationCollector.unescaped((parameter.secondName ?? parameter.firstName).text)
                    if internalName != "_" { methodCallParams[handlerKey] = internalName }
                    let index = parameters.distance(from: parameters.startIndex, to: found)
                    methodCallSeats[handlerKey] = (index, DeclarationCollector.unescaped(parameter.firstName.text))
                }
            }
            key = handlerKey
        }
        functionKeys.append(key)
        functionScopeIndices.append(scopes.count)
        return pushScope(node)
    }
    override func visitPost(_: FunctionDeclSyntax) {
        scopes.removeLast(); functionKeys.removeLast(); functionScopeIndices.removeLast()
    }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        initParamStack.append(Self.initParamLabels(of: node))
        return pushScope(node)
    }
    override func visitPost(_: InitializerDeclSyntax) { scopes.removeLast(); initParamStack.removeLast() }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_: ClosureExprSyntax) { scopes.removeLast() }

    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_: AccessorBlockSyntax) { scopes.removeLast() }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        _ = pushScope(node)
        let kind = node.accessorSpecifier.text
        if let name = node.parameters?.name.text { shadow(name, isLocal: true) }
        else if ["set", "willSet"].contains(kind) { shadow("newValue", isLocal: true) }
        else if kind == "didSet" { shadow("oldValue", isLocal: true) }
        return .visitChildren
    }
    override func visitPost(_: AccessorDeclSyntax) { scopes.removeLast() }

    private func pushScope(_ node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        scopes.append(Self.scopeKey(node)); return .visitChildren
    }

    /// 함수·클로저를 구분하는 키. 두 패스가 같은 트리를 걸으므로 같은 노드에서 같은 값이다.
    static func scopeKey(_ node: some SyntaxProtocol) -> Int { node.position.utf8Offset }

    /// `init(global: g)` 의 본문 이름 `g` → 호출 지점 레이블 `global`.
    /// `init(_ x:)` 처럼 레이블이 없는 인자는 호출 지점에서 이름이 없어 못 따라간다.
    private static func initParamLabels(of node: InitializerDeclSyntax) -> [String: String] {
        var labels: [String: String] = [:]
        for parameter in node.signature.parameterClause.parameters where parameter.firstName.text != "_" {
            labels[DeclarationCollector.unescaped((parameter.secondName ?? parameter.firstName).text)] =
                DeclarationCollector.unescaped(parameter.firstName.text)
        }
        return labels
    }

    // MARK: 타입 문맥

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if let name = SyntaxAttributes.objectiveCName(in: node.attributes) {
            reactModules[node.name.text] = (name, SyntaxAttributes.has("objcMembers", in: node.attributes))
        }
        classDeclarations.insert(node.name.text)
        if isExpoModuleClass(node) {
            expoModuleClasses.insert(node.name.text)
            expoClassDeclarations.insert(node.name.text)
        }
        return pushType(node.name.text)
    }
    override func visitPost(_: ClassDeclSyntax) { typeNames.removeLast() }

    /// `@ExpoModule` 을 달았거나 `Module` 을 상속한 클래스인지.
    private func isExpoModuleClass(_ node: ClassDeclSyntax) -> Bool {
        guard importsExpoModulesCore else { return false }
        if SyntaxAttributes.has("ExpoModule", in: node.attributes) { return true }
        return Self.hasModuleInheritance(node.inheritanceClause)
    }

    /// 상속 절에 Expo `Module` 이 있는지.
    ///
    /// Expo 의 `Module` 은 `AnyModule & BaseModule` 타입 별칭이다. 상속 절의 마지막
    /// 점 구성 요소만 본다 — `MyModule` 이나 `ModuleFactory` 같은 무관한 이름은 걸러 낸다.
    private static func hasModuleInheritance(_ clause: InheritanceClauseSyntax?) -> Bool {
        clause?.inheritedTypes.contains {
            $0.type.trimmedDescription.split(separator: ".").last == "Module"
        } ?? false
    }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node.name.text) }
    override func visitPost(_: StructDeclSyntax) { typeNames.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node.name.text) }
    override func visitPost(_: EnumDeclSyntax) { typeNames.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node.name.text) }
    override func visitPost(_: ActorDeclSyntax) { typeNames.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // `extension X: Module` — 준수를 클래스가 아니라 익스텐션이 선언할 수 있다.
        if importsExpoModulesCore, Self.hasModuleInheritance(node.inheritanceClause) {
            expoModuleClasses.insert(node.extendedType.trimmedDescription)
        }
        return pushType(node.extendedType.trimmedDescription)
    }
    override func visitPost(_: ExtensionDeclSyntax) { typeNames.removeLast() }

    private func pushType(_ name: String) -> SyntaxVisitorContinueKind {
        let unescaped = DeclarationCollector.unescaped(name)
        declaredTypeNames.insert(unescaped)
        typeNames.append(unescaped)
        declaredTypeChains.insert(typeNames.joined(separator: "."))
        return .visitChildren
    }

    // MARK: 바인딩 수집

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return .visitChildren }
        let local = DeclarationCollector.isInsideBody(node)
        guard let value = node.initializer?.value else {
            shadow(name, isLocal: local, uninitialized: node.accessorBlock == nil)
            return .visitChildren
        }
        let declaration = node.parent?.parent?.as(VariableDeclSyntax.self)
        bind(name: DeclarationCollector.unescaped(name), to: value, isLocal: local,
             immutable: declaration?.bindingSpecifier.tokenKind == .keyword(.let) && node.accessorBlock == nil)
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        shadow((node.secondName ?? node.firstName).text, isLocal: true)
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        shadow((node.secondName ?? node.firstName).text, isLocal: true)
        return .visitChildren
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        shadow(node.name.text, isLocal: true)
        return .visitChildren
    }

    override func visit(_ node: ClosureCaptureSyntax) -> SyntaxVisitorContinueKind {
        shadow(node.name.text, isLocal: true)
        return .visitChildren
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        // if/guard let, for, switch와 튜플 패턴은 값을 모르지만 동명 바깥 상수를 가린다.
        if node.parent?.is(PatternBindingSyntax.self) != true { shadow(node.identifier.text, isLocal: true) }
        return .visitChildren
    }

    private func shadow(_ name: String, isLocal: Bool, uninitialized: Bool = false) {
        let name = DeclarationCollector.unescaped(name)
        guard name != "_" else { return }
        let key = isLocal ? Self.localKey(name, scope: scopes.last) : (typeNames + [name]).joined(separator: ".")
        bindings[key] = uninitialized && bindings[key] == nil ? .some(.uninitialized) : .some(nil)
    }

    /// `channel = FlutterMethodChannel(...)` 처럼 대입으로 채널을 만드는 경우. `init` 안이 흔하다.
    ///
    /// `self.name = "…"` 은 프로퍼티라 타입 키로, 본문 안의 `name = "…"` 은 지역 키로 간다.
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.operator.is(AssignmentExprSyntax.self) else { return .visitChildren }
        guard let name = Self.identifierName(of: node.leftOperand) else { return .visitChildren }
        let member = node.leftOperand.as(MemberAccessExprSyntax.self)
        if let member, !["self", "Self"].contains(member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text ?? "") {
            // `peer.x = v` — 수신자 타입은 모르지만 init 주입으로 본 같은 이름의
            // 프로퍼티가 초기화 밖에서 대입될 수 있다는 증거이므로 이름째로 무효화한다.
            shadow(name, isLocal: false)
            nonInjectedNames.insert(name)
            return .visitChildren
        }
        let key = assignmentKey(name, explicitMember: member != nil)
        noteInjection(key: key, value: node.rightOperand)
        bind(name: name, to: node.rightOperand, isLocal: false, bindingKey: key)
        return .visitChildren
    }

    /// `init` 안의 `self.x = 인자` 로만 채워지는 프로퍼티를 생성자 주입으로 기록한다.
    ///
    /// 지역 키(`#`)는 프로퍼티가 아니다. 인자 아닌 값이나 `init` 밖 대입이 한 번이라도
    /// 오면 그 프로퍼티는 호출 지점의 값이라고 할 수 없으므로 주입 기록을 지운다.
    private func noteInjection(key: String, value: ExprSyntax) {
        guard !key.contains("#") else { return }
        guard let labels = initParamStack.last,
              let reference = value.as(DeclReferenceExprSyntax.self),
              let label = labels[DeclarationCollector.unescaped(reference.baseName.text)]
        else {
            initParamLabels.removeValue(forKey: key)
            nonInjectedProperties.insert(key)
            return
        }
        guard !nonInjectedProperties.contains(key) else { return }
        initParamLabels[key, default: []].insert(label)
    }

    /// 대입은 새 지역 선언이 아니다. 기존 지역·프로퍼티에 합쳐 표기 차이와 클로저 변경을 놓치지 않는다.
    private func assignmentKey(_ name: String, explicitMember: Bool) -> String {
        if explicitMember { return (typeNames + [name]).joined(separator: ".") }
        for scope in scopes.reversed() {
            let key = Self.localKey(name, scope: scope)
            if bindings[key] != nil { return key }
        }
        for depth in stride(from: typeNames.count, through: 0, by: -1) {
            let key = (typeNames.prefix(depth) + [name]).joined(separator: ".")
            if bindings[key] != nil { return key }
        }
        return scopes.isEmpty ? (typeNames + [name]).joined(separator: ".") : Self.localKey(name, scope: scopes.last)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        switch Self.calleeName(of: node) {
        case BridgeChannels.eventChannel: eventChannelCount += 1
        case let name? where BridgeChannels.messageChannels.contains(name): messageChannelCount += 1
        default: break
        }
        recordHandlerReference(node)
        recordDelegate(node)
        recordForwarding(node)
        recordConstructorCall(node)
        return .visitChildren
    }

    /// 핸들러가 `call` 을 그대로 넘기는 한 홉 위임을 기록한다.
    ///
    /// `self.f(…)`·`f(…)` 만 본다 — 다른 수신자의 메서드는 이 파일의 함수가 아니다.
    /// 호출자의 `FlutterMethodCall` 파라미터가 인자로 그대로 참조돼야 같은 호출의 분기다.
    private func recordForwarding(_ call: FunctionCallExprSyntax) {
        guard let caller = functionKeys.last ?? nil,
              let callParam = methodCallParams[caller],
              let callee = Self.identifierName(of: call.calledExpression) else { return }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text != "self" { return }
        // 본문 안 클로저가 `call` 이름을 다시 선언했으면 이 참조는 핸들러의
        // 인자가 아니라 클로저의 것이다 — 철자만 보고 위임으로 세지 않는다.
        if let own = functionScopeIndices.last {
            for scope in scopes.dropFirst(own + 1) where bindings[Self.localKey(callParam, scope: scope)] != nil {
                return
            }
        }
        // `call` 이 넘어간 자리를 전부 남긴다 — 피호출 함수의 `FlutterMethodCall`
        // 인자가 어느 자리인지는 선언을 봐야 알고, 대조는 2차 패스가 한다.
        let seats = call.arguments.enumerated().compactMap { offset, argument -> (Int, String?)? in
            Self.unparenthesized(argument.expression).as(DeclReferenceExprSyntax.self)?.baseName.text == callParam
                ? (offset, argument.label?.text) : nil
        }
        guard !seats.isEmpty else { return }
        forwardedCalls[Self.handlerKey(callee, enclosingTypes: typeNames), default: []]
            .append(contentsOf: seats.map { ForwardingCall(caller: caller, position: $0.0, label: $0.1) })
    }

    /// `Plugin(label: x)` 형태의 생성자 호출 인자를 기록한다.
    /// `init` 안의 `self.x = label` 주입 프로퍼티를 이 호출 지점의 값으로 푼다.
    private func recordConstructorCall(_ call: FunctionCallExprSyntax) {
        let dotted: String
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "init", let base = member.base {
            if base.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
                // `self.init(…)` 위임 생성자도 같은 타입의 호출 지점이다.
                dotted = typeNames.joined(separator: ".")
            } else {
                // `Plugin.init(c: x)` 처럼 `.init` 을 명시한 호출도 그 타입의 지점이다.
                // `super.init`·인스턴스의 `.init` 은 마지막 대문자 검사에서 걸러진다.
                dotted = Self.dottedTypeName(of: base)
            }
        } else {
            dotted = Self.dottedTypeName(of: call.calledExpression)
        }
        guard dotted.split(separator: ".").last?.first?.isUppercase == true else { return }
        constructorCalls.append(ConstructorCall(
            typeName: dotted,
            arguments: call.arguments.map { ($0.label?.text, $0.expression) },
            scopes: scopes,
            enclosingTypes: typeNames
        ))
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

    /// `FlutterMethodCall` 파라미터. `FlutterMethodCall?` 과 `Flutter.FlutterMethodCall` 도 같은 타입이다.
    static func methodCallParameter(of node: FunctionDeclSyntax) -> FunctionParameterSyntax? {
        node.signature.parameterClause.parameters.first(where: isMethodCallParameter)
    }

    /// 파라미터 타입이 `FlutterMethodCall`(`?`·`!`·모듈 수식 포함)인지.
    private static func isMethodCallParameter(_ parameter: FunctionParameterSyntax) -> Bool {
        let type = parameter.type.trimmedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "?!"))
        return type == BridgeChannels.methodCall || type.hasSuffix("." + BridgeChannels.methodCall)
    }

    /// `FlutterMethodCall` 인자를 받는 함수인지. `FlutterPlugin.handle(_:result:)` 가 그렇다.
    static func takesMethodCall(_ node: FunctionDeclSyntax) -> Bool {
        methodCallParameter(of: node) != nil
    }

    /// 저장된 클로저·외부 함수·오버로드를 파일 안의 확정된 함수 본문으로 오인하지 않는다.
    func isReadableHandlerReference(_ expression: ExprSyntax, in context: Context) -> Bool {
        let expression = Self.unparenthesized(expression)
        let membersOnly: Bool
        if let member = expression.as(MemberAccessExprSyntax.self) {
            guard member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" else { return false }
            membersOnly = true
        } else {
            guard expression.is(DeclReferenceExprSyntax.self) else { return false }
            membersOnly = false
        }
        guard let name = Self.identifierName(of: expression),
              binding(named: name, in: context, membersOnly: membersOnly) == nil else { return false }
        let key = Self.handlerKey(name, enclosingTypes: context.enclosingTypes)
        return functionCounts[key] == 1 && readableHandlers.contains(key)
    }

    static func unparenthesized(_ expression: ExprSyntax) -> ExprSyntax {
        var value = expression
        while let tuple = value.as(TupleExprSyntax.self), tuple.elements.count == 1,
              let element = tuple.elements.first, element.label == nil, element.trailingComma == nil {
            value = element.expression
        }
        return value
    }

    static func isNilHandler(_ expression: ExprSyntax) -> Bool {
        var expression = Self.unparenthesized(expression)
        while let cast = expression.as(AsExprSyntax.self) { expression = Self.unparenthesized(cast.expression) }
        return expression.is(NilLiteralExprSyntax.self)
    }

    /// `receiver.setMethodCallHandler(method)` 의 `method` 가 메서드 참조면 기억한다.
    private func recordHandlerReference(_ call: FunctionCallExprSyntax) {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "setMethodCallHandler",
              let receiver = member.base, call.trailingClosure == nil,
              let rawArgument = call.arguments.first?.expression else { return }
        let argument = Self.unparenthesized(rawArgument)
        guard !argument.is(ClosureExprSyntax.self), !Self.isNilHandler(argument),
              let name = Self.identifierName(of: argument) else { return }
        // `self.handle` 이나 `handle` — 등록 지점을 감싸는 타입의 메서드다. 다른 수신자는 모른다.
        if let member = argument.as(MemberAccessExprSyntax.self),
           let base = member.base, base.as(DeclReferenceExprSyntax.self)?.baseName.text != "self" { return }
        handlerFunctions[Self.handlerKey(name, enclosingTypes: typeNames), default: []].append((receiver, scopes, typeNames))
    }

    private func bind(name: String, to value: ExprSyntax, isLocal: Bool,
                      immutable: Bool = false, bindingKey: String? = nil) {
        let bound: BoundValue
        if let construction = Self.channelConstruction(value) {
            bound = .channel(
                argument: construction.argument, scopes: scopes, enclosingTypes: typeNames, kind: construction.kind
            )
        } else if immutable, let reference = Self.identifierName(of: value),
                  let existing = binding(named: reference, in: Context(scopes: scopes, enclosingTypes: typeNames), membersOnly: false),
                  case let .channel(argument, boundScopes, boundTypes, kind)? = existing {
            bound = .channel(argument: argument, scopes: boundScopes, enclosingTypes: boundTypes, kind: kind)
        } else if let call = value.as(FunctionCallExprSyntax.self), let last = Self.calleeName(of: call),
                  last.first?.isUppercase == true, !BridgeChannels.all.contains(last) {
            // 대문자 호출은 생성자로 본다. 다른 모듈의 타입이면 어느 지역 타입 사슬에도 맞지 않는다.
            bound = .instance(typeName: Self.dottedTypeName(of: call.calledExpression))
        } else if immutable {
            bound = .constant(expression: value, scopes: scopes, enclosingTypes: typeNames)
        } else {
            bound = .opaque
        }
        let key = bindingKey ?? (isLocal
            ? Self.localKey(name, scope: scopes.last) : (typeNames + [name]).joined(separator: "."))
        if let existing = bindings[key] {
            if existing == .uninitialized { bindings[key] = bound }
            else if existing != bound { bindings[key] = .some(nil) }
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

    /// 채널 변수의 이름과 생성자 종류를 함께 푼다.
    func channelDetails(named name: String, in context: Context) -> (name: ResolvedName, kind: BridgeChannelKind)?? {
        channelDetails(named: name, in: context, depth: 0)
    }

    private func channelDetails(named name: String, in context: Context, depth: Int) -> (name: ResolvedName, kind: BridgeChannelKind)?? {
        // 지역 스코프에서 먼저 잡히면 그 이름은 지역 값이다 — 같은 이름의 주입
        // 프로퍼티 채널이 지역 파라미터로 새어 나오지 않게 멤버 단계를 타지 않는다.
        for scope in context.scopes.reversed() {
            guard let found = bindings[Self.localKey(name, scope: scope)] else { continue }
            return .some(channelValue(found))
        }
        for end in stride(from: context.enclosingTypes.count, through: 0, by: -1) {
            let key = (context.enclosingTypes.prefix(end) + [name]).joined(separator: ".")
            guard let found = bindings[key] else { continue }
            if let details = channelValue(found) { return .some(details) }
            if let injected = injectedChannel(key: key, depth: depth) { return .some(injected) }
            return .some(nil)
        }
        return nil
    }

    /// 바인딩이 채널 생성자면 푼 이름과 종류. 다른 값이거나 모르면 nil.
    private func channelValue(_ found: BoundValue?) -> (name: ResolvedName, kind: BridgeChannelKind)? {
        guard case let .channel(argument, scopes, types, kind)? = found else { return nil }
        return (resolveString(argument, in: Context(scopes: scopes, enclosingTypes: types)), kind)
    }

    /// `init` 안에서 `self.name = 인자` 로만 채워지는 프로퍼티 `key`(`A.B.name`)의
    /// 채널을 생성자 호출 지점에서 푼다.
    ///
    /// 그 타입의 호출 지점이 하나라도 주입 레이블을 쓰지 않거나(`Plugin()`,
    /// `Plugin(other:)` — 다른 이니셜라이저가 다른 값을 넣는 경로), 지점마다
    /// 값이 다르면 모른다.
    private func injectedChannel(key: String, depth: Int) -> (name: ResolvedName, kind: BridgeChannelKind)? {
        guard depth < 4,
              let dot = key.lastIndex(of: "."),
              let labels = initParamLabels[key] else { return nil }
        let chain = String(key[..<dot])
        let name = String(key[key.index(after: dot)...])
        guard !nonInjectedNames.contains(name) else { return nil }
        var resolved: [(name: ResolvedName, kind: BridgeChannelKind)] = []
        for call in constructorCalls
        where resolveTypeChain(call.typeName, from: call.enclosingTypes) == chain {
            guard let argument = call.arguments.first(where: { $0.label != nil && labels.contains($0.label!) })
            else { return nil }
            let callContext = Context(scopes: call.scopes, enclosingTypes: call.enclosingTypes)
            if let inline = channelConstruction(argument.expression, in: callContext) {
                resolved.append(inline)
            } else if let reference = Self.identifierName(of: argument.expression),
                      let details = channelDetails(named: reference, in: callContext, depth: depth + 1), let details {
                resolved.append(details)
            } else {
                return nil
            }
        }
        guard let first = resolved.first,
              resolved.allSatisfy({ $0.name == first.name && $0.kind == first.kind }) else { return nil }
        return first
    }

    /// 파일 안의 메서드 채널 생성 전부를 이름으로 푼 것. 핸들러 문맥 밖의 추측에 쓴다.
    ///
    /// 이벤트·메시지 채널을 섞으면 `FlutterMethodCall` 을 받는 함수에 다른 종류의
    /// 채널 이름이 붙거나, 메서드 채널이 있는 파일의 추측이 무산된다.
    func allChannelNames() -> [ResolvedName] {
        bindings.values.compactMap { value in
            guard case let .channel(argument, scopes, types, kind)? = value, kind == .method else { return nil }
            return resolveString(argument, in: Context(scopes: scopes, enclosingTypes: types))
        }
    }

    /// 지원하는 Flutter 채널 생성자 호출이면 그 채널 이름과 종류.
    func channelConstruction(_ expression: ExprSyntax, in context: Context) -> (name: ResolvedName, kind: BridgeChannelKind)? {
        Self.channelConstruction(expression).map {
            (resolveString($0.argument, in: context), $0.kind)
        }
    }

    static func channelConstruction(_ expression: ExprSyntax) -> (argument: ExprSyntax, kind: BridgeChannelKind)? {
        guard let call = expression.as(FunctionCallExprSyntax.self),
              let kind = channelKind(of: call.calledExpression),
              let argument = call.arguments.first(where: { $0.label?.text == "name" })
        else { return nil }
        return (argument.expression, kind)
    }

    static func channelKind(of callee: ExprSyntax) -> BridgeChannelKind? {
        let name: String?
        if let member = callee.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "init" {
            name = member.base.flatMap(identifierName(of:))
        } else {
            name = identifierName(of: callee)
        }
        return name.flatMap(BridgeChannels.kind(of:))
    }

    /// 문자열 표현식을 리터럴로 푼다. 못 풀면 원문 표현식을 `dynamic` 으로 돌려준다.
    ///
    /// - `name`: 감싸는 클로저·함수에서 바깥으로, 그다음 감싸는 타입에서 바깥으로, 마지막으로
    ///   파일 최상위. 리터럴이 아닌 값에 걸리면 거기서 멈춘다. 그 이름은 그 값이다.
    /// - `Self.name`, `self.name`: 현재 타입의 선언만. 상속이나 바깥 타입의 값을 추측하지 않는다.
    /// - `Type.name`: 이 파일이 선언하거나 확장한 `Type` 의 상수만.
    /// - `.name`(암시적 멤버): 수신자 타입은 `String` 이지 이 파일의 어떤 타입도 아니다.
    ///   구문만으로는 어느 확장의 상수인지 알 수 없으므로 `dynamic`.
    func resolveString(_ expression: ExprSyntax, in context: Context) -> ResolvedName {
        if let value = constantString(expression, in: context, remaining: 64) { return value }
        let position = converter.location(for: expression.positionAfterSkippingLeadingTrivia)
        let location = CartographCore.SourceLocation(path: position.file, line: position.line, column: position.column)
        if let value = resolvedValues[location] { return .literal(value) }
        return .dynamic(expression.trimmedDescription)
    }

    /// 순환·지나치게 긴 별칭은 중단한다. 문자열 `+` 연결 외의 연산자와 함수 호출 결과는
    /// 평가하지 않는다.
    private func constantString(_ expression: ExprSyntax, in context: Context, remaining: Int) -> ResolvedName? {
        guard remaining > 0 else { return nil }
        let expression = Self.unparenthesized(expression)
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            if let value = literal.representedLiteralValue { return .literal(value) }
            return Self.interpolatedPrefix(of: literal).map {
                .dynamic(literal.trimmedDescription, channelPrefix: $0)
            }
        }
        // `base + "/events"` — 앞쪽이 풀렸으면 그 값이 실행 시 접두사이고, 뒤쪽까지
        // 리터럴이면 합친 값이 리터럴이다. `.literal` 은 문자열 리터럴에서만 나오므로
        // 오버로드된 다른 타입의 `+` 는 여기 오지 않는다.
        if let infix = expression.as(InfixOperatorExprSyntax.self),
           let operation = infix.operator.as(BinaryOperatorExprSyntax.self), operation.operator.text == "+",
           let left = constantString(infix.leftOperand, in: context, remaining: remaining - 1) {
            if !left.isDynamic,
               let right = constantString(infix.rightOperand, in: context, remaining: remaining - 1), !right.isDynamic {
                // 증명 가능해도 채널 이름이 될 수 없는 크기는 만들지 않는다 —
                // `aᵢ = aᵢ₋₁ + aᵢ₋₁` 사슬은 결과가 2ⁿ 배로 커진다.
                guard left.text.count + right.text.count <= 4096 else { return nil }
                return .literal(left.text + right.text)
            }
            if let prefix = left.isDynamic ? left.channelPrefix : left.text {
                return .dynamic(expression.trimmedDescription, channelPrefix: prefix)
            }
        }
        guard case let .constant(value, scopes, types)?? = constantBinding(for: expression, in: context) else { return nil }
        // 같은 바인딩 표현식을 두 번째 풀 때는 저장된 답을 쓴다 — 별칭이 갈라지는
        // 사슬에서 메모가 없으면 재귀가 지수로 불어난다.
        if let memoized = constantMemo[value.id] { return memoized }
        let resolved = constantString(value, in: Context(scopes: scopes, enclosingTypes: types), remaining: remaining - 1)
        constantMemo[value.id] = resolved
        return resolved
    }

    /// 보간 문자열의 첫 리터럴 세그먼트를 실행 시 문자열 값으로 디코드한다.
    private static func interpolatedPrefix(of literal: StringLiteralExprSyntax) -> String? {
        guard literal.segments.contains(where: { $0.as(ExpressionSegmentSyntax.self) != nil }) else { return nil }
        let leading = literal.segments.prefix { $0.as(StringSegmentSyntax.self) != nil }
        guard !leading.isEmpty else { return nil }
        let segments = StringLiteralSegmentListSyntax(Array(leading))
        let prefix = StringLiteralExprSyntax(
            openingPounds: literal.openingPounds,
            openingQuote: literal.openingQuote,
            segments: segments,
            closingQuote: literal.closingQuote,
            closingPounds: literal.closingPounds
        )
        return prefix.representedLiteralValue
    }

    private func constantBinding(for expression: ExprSyntax, in context: Context) -> BoundValue?? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return binding(named: DeclarationCollector.unescaped(reference.baseName.text), in: context, membersOnly: false)
        }
        guard let member = expression.as(MemberAccessExprSyntax.self),
              let base = member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text
        else { return nil }
        let name = DeclarationCollector.unescaped(member.declName.baseName.text)
        if base == "Self" || base == "self" {
            guard !context.enclosingTypes.isEmpty else { return nil }
            return bindings[(context.enclosingTypes + [name]).joined(separator: ".")]
        }
        let type = DeclarationCollector.unescaped(base)
        guard declaredTypeNames.contains(type),
              binding(named: type, in: context, membersOnly: false) == nil else { return nil }
        return bindings[type + "." + name]
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
    private(set) var opaqueHandlerChannels: [String?] = []
    /// Flutter 가 Swift 쪽에 제공하는 채널 타입 이름.
    private(set) var facts: [ScannedBridgeFact] = []
    private(set) var handlerScopesByDeclaration: [String: [BridgeFact.HandlerScope]] = [:]
    private var declarationsByKey: [String: EnclosingDeclaration] = [:]
    private let converter: SourceLocationConverter
    private let bindings: BindingCollector
    private let path: String
    private let messages: Bool
    /// `true`면 `setStreamHandler` 만 사실로 낸다. MethodChannel 사실은 버전 1 문서의 것이다.
    private let events: Bool

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
    /// Expo `Module` 클래스(또는 그 익스텐션) 안에 있으면 해석된 모듈 이름과 매크로 형태 여부.
    private var expoModules: [(name: ResolvedName, viaMacro: Bool)?] = []
    /// 익스텐션 방문에서 Expo 사실을 이미 낸 타입. `extension X: Module` + `extension X`
    /// 처럼 같은 타입의 익스텐션이 여러 개여도 모듈 사실을 한 번만 내기 위한 메모다.
    private var emittedExpoExtensionTypes: Set<String> = []
    /// `let m = call.method` 로 메서드 이름을 담아 둔 지역 변수들. 함수·클로저마다 한 층.
    ///
    /// `switch m` 을 못 알아보면 그 핸들러의 메서드가 전부 사라진다. 실제 플러그인에서
    /// 드물지 않은 형태다. 파일 전역으로 두면 한 함수의 별칭이 다른 함수의 무관한 `m` 을
    /// 메서드 이름으로 위장시킨다.
    private var aliasScopes: [Set<String>] = [[]]
    /// 지금 어느 함수 본문 안에 있는지. `BindingCollector` 와 같은 키다.
    private var scopes: [Int] = []

    init(converter: SourceLocationConverter, bindings: BindingCollector, path: String,
         messages: Bool, events: Bool = false) {
        self.converter = converter
        self.bindings = bindings
        self.path = path
        self.messages = messages
        self.events = events
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
        let expo = expoModuleInfo(of: node)
        expoModules.append(expo.map { ($0.name, $0.viaMacro) })
        if let expo {
            emit(.moduleExport, target: .reactNative, channel: expo.name, mechanism: .expo, at: node.name)
            emitExpoDSL(moduleName: expo.name, extracted: expo.extracted)
        }
        return .visitChildren
    }
    override func visitPost(_: ClassDeclSyntax) { popType(); reactModules.removeLast(); expoModules.removeLast() }

    // 중첩 타입은 바깥 클래스의 Objective-C 노출을 물려받지 않는다.
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, node: node); reactModules.append(nil); expoModules.append(nil); return .visitChildren
    }
    override func visitPost(_: StructDeclSyntax) { popType(); reactModules.removeLast(); expoModules.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, node: node); reactModules.append(nil); expoModules.append(nil); return .visitChildren
    }
    override func visitPost(_: EnumDeclSyntax) { popType(); reactModules.removeLast(); expoModules.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, node: node); reactModules.append(nil); expoModules.append(nil); return .visitChildren
    }
    override func visitPost(_: ActorDeclSyntax) { popType(); reactModules.removeLast(); expoModules.removeLast() }

    /// `@objc(Name)` 클래스의 익스텐션에 둔 `@objc` 메서드도 JS 에 보인다.
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let typeName = DeclarationCollector.unescaped(node.extendedType.trimmedDescription)
        pushType(typeName, node: node)
        // `private extension` 의 멤버는 전부 private 이라 Objective-C 에 보이지 않는다.
        let module = Self.isFilePrivate(node.modifiers) ? nil : bindings.reactModules[typeName].map {
            (name: $0.name, exportsAllMembers: $0.exportsAllMembers || SyntaxAttributes.has("objcMembers", in: node.attributes))
        }
        reactModules.append(module)
        // 이 파일에 `class` 선언이 없는 Expo 타입 — `extension X: Module` 준수나
        // `func definition` 본문의 DSL 호출이 증거다. 클래스를 본 타입은 클래스 방문이 낸다.
        // DSL 증거 경로도 import 게이트를 요구하고, 클래스 선언이 보이는 비-Expo 타입의
        // `definition` 은 증거로 쓰지 않는다. 같은 타입의 익스텐션이 여러 개여도 한 번만 낸다.
        if !Self.isFilePrivate(node.modifiers),
           bindings.importsExpoModulesCore,
           !bindings.expoClassDeclarations.contains(typeName),
           emittedExpoExtensionTypes.insert(typeName).inserted {
            let bodies = bindings.definitionFunctions[typeName] ?? []
            let extracted = bodies.map { (body: $0, dsl: ExpoDefinitionCollector.collect($0)) }
            let marked = bindings.expoModuleClasses.contains(typeName)
            if marked || (!bindings.classDeclarations.contains(typeName)
                && extracted.contains(where: { !$0.dsl.isEmpty })) {
                let fallback: ResolvedName = bodies.isEmpty ? .dynamic(typeName) : .literal(typeName)
                let moduleName = expoModuleName(extracted: extracted, defaultName: fallback)
                emit(.moduleExport, target: .reactNative, channel: moduleName, mechanism: .expo, at: node.extendedType)
                emitExpoDSL(moduleName: moduleName, extracted: extracted)
            }
        }
        expoModules.append(nil)
        return .visitChildren
    }
    override func visitPost(_: ExtensionDeclSyntax) { popType(); reactModules.removeLast(); expoModules.removeLast() }

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
        if BindingCollector.takesMethodCall(node) { methodCallFunctionDepth += 1 }
        if let channel = referencedHandlerChannel(of: node) { handlerChannels.append(channel) }
        emitReactMethodIfExported(node)
        emitExpoMethodIfMacroMember(node)
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) {
        scopes.removeLast(); aliasScopes.removeLast()
        guard !DeclarationCollector.isInsideBody(node) else { return }
        declarations.removeLast()
        if BindingCollector.takesMethodCall(node) { methodCallFunctionDepth -= 1 }
        if referencedHandlerChannel(of: node) != nil { handlerChannels.removeLast() }
    }

    /// 이 함수가 어느 채널의 핸들러인지, 등록 호출이 말해 준 것.
    ///
    /// 셋 중 하나다. `setMethodCallHandler(handleCall)` 로 메서드 참조가 넘겨졌거나,
    /// 이 함수가 `addMethodCallDelegate(instance, channel:)` 로 등록된 타입의
    /// `handle(_:result:)` 이거나, 그런 핸들러가 `call` 을 그대로 넘기는 한 홉
    /// 위임의 대상이거나. 모두 추측이 아니다.
    private func referencedHandlerChannel(of node: FunctionDeclSyntax) -> ResolvedName?? {
        // 메서드 참조든 델리게이트든, 핸들러는 FlutterMethodCall 을 받는 함수다. 아니면 동명의
        // 무관한 함수라 `request.method == "DELETE"` 가 이 채널의 사실로 나간다.
        guard BindingCollector.takesMethodCall(node) else { return nil }
        let name = DeclarationCollector.unescaped(node.name.text)
        let key = BindingCollector.handlerKey(name, enclosingTypes: typeNames)
        if let entries = bindings.handlerFunctions[key] {
            return .some(Self.single(entries.compactMap {
                resolveChannel($0.receiver, in: .init(scopes: $0.scopes, enclosingTypes: $0.enclosingTypes))?.name
            }))
        }
        // FlutterPlugin 이 요구하는 것은 정확히 `handle(_:result:)` 다. 다른 오버로드는 아니다.
        if Self.indexName(name, parameters: node.signature.parameterClause.parameters) == "handle(_:result:)" {
            let chain = typeNames.joined(separator: ".")
            let registrations = bindings.delegateRegistrations.filter {
                bindings.resolveTypeChain($0.typeName, from: $0.enclosingTypes) == chain
            }
            if !registrations.isEmpty {
                return .some(Self.single(registrations.compactMap {
                    resolveChannel($0.channel, in: .init(scopes: $0.scopes, enclosingTypes: $0.enclosingTypes))?.name
                }))
            }
        }
        // `handle` → `handleAsync` 처럼 `call` 을 그대로 넘기는 한 홉 위임. 기록된 한 단계만
        // 보며 호출 그래프를 재귀로 쫓지 않는다. 같은 이름에 선언이 여럿이면 어느 것이
        // 호출자인지 몰라 귀속하지 않는다.
        guard bindings.functionCounts[key] == 1,
              let seat = bindings.methodCallSeats[key],
              let calls = bindings.forwardedCalls[key], !calls.isEmpty else { return nil }
        // `call` 이 이 함수의 `FlutterMethodCall` 자리와 다른 위치·레이블로 넘어간
        // 호출은 위임이 아니다 — 그 자리의 인자가 분기 대상이어야 같은 호출이다.
        let callers = Set(calls.compactMap { entry -> String? in
            let labelMatches = entry.label == nil ? seat.label == "_" : entry.label == seat.label
            return labelMatches && entry.position == seat.index ? entry.caller : nil
        })
        guard !callers.isEmpty else { return nil }
        let proven = callers.sorted().compactMap {
            bindings.functionCounts[$0] == 1 ? recordedChannel(of: $0) : nil
        }
        guard !proven.isEmpty else { return nil }
        // 호출자마다 증명된 채널이 있고 전부 같을 때만 계승한다.
        return .some(proven.count == callers.count ? Self.single(proven) : nil)
    }

    /// 등록 호출이 `key` 함수에 물어 준 채널. 메서드 참조와 델리게이트 등록 둘 다 본다.
    ///
    /// 근거가 없으면 nil, 있으면 푼 채널이 전부 같을 때만 그 채널이다.
    private func recordedChannel(of key: String) -> ResolvedName? {
        var channels = (bindings.handlerFunctions[key] ?? []).compactMap {
            resolveChannel($0.receiver, in: .init(scopes: $0.scopes, enclosingTypes: $0.enclosingTypes))?.name
        }
        if let function = bindings.methodCallFunctions[key], function.indexName == "handle(_:result:)" {
            channels += bindings.delegateRegistrations.filter {
                bindings.resolveTypeChain($0.typeName, from: $0.enclosingTypes) == function.typeChain
            }.compactMap {
                resolveChannel($0.channel, in: .init(scopes: $0.scopes, enclosingTypes: $0.enclosingTypes))?.name
            }
        }
        return channels.isEmpty ? nil : Self.single(channels)
    }

    /// 등록이 여럿이면 푼 채널 이름이 전부 같을 때만 그 채널이다. 다르면 모른다.
    ///
    /// 텍스트로 비교하면 스코프가 다른 동명 변수(`let channel` 둘)가 같은 채널로 읽힌다.
    private static func single(_ names: [ResolvedName]) -> ResolvedName? {
        Set(names).count == 1 ? names.first : nil
    }

    /// 클로저마다 한 층. 지역 상수와 별칭은 그것을 선언한 클로저 안에서만 보인다.
    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(BindingCollector.scopeKey(node)); aliasScopes.append([]); return .visitChildren
    }
    override func visitPost(_: AccessorBlockSyntax) { scopes.removeLast(); aliasScopes.removeLast() }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(BindingCollector.scopeKey(node)); aliasScopes.append([]); return .visitChildren
    }
    override func visitPost(_: AccessorDeclSyntax) { scopes.removeLast(); aliasScopes.removeLast() }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(BindingCollector.scopeKey(node)); aliasScopes.append([]); return .visitChildren
    }
    override func visitPost(_: ClosureExprSyntax) { scopes.removeLast(); aliasScopes.removeLast() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        pushDeclaration(
            name: "init",
            indexName: Self.indexName("init", parameters: node.signature.parameterClause.parameters),
            node: node
        )
        scopes.append(BindingCollector.scopeKey(node)); aliasScopes.append([])
        return .visitChildren
    }
    override func visitPost(_: InitializerDeclSyntax) {
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
        RuntimeSyntaxNames.indexName(base, parameters: parameters)
    }

    // MARK: Flutter

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return .visitChildren }
        let isNil = node.arguments.first.map { BindingCollector.isNilHandler($0.expression) } ?? false
        if events, member.declName.baseName.text == "setStreamHandler", !isNil {
            let registration = registeredChannel(of: node, receiver: member.base)
            // 다른 채널 종류로 증명된 수신자는 스트림 등록이 아니다. 미증명 수신자는
            // 메시지 경로와 같이 동적 이름의 사실로 남긴다 — `resolveChannel` 의 `.method`
            // 기본값은 "method 채널로 증명됨"이 아니라 "못 풂"이라 섞으면 안 된다.
            if let proven = provenChannelKind(of: node, receiver: member.base), proven != .event {
                return .visitChildren
            }
            let channelName = registration.flatMap { $0.kind == .event ? $0.name : nil }
                ?? .dynamic(member.base?.trimmedDescription ?? "setStreamHandler")
            emit(.streamHandle, target: .flutter, channel: channelName, at: node)
            return .visitChildren
        }
        if messages, member.declName.baseName.text == "setMessageHandler", !isNil {
            let closure = Self.handlerClosure(of: node)
            // 수신자를 못 풀어도 범위는 기록한다. 빠뜨리면 그 클로저 안의 참조가
            // 다른 핸들러의 공통 등록 근거로 오염되고 목록은 몰래 불완전해진다.
            recordHandlerScope(closure)
            let registration = registeredChannel(of: node, receiver: member.base)
            // MethodChannel 에는 이 메서드가 없다. 풀지 못한 수신자도 메시지 채널로 본다.
            // 이름이 없다고 사실을 버리면 isthmus 가 핸들러 존재 자체를 모른다.
            let channelName = registration.flatMap { $0.kind == .message ? $0.name : nil }
                ?? .dynamic(member.base?.trimmedDescription ?? "setMessageHandler")
            emit(
                .messageHandle, target: .flutter, channel: channelName,
                handlerScope: handlerScope(of: closure), at: node
            )
            return .visitChildren
        }
        guard BridgeChannels.handlerRegistrationMethods.contains(member.declName.baseName.text), !isNil else {
            return .visitChildren
        }

        recordHandlerScope(Self.handlerClosure(of: node))
        let registration = registeredChannel(of: node, receiver: member.base)
        emit(.channelRegister, target: .flutter, channel: registration?.name, at: node)

        // 핸들러 클로저 안의 `case "…"` 는 이 채널의 메서드다. 클로저를 방문하는 동안만
        // 채널을 스택에 올린다. 클로저가 없으면(델리게이트 등록) 올릴 것이 없다.
        guard let closure = Self.handlerClosure(of: node) else {
            if member.declName.baseName.text == "setMethodCallHandler",
               let argument = node.arguments.first?.expression, !bindings.isReadableHandlerReference(argument, in: context) {
                opaqueHandlerChannels.append(registration?.name.isDynamic == false ? registration?.name.text : nil)
            }
            return .visitChildren
        }
        handlerChannels.append(registration?.name)
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
    private func registeredChannel(
        of call: FunctionCallExprSyntax, receiver: ExprSyntax?
    ) -> (name: ResolvedName, kind: BridgeChannelKind)? {
        if let argument = call.arguments.first(where: { $0.label?.text == "channel" }) {
            return resolveChannel(argument.expression)
        }
        guard let receiver else { return nil }
        return resolveChannel(receiver)
    }

    /// 채널 표현식을 이름으로 푼다. 인라인 생성, 변수, 그 밖의 표현식 순으로 본다.
    private func resolveChannel(_ expression: ExprSyntax) -> (name: ResolvedName, kind: BridgeChannelKind)? {
        resolveChannel(expression, in: context)
    }

    /// 채널 생성자나 그에 묶인 변수로 종류가 증명될 때만 그 종류. 증명이 없으면 nil —
    /// `resolveChannel` 은 못 푼 표현식에 `.method` 기본값을 붙이므로 "다른 종류로
    /// 증명됨"과 "못 풂"을 그 반환값으로는 구분할 수 없다.
    private func provenChannelKind(of call: FunctionCallExprSyntax, receiver: ExprSyntax?) -> BridgeChannelKind? {
        // 수신자를 먼저 본다. `channel:` 인자가 수신자보다 앞서면, 수신자가 다른 종류로
        // 증명된 호출에서도 인자 쪽 종류가 이겨 스트림 사실이 남을 수 있다.
        for expression in [receiver, call.arguments.first(where: { $0.label?.text == "channel" })?.expression] {
            guard let expression else { continue }
            if let inline = bindings.channelConstruction(expression, in: context) { return inline.kind }
            if let name = BindingCollector.identifierName(of: expression),
               let bound = bindings.channelDetails(named: name, in: context), let bound {
                return bound.kind
            }
        }
        return nil
    }

    private func resolveChannel(
        _ expression: ExprSyntax, in context: BindingCollector.Context
    ) -> (name: ResolvedName, kind: BridgeChannelKind)? {
        if let inline = bindings.channelConstruction(expression, in: context) { return inline }
        if let name = BindingCollector.identifierName(of: expression), let bound = bindings.channelDetails(named: name, in: context) {
            return bound ?? (name: .dynamic(expression.trimmedDescription), kind: .method)
        }
        return (name: .dynamic(expression.trimmedDescription), kind: .method)
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

    private func handlerScope(of closure: ClosureExprSyntax?) -> BridgeFact.HandlerScope? {
        guard let closure else { return nil }
        // 범위는 `in` 뒤의 본문이다. `{ [s = f()] … in }` 의 캡처 초기화식은
        // 클로저 생성 시 한 번 실행되므로 메시지마다 도는 핸들러 근거가 아니다.
        let anchor = closure.signature?.inKeyword ?? closure.leftBrace
        let start = anchor.startLocation(converter: converter)
        let end = closure.rightBrace.startLocation(converter: converter)
        return BridgeFact.HandlerScope(
            start: SourceLocation(path: path, line: start.line, column: start.column),
            end: SourceLocation(path: path, line: end.line, column: end.column),
            complete: false
        )
    }

    func declaration(for key: String) -> EnclosingDeclaration {
        declarationsByKey[key]!
    }

    private static func declarationKey(_ declaration: EnclosingDeclaration) -> String {
        guard let start = declaration.start, let end = declaration.end else {
            return "\(declaration.qualifiedName)#\(declaration.line)"
        }
        return "\(start.path)#\(start.line):\(start.column)-\(end.line):\(end.column)"
    }

    private func recordHandlerScope(_ closure: ClosureExprSyntax?) {
        guard let scope = handlerScope(of: closure), let declaration = declarations.last else { return }
        let key = Self.declarationKey(declaration)
        declarationsByKey[key] = declaration
        handlerScopesByDeclaration[key, default: []].append(scope)
    }

    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        guard let switchExpression = Self.enclosingSwitch(of: node),
              isMethodNameExpression(switchExpression.subject),
              case let .case(label) = node.label,
              let (channel, inferred) = currentHandlerChannel
        else { return .visitChildren }
        // case 절 범위가 이 메서드의 분기 근거다. 같은 절의 여러 패턴은 같은 범위를 나누고,
        // 인덱스 귀속은 그 안의 참조만 이 분기로 본다.
        let scope = sourceScope(from: node.positionAfterSkippingLeadingTrivia, to: node.endPosition)
        for item in label.caseItems {
            guard let expression = item.pattern.as(ExpressionPatternSyntax.self)?.expression else { continue }
            emit(
                .methodHandle, target: .flutter, channel: channel,
                method: bindings.resolveString(expression, in: context),
                handlerScope: scope, inferred: inferred, at: item
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
            // 분기 범위는 그 조건을 단 `if`의 then 본문이다. 조건식 안의 `==`가 아니라
            // 본문 안의 다른 `==`이면 스코프로 쓰지 않는다.
            emit(
                .methodHandle, target: .flutter, channel: channel,
                method: bindings.resolveString(value, in: context),
                handlerScope: enclosingIfBodyScope(of: node), inferred: inferred, at: value
            )
            break
        }
        return .visitChildren
    }

    /// 절대 위치 두 개를 `HandlerScope` 로 옮긴다.
    private func sourceScope(from start: AbsolutePosition, to end: AbsolutePosition) -> BridgeFact.HandlerScope {
        let first = converter.location(for: start)
        let last = converter.location(for: end)
        return BridgeFact.HandlerScope(
            start: SourceLocation(path: path, line: first.line, column: first.column),
            end: SourceLocation(path: path, line: last.line, column: last.column),
            complete: false
        )
    }

    /// 이 비교가 조건인 가장 가까운 `if`의 then 본문 범위. 조건이 아닌 곳의 `==`는 nil.
    private func enclosingIfBodyScope(of node: some SyntaxProtocol) -> BridgeFact.HandlerScope? {
        var current = node.parent
        while let syntax = current {
            if let ifExpression = syntax.as(IfExprSyntax.self) {
                // then 본문이 이 비교의 참을 요구할 때만 분기 근거다. `!(x == "a")`나
                // `x == "a" || y` 처럼 조건 요소가 이 `==` 자체가 아니면 본문 실행이
                // 그 메서드를 보장하지 않으므로 근거를 붙이지 않는다.
                let isPositiveCondition = ifExpression.conditions.contains { element in
                    guard case let .expression(condition) = element.condition else { return false }
                    return Self.unparenthesized(condition).id == node.id
                }
                guard isPositiveCondition else { return nil }
                return sourceScope(
                    from: ifExpression.body.positionAfterSkippingLeadingTrivia,
                    to: ifExpression.body.endPosition
                )
            }
            current = syntax.parent
        }
        return nil
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

    /// `@objc(Name)` 클래스 안의 `@objc` 메서드는 JS 가 `NativeModules.Name.method()` 로 부른다.
    /// 클래스가 `@objcMembers` 면 표식 없는 메서드도 노출되지만, `@nonobjc` 는 아니고,
    /// `private`/`fileprivate` 은 명시적 `@objc` 가 있을 때만(SE-0186) Objective-C 에 보인다.
    /// `static`/`class` 메서드는 클래스 메서드라 RN 이 인스턴스에서 찾는 목록에 없다.
    private func emitReactMethodIfExported(_ node: FunctionDeclSyntax) {
        let explicit = SyntaxAttributes.has("objc", in: node.attributes)
        guard let module = reactModules.last ?? nil,
              !SyntaxAttributes.has("nonobjc", in: node.attributes),
              explicit || !Self.isFilePrivate(node.modifiers),
              !node.modifiers.contains(where: { $0.name.text == "static" || $0.name.text == "class" }),
              module.exportsAllMembers || explicit
        else { return }
        let selector = SyntaxAttributes.objectiveCName(in: node.attributes)
        let method = selector.map { String($0.prefix { $0 != ":" }) } ?? DeclarationCollector.unescaped(node.name.text)
        emit(.methodHandle, target: .reactNative, channel: .literal(module.name), method: .literal(method), at: node.name)
    }

    /// `@ExpoModule` 매크로 모듈의 `@JS` 멤버는 JS 가 부르는 메서드다.
    ///
    /// `@JS("name")` 첫 인자가 이름이고 생략하면 함수 이름이다. `@JS(.concurrent)` 처럼
    /// 선행 점 인자는 `JSOptions` 라 이름이 아니다. `method-handle` 은 이름 경계 사실이
    /// 아니라 mechanism 을 싣지 않는다.
    private func emitExpoMethodIfMacroMember(_ node: FunctionDeclSyntax) {
        guard let expo = expoModules.last ?? nil, expo.viaMacro,
              SyntaxAttributes.has("JS", in: node.attributes)
        else { return }
        let method: ResolvedName
        if let argument = SyntaxAttributes.firstArgumentExpression(of: "JS", in: node.attributes) {
            let resolved = bindings.resolveString(argument, in: context)
            // `@JS(.concurrent)`·`@JS(JSMethodOptions.concurrent)` 처럼 옵션 인자는 이름이 아니다.
            let memberAccess = argument.as(MemberAccessExprSyntax.self)
            let optionBases: Set<String> = ["JSOptions", "JSMethodOptions"]
            let isOption = resolved.isDynamic
                && (memberAccess?.base == nil
                    || optionBases.contains(memberAccess?.base?.trimmedDescription ?? ""))
            method = isOption ? .literal(DeclarationCollector.unescaped(node.name.text)) : resolved
        } else {
            method = .literal(DeclarationCollector.unescaped(node.name.text))
        }
        emit(.methodHandle, target: .reactNative, channel: expo.name, method: method, at: node.name)
    }

    private static func isFilePrivate(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == "private" || $0.name.text == "fileprivate" }
    }

    // MARK: Expo Modules

    /// `func definition` 본문 하나에서 모은 DSL 호출.
    private typealias ExtractedDefinition = (body: FunctionDeclSyntax, dsl: ExpoDefinitionCollector.Result)

    /// `class X: Module` 또는 `@ExpoModule class X` — Expo Modules DSL 모듈이면
    /// 해석된 모듈 이름과 `func definition` 본문에서 모은 DSL 호출들을 돌려준다.
    ///
    /// 이름 규칙은 Expo 소스와 같다 — `@ExpoModule("…")` 인자, `Name("…")` 의 마지막
    /// 호출, 그것도 없으면 클래스 이름(`String(describing: type)`). `func definition`
    /// 을 이 파일에서 못 찾으면 보지 못한 `Name` 이 이름을 덮을 수 있어 동적으로 둔다.
    private func expoModuleInfo(of node: ClassDeclSyntax)
        -> (name: ResolvedName, viaMacro: Bool, extracted: [ExtractedDefinition])?
    {
        // `class X` + `extension X: Module` 처럼 준수가 익스텐션에 있으면 익스텐션 방문이 낸다.
        guard bindings.expoClassDeclarations.contains(node.name.text) else { return nil }
        let className = DeclarationCollector.unescaped(node.name.text)
        if SyntaxAttributes.has("ExpoModule", in: node.attributes) {
            let name = SyntaxAttributes.firstArgumentExpression(of: "ExpoModule", in: node.attributes)
                .map { bindings.resolveString($0, in: context) }
                ?? .literal(className)
            return (name, true, [])
        }
        let bodies = bindings.definitionFunctions[className] ?? []
        if bodies.isEmpty {
            return (.dynamic(className), false, [])
        }
        let extracted: [ExtractedDefinition] = bodies.map { ($0, ExpoDefinitionCollector.collect($0)) }
        return (expoModuleName(extracted: extracted, defaultName: .literal(className)), false, extracted)
    }

    /// 모듈 이름 — `Name(…)` 의 마지막 인자가 이기고, 없으면 주어진 기본값이다.
    private func expoModuleName(extracted: [ExtractedDefinition], defaultName: ResolvedName) -> ResolvedName {
        for entry in extracted.reversed() {
            if let argument = entry.dsl.nameArguments.last {
                return bindings.resolveString(
                    argument,
                    in: BindingCollector.Context(scopes: [BindingCollector.scopeKey(entry.body)], enclosingTypes: typeNames)
                )
            }
        }
        return defaultName
    }

    /// 모은 DSL 호출을 사실로 옮긴다.
    ///
    /// `View` 가 하나라도 있으면 JS 의 `requireNativeViewManager(모듈이름)` 이 이 클래스를
    /// 찾으므로 component-export 를 첫 `View` 호출 자리에 낸다. `Function` 계열 호출은
    /// JS 가 부르는 메서드다 — 이름 경계 사실이 아니라 mechanism 을 싣지 않는다.
    private func emitExpoDSL(moduleName: ResolvedName, extracted: [ExtractedDefinition]) {
        if let view = extracted.lazy.compactMap({ $0.dsl.viewCalls.first }).first {
            emit(.componentExport, target: .reactNative, channel: moduleName, mechanism: .expo, at: view)
        }
        for entry in extracted {
            guard !entry.dsl.functionCalls.isEmpty else { continue }
            let context = BindingCollector.Context(
                scopes: [BindingCollector.scopeKey(entry.body)], enclosingTypes: typeNames
            )
            for call in entry.dsl.functionCalls {
                guard let argument = call.arguments.first?.expression else { continue }
                let method = bindings.resolveString(argument, in: context)
                emit(.methodHandle, target: .reactNative, channel: moduleName, method: method, at: call)
            }
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
        let start = node.startLocation(converter: converter)
        let end = node.endLocation(converter: converter)
        declarations.append(
            EnclosingDeclaration(
                name: base,
                indexName: indexName,
                qualifiedName: qualified ?? (typeNames + [base]).joined(separator: "."),
                line: start.line,
                start: SourceLocation(path: path, line: start.line, column: start.column),
                end: SourceLocation(path: path, line: end.line, column: end.column)
            )
        )
    }

    private func emit(
        _ kind: BridgeFact.Kind,
        target: BridgeFact.Target,
        channel: ResolvedName?,
        method: ResolvedName? = nil,
        handlerScope: BridgeFact.HandlerScope? = nil,
        inferred: Bool = false,
        mechanism: BridgeFact.Mechanism? = nil,
        at node: some SyntaxProtocol
    ) {
        guard !messages || kind == .messageHandle else { return }
        guard !events || kind == .streamHandle else { return }
        let location = node.startLocation(converter: converter)
        let fact = BridgeFact(
            kind: kind,
            target: target,
            channel: channel?.text,
            method: method?.text,
            isDynamic: (channel?.isDynamic ?? false) || (method?.isDynamic ?? false),
            channelPrefix: (messages || events) ? channel?.channelPrefix : nil,
            handlerScope: handlerScope,
            isChannelInferred: inferred,
            mechanism: mechanism,
            location: SourceLocation(path: path, line: location.line, column: location.column)
        )
        facts.append(ScannedBridgeFact(fact: fact, declaration: declarations.last))
    }
}

// MARK: - Expo definition 본문 수집

/// `func definition` 의 결과 빌더 본문에서 Expo Modules DSL 호출을 모은다.
///
/// `Name`·`View`·`Function` 은 흔한 이름이라 `definition` 본문의 직접 문장만 본다.
/// `Function("f") { … }` 의 클로저나 지역 함수 안에 있는 동명 호출은 세지 않는다.
/// `ModuleDefinition { … }` 처럼 명시적 래퍼의 후행 클로저만 투명하게 지나간다.
private final class ExpoDefinitionCollector: SyntaxVisitor {
    /// 모은 DSL 호출.
    struct Result {
        /// `Name(…)` 의 인자 식. 같은 정의에 여러 개면 뒤의 것이 이긴다(정의 덮어쓰기).
        var nameArguments: [ExprSyntax] = []
        /// `View(…)`·`View { … }` 호출.
        var viewCalls: [FunctionCallExprSyntax] = []
        /// `Function` 계열 — JS 가 부르는 메서드 정의 호출.
        var functionCalls: [FunctionCallExprSyntax] = []
        var isEmpty: Bool { nameArguments.isEmpty && viewCalls.isEmpty && functionCalls.isEmpty }
    }

    /// JS 가 부르는 메서드를 정의하는 DSL 팩토리 이름들.
    private static let functionFactories: Set<String> = [
        "Function", "AsyncFunction", "SyncFunction", "ConcurrentFunction",
        "StaticFunction", "StaticAsyncFunction",
    ]

    static func collect(_ function: FunctionDeclSyntax) -> Result {
        let collector = ExpoDefinitionCollector()
        if let body = function.body {
            collector.rootID = body.id
            collector.walk(body)
        }
        return collector.result
    }

    private var result = Result()
    /// 걸어 들어간 본문. 조상 검사는 이 뿌리에 닿으면 직접 문장으로 멈춘다.
    private var rootID: SyntaxIdentifier?

    init() { super.init(viewMode: .sourceAccurate) }

    /// 이 호출이 결과 빌더의 직접 문장인지.
    ///
    /// 조상에 `ModuleDefinition { … }` 래퍼의 후행 클로저가 아닌 클로저, 다른 함수
    /// 호출의 인자, 또는 지역 함수가 끼어 있으면 DSL 문장이 아니다. `if` 안의 호출은
    /// 결과 빌더가 변환하므로 직접 문장과 같이 본다.
    private func isDSLStatement(_ node: FunctionCallExprSyntax) -> Bool {
        var current = Syntax(node)
        while let parent = current.parent {
            if parent.id == rootID { return true }
            if parent.is(FunctionDeclSyntax.self) || parent.is(InitializerDeclSyntax.self) { return false }
            if let call = parent.as(FunctionCallExprSyntax.self) {
                guard let closure = current.as(ClosureExprSyntax.self),
                      call.trailingClosure == closure,
                      BindingCollector.calleeName(of: call) == "ModuleDefinition"
                else { return false }
            }
            current = parent
        }
        return true
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard isDSLStatement(node), let callee = BindingCollector.calleeName(of: node)
        else { return .visitChildren }
        switch callee {
        case "Name":
            if let argument = node.arguments.first { result.nameArguments.append(argument.expression) }
        case "View":
            result.viewCalls.append(node)
        case let name where Self.functionFactories.contains(name):
            result.functionCalls.append(node)
        default:
            break
        }
        return .visitChildren
    }
}
