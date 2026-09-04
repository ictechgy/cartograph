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

/// 문자열 상수 하나. 같은 키가 다른 값으로 두 번 선언되면 `nil` 로 지워 "모른다"고 한다.
private typealias ConstantTable = [String: String?]

/// 파일 안의 문자열 상수와 채널 변수를 모은다.
///
/// 한 단계만 따라간다. `static let name = "…"` 을 `FlutterMethodChannel(name: Self.name)` 에
/// 넣는 것은 흔하고, 그것을 놓치면 채널 대부분이 `dynamic` 으로 나온다. 두 단계
/// 이상(상수가 다른 상수를 참조)은 드물고, 그 경우는 정직하게 `dynamic` 으로 남긴다.
///
/// 상수는 선언된 타입으로 구분한다. `A.name` 과 `B.name` 을 한 이름으로 섞으면
/// 다른 타입의 값이 이 타입의 리터럴로 나간다. `dynamic` 은 안전하지만 틀린 리터럴은
/// isthmus 의 조인을 오염시킨다.
final class BindingCollector: SyntaxVisitor {
    /// `Type.name` → 리터럴. 파일 최상위 상수는 `name` 그대로.
    private var constants: ConstantTable = [:]
    /// 채널 변수 이름 → 생성자의 `name:` 인자와, 그것이 쓰인 타입·함수 문맥.
    ///
    /// 해석은 2차 패스에서 한다. 여기서 해석하면 아래에 선언된 상수를 못 본다.
    private(set) var channelBindings: [String: (argument: ExprSyntax, enclosingTypes: [String], scope: Int?)?] = [:]
    /// 이 파일이 선언하거나 확장한 타입 이름.
    private(set) var declaredTypeNames: Set<String> = []
    /// `@objc(Name)` 클래스 이름 → 모듈 이름과 `@objcMembers` 여부. 익스텐션이 이것을 이어받는다.
    private(set) var reactModules: [String: (name: String, exportsAllMembers: Bool)] = [:]
    /// `FlutterEventChannel(name:)` 생성 수.
    private(set) var eventChannelCount = 0
    /// `FlutterBasicMessageChannel(name:)` / `BasicMessageChannel(name:)` 생성 수.
    private(set) var messageChannelCount = 0

    /// 지금 어느 타입 안에 있는지. 상수와 채널 변수의 키를 만든다.
    private var typeNames: [String] = []
    /// 지금 어느 함수 본문 안에 있는지. 지역 상수는 그 함수 안에서만 보인다.
    ///
    /// 함수를 구분하지 않고 지역 상수를 파일 최상위로 올리면, 어느 함수의 `let name = "…"`
    /// 이든 파일 전체의 `name` 참조를 확신에 찬 리터럴로 만든다. 다른 파일의 전역 상수를
    /// 가리키는 참조가 이 파일의 무관한 지역 값으로 나간다.
    private var scopes: [Int] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: 함수 문맥

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_ node: FunctionDeclSyntax) { scopes.removeLast() }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { pushScope(node) }
    override func visitPost(_ node: InitializerDeclSyntax) { scopes.removeLast() }

    private func pushScope(_ node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        scopes.append(Self.scopeKey(node)); return .visitChildren
    }

    /// 함수를 구분하는 키. 두 패스가 같은 노드에서 같은 값을 얻는다.
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
        return .visitChildren
    }

    private func bind(name: String, to value: ExprSyntax, isLocal: Bool) {
        if let literal = Self.stringLiteral(value) {
            // 함수 안의 지역 상수는 그 함수 키로만 둔다. 밖에서는 보이지 않는다.
            record(&constants, key: isLocal ? Self.localKey(name, scope: scopes.last) : qualified(name), value: literal)
        } else if let argument = Self.channelNameArgument(value) {
            if let existing = channelBindings[name] {
                if existing != nil { channelBindings[name] = .some(nil) }
            } else {
                channelBindings[name] = (argument, typeNames, scopes.last)
            }
        }
    }

    private func qualified(_ name: String) -> String {
        (typeNames + [name]).joined(separator: ".")
    }

    private static func localKey(_ name: String, scope: Int?) -> String {
        "\(scope ?? -1)#\(name)"
    }

    /// 같은 키가 다른 값으로 두 번 나오면 어느 쪽인지 알 수 없다. 그때는 모른다고 한다.
    private func record(_ table: inout ConstantTable, key: String, value: String) {
        if let existing = table[key] {
            if existing != value { table[key] = .some(nil) }
        } else {
            table[key] = value
        }
    }

    // MARK: 해석 (2차 패스에서 부른다)

    /// 채널 변수 이름을 채널 이름으로 푼다. 변수를 모르면 nil, 알지만 못 풀면 `dynamic`.
    func channel(named name: String) -> ResolvedName?? {
        guard let entry = channelBindings[name] else { return nil }
        guard let entry else { return .some(nil) }
        return .some(resolveString(entry.argument, enclosingTypes: entry.enclosingTypes, scope: entry.scope))
    }

    /// `FlutterMethodChannel(name: …, …)` 호출이면 그 채널 이름.
    func channelConstruction(_ expression: ExprSyntax, enclosingTypes: [String], scope: Int?) -> ResolvedName? {
        Self.channelNameArgument(expression).map { resolveString($0, enclosingTypes: enclosingTypes, scope: scope) }
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
    /// - `name`: 같은 함수의 지역 상수, 그다음 감싸는 타입에서 바깥으로, 마지막으로 파일 최상위.
    /// - `Self.name`, `self.name`: 감싸는 타입에서 바깥으로, 마지막으로 파일 최상위.
    /// - `Type.name`: 이 파일이 선언하거나 확장한 `Type` 의 상수만.
    /// - `.name`(암시적 멤버): 수신자 타입은 `String` 이지 이 파일의 어떤 타입도 아니다.
    ///   구문만으로는 어느 확장의 상수인지 알 수 없으므로 `dynamic`.
    func resolveString(_ expression: ExprSyntax, enclosingTypes: [String], scope: Int?) -> ResolvedName {
        if let literal = Self.stringLiteral(expression) { return .literal(literal) }
        if let value = constant(for: expression, enclosingTypes: enclosingTypes, scope: scope) { return .literal(value) }
        return .dynamic(expression.trimmedDescription)
    }

    private func constant(for expression: ExprSyntax, enclosingTypes: [String], scope: Int?) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            let name = DeclarationCollector.unescaped(reference.baseName.text)
            if let scope, let local = constants[Self.localKey(name, scope: scope)] { return local }
            return lookup(name, from: enclosingTypes)
        }
        guard let member = expression.as(MemberAccessExprSyntax.self),
              let base = member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text
        else { return nil }
        let name = DeclarationCollector.unescaped(member.declName.baseName.text)
        if base == "Self" || base == "self" { return lookup(name, from: enclosingTypes) }
        let type = DeclarationCollector.unescaped(base)
        guard declaredTypeNames.contains(type) else { return nil }
        return constants[type + "." + name] ?? nil
    }

    /// 감싸는 타입에서 바깥으로 찾고, 마지막에 파일 최상위를 본다.
    private func lookup(_ name: String, from enclosingTypes: [String]) -> String? {
        for depth in stride(from: enclosingTypes.count, through: 0, by: -1) {
            let key = (enclosingTypes.prefix(depth) + [name]).joined(separator: ".")
            if let value = constants[key] { return value }
        }
        return nil
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
        // 함수 본문 안의 지역 함수는 인덱스에 정점이 없고 Objective-C 에도 보이지 않는다.
        // 감싸는 메서드가 그대로 남는다.
        guard !DeclarationCollector.isInsideBody(node) else { return .visitChildren }
        pushDeclaration(
            name: node.name.text,
            indexName: Self.indexName(node.name.text, parameters: node.signature.parameterClause.parameters),
            node: node
        )
        scopes.append(BindingCollector.scopeKey(node)); aliasScopes.append([])
        if Self.takesMethodCall(node) { methodCallFunctionDepth += 1 }
        emitReactMethodIfExported(node)
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) {
        guard !DeclarationCollector.isInsideBody(node) else { return }
        declarations.removeLast(); scopes.removeLast(); aliasScopes.removeLast()
        if Self.takesMethodCall(node) { methodCallFunctionDepth -= 1 }
    }

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
              Self.handlerRegistrationMethods.contains(member.declName.baseName.text)
        else { return .visitChildren }

        let channel = registeredChannel(of: node, receiver: member.base)
        emit(.channelRegister, target: .flutter, channel: channel, at: node)

        // 핸들러 클로저 안의 `case "…"` 는 이 채널의 메서드다. 클로저를 방문하는 동안만
        // 채널을 스택에 올린다. 클로저가 없으면(델리게이트 등록) 올릴 것이 없다.
        guard let closure = Self.handlerClosure(of: node) else { return .visitChildren }
        handlerChannels.append(channel); aliasScopes.append([])
        walk(closure)
        handlerChannels.removeLast(); aliasScopes.removeLast()
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
        if let inline = bindings.channelConstruction(expression, enclosingTypes: typeNames, scope: scopes.last) {
            return inline
        }
        if let name = BindingCollector.identifierName(of: expression), let bound = bindings.channel(named: name) {
            return bound ?? .dynamic(expression.trimmedDescription)
        }
        return .dynamic(expression.trimmedDescription)
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
                method: bindings.resolveString(expression, enclosingTypes: typeNames, scope: scopes.last),
                inferred: inferred, at: item
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
                method: bindings.resolveString(value, enclosingTypes: typeNames, scope: scopes.last),
                inferred: inferred, at: value
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
        if Self.isMethodMemberAccess(expression) { return true }
        guard let reference = expression.as(DeclReferenceExprSyntax.self) else { return false }
        let name = DeclarationCollector.unescaped(reference.baseName.text)
        return aliasScopes.contains { $0.contains(name) }
    }

    private static func isMethodMemberAccess(_ expression: ExprSyntax) -> Bool {
        guard let member = expression.as(MemberAccessExprSyntax.self) else { return false }
        return member.base != nil && member.declName.baseName.text == "method"
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
        let known = Set(bindings.channelBindings.keys.compactMap { bindings.channel(named: $0) ?? nil })
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
