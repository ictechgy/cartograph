import CartographCore
@testable import CartographSyntax
import Testing

@Suite("브리지 사실 스캐너")
struct BridgeFactScannerTests {
    private func scan(_ source: String, path: String = "/p/Plugin.swift") -> [ScannedBridgeFact] {
        BridgeFactScanner().scan(source: source, path: path).facts
    }

    private func facts(_ source: String, of kind: BridgeFact.Kind) -> [BridgeFact] {
        scan(source).map(\.fact).filter { $0.kind == kind }
    }

    @Test("접근자 지역 상수와 setter 매개변수는 자기 스코프에서 해석한다")
    func accessorScopes() {
        let source = """
            let name = "wrong"
            let newValue = "wrong"
            class Plugin {
                var registration: Void {
                    let name = "right"
                    let alias = name
                    FlutterMethodChannel(name: alias, binaryMessenger: m).setMethodCallHandler { _, _ in }
                }
                var value: String {
                    get { "" }
                    set {
                        FlutterMethodChannel(name: newValue, binaryMessenger: m).setMethodCallHandler { _, _ in }
                    }
                }
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.count == 2)
        #expect(registered.first?.channel == "right")
        #expect(registered.first?.isDynamic == false)
        #expect(registered.last?.isDynamic == true)
    }

    @Test("혼합 표기의 초기화와 바깥 스코프 채널 변경은 한 바인딩에서 충돌한다")
    func mergesAssignmentTargets() {
        let source = """
            class Plugin {
                let channel: FlutterMethodChannel
                init(flag: Bool) {
                    if flag { self.channel = FlutterMethodChannel(name: "a", binaryMessenger: m) }
                    else { channel = FlutterMethodChannel(name: "b", binaryMessenger: m) }
                }
                func attach() { channel.setMethodCallHandler { _, _ in } }
            }
            func local() {
                var channel = FlutterMethodChannel(name: "a", binaryMessenger: m)
                consume { channel = FlutterMethodChannel(name: "b", binaryMessenger: m) }
                channel.setMethodCallHandler { _, _ in }
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.count == 2)
        #expect(registered.allSatisfy { $0.channel == nil || $0.isDynamic })
    }

    @Test("혼합 표기의 문자열 초기화도 상수라고 확정하지 않는다")
    func mixedStringAssignmentIsUnknown() {
        let source = """
            class Plugin {
                let name: String
                init(flag: Bool) { if flag { self.name = "a" } else { name = "b" } }
                func attach() {
                    FlutterMethodChannel(name: name, binaryMessenger: m).setMethodCallHandler { _, _ in }
                }
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.count == 1)
        #expect(registered.allSatisfy { $0.isDynamic })
    }

    @Test("타입 이름을 가린 수신자와 상속한 Self 멤버를 전역 상수로 바꾸지 않는다")
    func qualifiedReceiverShadows() {
        let source = """
            enum Names { static let value = "wrong-type" }
            let value = "wrong-global"
            func register(Names: Other) {
                let alias = Names.value
                FlutterMethodChannel(name: alias, binaryMessenger: m).setMethodCallHandler { _, _ in }
            }
            class Base { static let value = "base" }
            class Child: Base {
                static func register() {
                    FlutterMethodChannel(name: Self.value, binaryMessenger: m).setMethodCallHandler { _, _ in }
                }
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.count == 2)
        #expect(registered.allSatisfy { $0.isDynamic })
    }

    @Test("초기화 전 선언은 self 채널의 첫 초기화 대입을 막지 않는다")
    func initializesDeclaredChannel() {
        let source = """
            class Plugin {
                let channel: FlutterMethodChannel
                init() {
                    self.channel = FlutterMethodChannel(name: "camera", binaryMessenger: m)
                    self.channel.setMethodCallHandler { call, result in
                        if call.method == "run" { result(nil) }
                    }
                }
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.count == 1)
        #expect(handled.first?.channel == "camera")
        #expect(handled.first?.isDynamic == false)
    }

    @Test("클로저 캡처와 조건 패턴은 전역 상수의 값을 빌리지 않는다")
    func captureAndPatternShadows() {
        let source = """
            let name = "wrong"
            func install() {
                consume { [name = runtimeName()] in
                    let alias = name
                    FlutterMethodChannel(name: alias, binaryMessenger: m).setMethodCallHandler { _, _ in }
                }
                if let name = runtimeOptionalName() {
                    FlutterMethodChannel(name: name, binaryMessenger: m).setMethodCallHandler { _, _ in }
                }
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.count == 2)
        #expect(registered.allSatisfy { $0.isDynamic })
    }

    @Test("불변 상수 별칭은 선언 문맥에서 여러 단계 풀고 괄호를 벗긴다")
    func followsImmutableAliases() {
        let source = """
            enum Names { static let base = "camera"; static let alias = (base) }
            let channelName = Names.alias
            func register() {
                let base = "wrong"
                let local = channelName
                FlutterMethodChannel(name: (local), binaryMessenger: m).setMethodCallHandler { _, _ in }
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.map(\.channel) == ["camera"])
        #expect(registered.allSatisfy { !$0.isDynamic })
    }

    @Test("매개변수와 계산 프로퍼티는 바깥 동명 상수로 풀지 않는다")
    func unknownBindingsShadowConstants() {
        let source = """
            let name = "wrong"
            func register(name: String) {
                let alias = name
                FlutterMethodChannel(name: name, binaryMessenger: m).setMethodCallHandler { _, _ in }
                FlutterMethodChannel(name: alias, binaryMessenger: m).setMethodCallHandler { _, _ in }
            }
            class Plugin {
                var name: String { runtimeName() }
                func register() {
                    FlutterMethodChannel(name: name, binaryMessenger: m).setMethodCallHandler { _, _ in }
                }
            }
            """
        #expect(facts(source, of: .channelRegister).allSatisfy { $0.isDynamic })
    }

    @Test("가변 이름과 순환 별칭과 연산자 식은 상수로 추측하지 않는다")
    func refusesUnprovenConstants() {
        let source = """
            var mutable = "before"
            mutate(&mutable)
            let alias = mutable
            let a = b
            let b = a
            FlutterMethodChannel(name: mutable, binaryMessenger: m).setMethodCallHandler { _, _ in }
            FlutterMethodChannel(name: alias, binaryMessenger: m).setMethodCallHandler { _, _ in }
            FlutterMethodChannel(name: a, binaryMessenger: m).setMethodCallHandler { _, _ in }
            FlutterMethodChannel(name: "a" + mutable, binaryMessenger: m).setMethodCallHandler { _, _ in }
            """
        #expect(facts(source, of: .channelRegister).count == 4)
        #expect(facts(source, of: .channelRegister).allSatisfy { $0.isDynamic })
    }

    @Test("많은 핸들러의 범위는 사실마다 복사하지 않고 선언별로 보존한다")
    func storesHandlerScopesOncePerDeclaration() {
        let registrations = (0..<100).map { index in
            "let channel\(index) = BasicMessageChannel<Any?>(name: \"channel\(index)\", binaryMessenger: messenger)\n"
                + "channel\(index).setMessageHandler { _, _ in reply(\(index)) }"
        }.joined(separator: "\n")
        let split = registrations.split(separator: "\n", omittingEmptySubsequences: true)
        let first = split.prefix(100)
        let second = split.dropFirst(100)
        let result = BridgeFactScanner().scan(
            source: "func install() {\n\(first.joined(separator: "\n"))\n}\n"
                + "func installSecond() {\n\(second.joined(separator: "\n"))\n}",
            path: "/p/Plugin.swift", messages: true
        )

        #expect(result.facts.count == 100)
        #expect(result.handlerScopes.count == 2)
        #expect(result.handlerScopes.map(\.scopes.count) == [50, 50])
        #expect(result.facts.allSatisfy { $0.handlerScopes.isEmpty })
    }

    @Test("채널을 만들기만 한 것은 사실이 아니다")
    func creationAloneIsNotAFact() {
        let source = """
            import Flutter
            final class CameraPlugin {
                let channel = FlutterMethodChannel(name: "com.example/camera", binaryMessenger: messenger)
            }
            """
        #expect(scan(source).isEmpty)
    }

    @Test("setMethodCallHandler 는 수신자 변수를 따라 채널 이름을 찾고 위치는 등록 호출을 가리킨다")
    func resolvesRegisteredChannelThroughVariable() {
        let source = """
            final class CameraPlugin {
                private var channel: FlutterMethodChannel?
                func attach(messenger: FlutterBinaryMessenger) {
                    channel = FlutterMethodChannel(name: "com.example/camera", binaryMessenger: messenger)
                    channel?.setMethodCallHandler { call, result in
                        result(nil)
                    }
                }
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.map(\.channel) == ["com.example/camera"])
        #expect(registered.first?.isDynamic == false)
        #expect(registered.first?.location == SourceLocation(path: "/p/Plugin.swift", line: 5, column: 9))
    }

    @Test("lazy var 로 만든 채널도 따라간다")
    func resolvesLazyChannel() {
        let source = """
            final class CameraPlugin {
                lazy var channel = FlutterMethodChannel(name: "com.example/camera", binaryMessenger: messenger)
                func attach() {
                    channel.setMethodCallHandler { _, result in result(nil) }
                }
            }
            """
        #expect(facts(source, of: .channelRegister).map(\.channel) == ["com.example/camera"])
    }

    @Test("핸들러 클로저 안의 case 리터럴은 그 채널의 method-handle 이 된다")
    func attributesSwitchCasesToEnclosingHandler() {
        let source = """
            let channel = FlutterMethodChannel(name: "com.example/camera", binaryMessenger: messenger)
            channel.setMethodCallHandler { call, result in
                switch call.method {
                case "takePhoto":
                    result(takePhoto())
                case "record", "stop":
                    result(nil)
                default:
                    result(FlutterMethodNotImplemented)
                }
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.map(\.method) == ["takePhoto", "record", "stop"])
        #expect(handled.allSatisfy { $0.channel == "com.example/camera" })
        #expect(handled.allSatisfy { !$0.isDynamic && !$0.isChannelInferred })
    }

    @Test("괄호로 감싼 switch (call.method) 도 인식한다")
    func recognizesParenthesizedSubject() {
        // sensors_plus 가 실제로 이렇게 쓴다. 괄호 하나에 핸들러 다섯 개가 사라졌다.
        let source = """
            let channel = FlutterMethodChannel(name: "dev.fluttercommunity.plus/sensors/method", binaryMessenger: m)
            channel.setMethodCallHandler { call, result in
                switch (call.method) {
                case "setAccelerationSamplingPeriod": result(nil)
                default: result(FlutterMethodNotImplemented)
                }
                if ((call.method) == "ping") { result(nil) }
                if ((call.method)) == "pong" { result(nil) }
            }
            """
        #expect(facts(source, of: .methodHandle).map(\.method) == ["setAccelerationSamplingPeriod", "ping", "pong"])
    }

    @Test("if call.method == 리터럴 분기도 method-handle 이다")
    func recordsEqualityBranches() {
        let source = """
            let channel = FlutterMethodChannel(name: "com.example/camera", binaryMessenger: messenger)
            channel.setMethodCallHandler { call, result in
                if call.method == "takePhoto" { result(nil) }
                guard "dispose" == call.method else { return }
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.map(\.method) == ["takePhoto", "dispose"])
    }

    @Test("등록 호출이 없어도 파일에 채널이 하나면 handle 메서드의 case 가 추측으로 그 채널에 붙는다")
    func fallsBackToSingleChannelInFile() {
        // 등록은 다른 파일에서 한다. 채널 생성만 이 파일에 있다.
        let source = """
            public final class CameraPlugin: NSObject, FlutterPlugin {
                static let channel = FlutterMethodChannel(name: "com.example/camera", binaryMessenger: Registry.messenger)
                public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    switch call.method {
                    case "takePhoto": result(nil)
                    default: result(FlutterMethodNotImplemented)
                    }
                }
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.map(\.channel) == ["com.example/camera"])
        #expect(handled.first?.isChannelInferred == true)
    }

    @Test("FlutterPlugin 표준 형태는 등록 호출이 타입을 말해 주므로 추측이 아니다")
    func delegateRegistrationIsAFact() {
        let source = """
            public final class CameraPlugin: NSObject, FlutterPlugin {
                public static func register(with registrar: FlutterPluginRegistrar) {
                    let channel = FlutterMethodChannel(name: "com.example/camera", binaryMessenger: registrar.messenger())
                    registrar.addMethodCallDelegate(CameraPlugin(), channel: channel)
                }
                public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    switch call.method {
                    case "takePhoto": result(nil)
                    default: result(FlutterMethodNotImplemented)
                    }
                }
            }
            """
        let scanned = scan(source)
        let registered = scanned.map(\.fact).filter { $0.kind == .channelRegister }
        #expect(registered.map(\.channel) == ["com.example/camera"])

        let handled = scanned.filter { $0.fact.kind == .methodHandle }
        #expect(handled.map(\.fact.channel) == ["com.example/camera"])
        #expect(handled.first?.fact.isChannelInferred == false)
        // 클로저가 아니라 메서드 안이므로 감싸는 선언은 `handle` 이다.
        #expect(handled.first?.declaration?.name == "handle")
        #expect(handled.first?.declaration?.indexName == "handle(_:result:)")
        #expect(handled.first?.declaration?.qualifiedName == "CameraPlugin.handle")
        #expect(handled.first?.declaration?.line == 6)
    }

    @Test("addMethodCallDelegate 로 등록된 타입의 handle 은 추측 없이 그 채널이다")
    func attributesDelegateHandleToRegisteredChannel() {
        // 파일에 채널이 둘이라 추측은 못 쓴다. 등록 호출이 어느 타입인지 말해 준다.
        let source = """
            public final class CameraPlugin: NSObject, FlutterPlugin {
                public static func register(with registrar: FlutterPluginRegistrar) {
                    let camera = FlutterMethodChannel(name: "com.example/camera", binaryMessenger: registrar.messenger())
                    let events = FlutterMethodChannel(name: "com.example/events", binaryMessenger: registrar.messenger())
                    let instance = CameraPlugin()
                    registrar.addMethodCallDelegate(instance, channel: camera)
                    registrar.addMethodCallDelegate(EventsPlugin(), channel: events)
                }
                public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    switch call.method { case "takePhoto": result(nil); default: break }
                }
            }
            final class EventsPlugin: NSObject, FlutterPlugin {
                func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    if call.method == "listen" { result(nil) }
                }
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.map(\.method) == ["takePhoto", "listen"])
        #expect(handled.map(\.channel) == ["com.example/camera", "com.example/events"])
        #expect(handled.allSatisfy { !$0.isChannelInferred && !$0.isDynamic })
    }

    @Test("메서드 참조 핸들러는 등록한 타입의 FlutterMethodCall 메서드에만 붙는다")
    func referencedHandlerDoesNotLeakToSameNamedFunctions() {
        let source = """
            final class AudioPlugin {
                init(messenger: Any) {
                    let ch = FlutterMethodChannel(name: "com.example/audio", binaryMessenger: messenger)
                    ch.setMethodCallHandler(handleCall)
                }
                func handleCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    if call.method == "play" { result(nil) }
                }
            }
            final class Router {
                func handleCall(_ request: Request) {
                    if request.method == "DELETE" { purge() }
                }
                func handleCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    if call.method == "stop" { result(nil) }
                }
            }
            """
        let handled = facts(source, of: .methodHandle)
        // "DELETE" 는 없다. Router 의 FlutterMethodCall 오버로드는 파일에 채널이 하나라 추측으로만 붙는다.
        #expect(handled.map(\.method) == ["play", "stop"])
        #expect(handled.map(\.isChannelInferred) == [false, true])
    }

    @Test("델리게이트 채널은 점으로 이은 타입 이름으로 구분하고 이중 등록은 채널 없음이다")
    func delegateChannelsAreKeyedByFullTypeNameAndAmbiguityIsHonest() {
        let source = """
            enum A {
                final class Plugin: NSObject, FlutterPlugin {
                    static func register(with r: FlutterPluginRegistrar) {
                        let c = FlutterMethodChannel(name: "a/channel", binaryMessenger: r.messenger())
                        r.addMethodCallDelegate(A.Plugin(), channel: c)
                    }
                    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                        switch call.method { case "x": result(nil); default: break }
                    }
                    func handle(_ call: FlutterMethodCall, retries: Int) {
                        switch call.method { case "overload": break; default: break }
                    }
                }
            }
            enum B {
                final class Plugin: NSObject, FlutterPlugin {
                    static func register(with r: FlutterPluginRegistrar) {
                        let one = FlutterMethodChannel(name: "b/one", binaryMessenger: r.messenger())
                        let two = FlutterMethodChannel(name: "b/two", binaryMessenger: r.messenger())
                        r.addMethodCallDelegate(B.Plugin(), channel: one)
                        r.addMethodCallDelegate(B.Plugin(), channel: two)
                    }
                    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                        switch call.method { case "y": result(nil); default: break }
                    }
                }
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.map(\.method) == ["x", "overload", "y"])
        // A.Plugin.handle(_:result:) 는 a/channel. 오버로드는 파일에 채널이 셋이라 추측도 못 해 null.
        // B.Plugin 은 두 채널에 등록돼 어느 쪽인지 모르므로 null.
        #expect(handled.map(\.channel) == ["a/channel", nil, nil])
    }

    @Test("중첩 타입 안의 무자격 Plugin() 은 그 중첩 타입이지 최상위 동명 타입이 아니다")
    func unqualifiedDelegateResolvesLikeSwiftLookup() {
        let source = """
            enum A {
                final class Plugin: NSObject, FlutterPlugin {
                    static func register(with r: FlutterPluginRegistrar) {
                        let c = FlutterMethodChannel(name: "a/channel", binaryMessenger: r.messenger())
                        r.addMethodCallDelegate(Plugin(), channel: c)
                    }
                    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                        switch call.method { case "inner": result(nil); default: break }
                    }
                }
            }
            final class Plugin {
                func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    switch call.method { case "unrelated": result(nil); default: break }
                }
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.map(\.method) == ["inner", "unrelated"])
        #expect(handled.map(\.channel) == ["a/channel", "a/channel"])
        // inner 는 등록 사실, unrelated 는 파일에 채널이 하나라 추측일 뿐이다.
        #expect(handled.map(\.isChannelInferred) == [false, true])
    }

    @Test("같은 텍스트의 다른 채널 변수로 두 번 등록하면 채널 없음이고, 메서드 참조도 같은 규칙이다")
    func duplicateRegistrationsCompareResolvedChannels() {
        let source = """
            final class P: NSObject, FlutterPlugin {
                static func register(with r: FlutterPluginRegistrar) {
                    let channel = FlutterMethodChannel(name: "ch/one", binaryMessenger: r.messenger())
                    r.addMethodCallDelegate(P(), channel: channel)
                }
                static func registerMore(with r: FlutterPluginRegistrar) {
                    let channel = FlutterMethodChannel(name: "ch/two", binaryMessenger: r.messenger())
                    r.addMethodCallDelegate(P(), channel: channel)
                }
                func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    switch call.method { case "ping": result(nil); default: break }
                }
            }
            final class Q: NSObject {
                let a: FlutterMethodChannel
                let b: FlutterMethodChannel
                init(m: Any) {
                    a = FlutterMethodChannel(name: "q/a", binaryMessenger: m)
                    b = FlutterMethodChannel(name: "q/b", binaryMessenger: m)
                    super.init()
                    a.setMethodCallHandler(handleCall)
                    b.setMethodCallHandler(handleCall)
                }
                func handleCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    switch call.method { case "pong": result(nil); default: break }
                }
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.map(\.method) == ["ping", "pong"])
        #expect(handled.allSatisfy { $0.channel == nil })
    }

    @Test("setMethodCallHandler(nil) 은 등록이 아니다")
    func unregistrationIsNotAFact() {
        let source = """
            let channel = FlutterMethodChannel(name: "c", binaryMessenger: m)
            channel.setMethodCallHandler(nil)
            """
        #expect(scan(source).isEmpty)
    }

    @Test("채널이 여럿이고 핸들러 밖이면 채널을 지어내지 않는다")
    func leavesChannelUnknownWhenAmbiguous() {
        let source = """
            let camera = FlutterMethodChannel(name: "com.example/camera", binaryMessenger: m)
            let audio = FlutterMethodChannel(name: "com.example/audio", binaryMessenger: m)
            func handle(_ call: FlutterMethodCall, result: FlutterResult) {
                switch call.method {
                case "takePhoto": result(nil)
                default: break
                }
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.count == 1)
        #expect(handled.first?.channel == nil)
        #expect(handled.first?.isDynamic == false)
        #expect(handled.first?.isChannelInferred == false)
    }

    @Test("다른 타입의 같은 이름 채널 변수를 훔치지 않는다")
    func channelVariablesAreScopedToTheirDeclaration() {
        // Camera 의 `channel` 은 팩토리가 만든 값이라 스캐너가 모른다. Audio 의 `channel` 로
        // 풀면 카메라 핸들러가 오디오 채널의 사실로 나가 Dart 조인이 어긋난다.
        let source = """
            final class CameraPlugin {
                func setup(messenger: Any) {
                    let channel = CameraSupport.make(messenger)
                    channel.setMethodCallHandler { call, result in
                        switch call.method { case "takePhoto": result(nil); default: result(nil) }
                    }
                }
            }
            final class AudioPlugin {
                func setup(messenger: Any) {
                    let channel = FlutterMethodChannel(name: "com.example/audio", binaryMessenger: messenger)
                    channel.setMethodCallHandler { call, result in
                        switch call.method { case "record": result(nil); default: result(nil) }
                    }
                }
            }
            final class VideoPlugin {
                func setup(messenger: Any) {
                    let channel = FlutterMethodChannel(name: "com.example/video", binaryMessenger: messenger)
                    channel.setMethodCallHandler { _, _ in }
                }
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.map(\.channel) == ["channel", "com.example/audio", "com.example/video"])
        #expect(registered.map(\.isDynamic) == [true, false, false])
        let handled = facts(source, of: .methodHandle)
        #expect(handled.map(\.channel) == ["channel", "com.example/audio"])
        #expect(handled.map(\.isDynamic) == [true, false])
    }

    @Test("클로저 안의 그림자 지역 변수는 바깥 함수의 상수를 덮지 않는다")
    func closureLocalsDoNotShadowOuterConstants() {
        let source = """
            final class PrinterPlugin: NSObject, FlutterPlugin {
                private static let name = "com.example/print"
                static func register(with registrar: FlutterPluginRegistrar) {
                    let channel = FlutterMethodChannel(name: name, binaryMessenger: registrar.messenger())
                    channel.setMethodCallHandler { call, result in
                        let name = "diagnostic"
                        result(name)
                    }
                }
            }
            """
        #expect(facts(source, of: .channelRegister).map(\.channel) == ["com.example/print"])
    }

    @Test("클로저는 바깥 함수의 지역 상수를 본다")
    func closuresSeeEnclosingLocals() {
        let source = """
            func attach(messenger: Any) {
                let name = "com.example/camera"
                run { FlutterMethodChannel(name: name, binaryMessenger: messenger).setMethodCallHandler { _, _ in } }
            }
            """
        #expect(facts(source, of: .channelRegister).map(\.channel) == ["com.example/camera"])
    }

    @Test("중첩 함수의 지역 상수는 두 패스가 같은 스코프로 본다")
    func nestedFunctionLocalsResolveInTheirOwnScope() {
        // 1차 패스가 중첩 함수 키로 기록한 것을 2차 패스가 바깥 메서드 키로 찾으면
        // 지역이 빗나가고 타입 상수가 대신 맞아 틀린 리터럴이 나간다.
        let source = """
            final class ScanPlugin: NSObject, FlutterPlugin {
                static let channelName = "com.example/scan"
                static func register(with registrar: FlutterPluginRegistrar) {
                    func attach(_ messenger: FlutterBinaryMessenger) {
                        let channelName = "com.example/internal"
                        FlutterMethodChannel(name: channelName, binaryMessenger: messenger).setMethodCallHandler { _, _ in }
                    }
                    attach(registrar.messenger())
                }
            }
            """
        #expect(facts(source, of: .channelRegister).map(\.channel) == ["com.example/internal"])
    }

    @Test("메서드 참조로 넘긴 핸들러의 분기도 그 채널의 것이다")
    func attributesCasesInReferencedHandlerMethod() {
        // audioplayers 의 형태. 파일에 채널이 둘이라 단일 채널 추측도 못 쓴다.
        let source = """
            final class AudioPlugin: NSObject {
                var methods: FlutterMethodChannel
                var globalMethods: FlutterMethodChannel
                init(messenger: Any) {
                    methods = FlutterMethodChannel(name: "xyz.luan/audioplayers", binaryMessenger: messenger)
                    globalMethods = FlutterMethodChannel(name: "xyz.luan/audioplayers.global", binaryMessenger: messenger)
                    super.init()
                    self.globalMethods.setMethodCallHandler(handleGlobalMethodCall)
                    methods.setMethodCallHandler(handleMethodCall)
                }
                func handleGlobalMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
                    let method = call.method
                    if method == "init" { result(nil) }
                }
                func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
                    switch call.method {
                    case "pause": result(nil)
                    default: result(nil)
                    }
                }
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.map(\.method) == ["init", "pause"])
        #expect(handled.map(\.channel) == ["xyz.luan/audioplayers.global", "xyz.luan/audioplayers"])
        #expect(handled.allSatisfy { !$0.isDynamic && !$0.isChannelInferred })
    }

    @Test("메서드 이름을 지역 변수에 담아 분기해도 인식한다")
    func followsMethodAlias() {
        let source = """
            let channel = FlutterMethodChannel(name: "c", binaryMessenger: m)
            channel.setMethodCallHandler { call, result in
                let method = call.method
                switch method {
                case "takePhoto": result(nil)
                default: break
                }
            }
            """
        #expect(facts(source, of: .methodHandle).map(\.method) == ["takePhoto"])
    }

    @Test("메서드 별칭은 그것을 선언한 함수 밖으로 새지 않는다")
    func methodAliasesAreScoped() {
        let source = """
            let channel = FlutterMethodChannel(name: "c", binaryMessenger: msg)
            func first(_ call: FlutterMethodCall, result: FlutterResult) {
                let m = call.method
                _ = m
            }
            final class Second {
                func handle(_ call: FlutterMethodCall, result: FlutterResult) {
                    let m = String(describing: call.arguments)
                    switch m {
                    case "photo": break
                    default: break
                    }
                }
            }
            """
        #expect(facts(source, of: .methodHandle).isEmpty)
    }

    @Test("수신자 없는 .method 는 열거형 케이스라 메서드 이름이 아니다")
    func ignoresImplicitMemberNamedMethod() {
        let source = """
            let channel = FlutterMethodChannel(name: "c", binaryMessenger: m)
            channel.setMethodCallHandler { call, result in
                if kind == .method { result(nil) }
            }
            """
        #expect(facts(source, of: .methodHandle).isEmpty)
    }

    @Test("옵셔널·모듈 한정 FlutterMethodCall 파라미터와 #if 로 감싼 case 도 인식한다")
    func recognizesQualifiedParameterTypesAndConditionalCases() {
        let source = """
            let channel = FlutterMethodChannel(name: "c", binaryMessenger: m)
            func handle(_ call: Flutter.FlutterMethodCall?, result: FlutterResult) {
                switch call!.method {
                #if DEBUG
                case "debugDump": result(nil)
                #endif
                case "takePhoto": result(nil)
                default: break
                }
            }
            """
        #expect(facts(source, of: .methodHandle).map(\.method) == ["debugDump", "takePhoto"])
    }

    @Test("FlutterMethodCall 을 받지 않는 함수의 .method 비교는 브리지 사실이 아니다")
    func ignoresUnrelatedMethodPropertyOutsideHandlers() {
        // StoreKit 의 `transaction.method` 처럼 이름만 같은 프로퍼티. 파일에 채널이 하나라도
        // 이것을 그 채널의 핸들러로 내면 isthmus 는 없는 핸들러와 조인한다.
        let source = """
            let channel = FlutterMethodChannel(name: "com.example/pay", binaryMessenger: m)
            func audit(_ transaction: Transaction) {
                if transaction.method == "refund" { log() }
                switch transaction.method {
                case "purchase": break
                default: break
                }
            }
            """
        #expect(facts(source, of: .methodHandle).isEmpty)
    }

    @Test("불변 별칭은 따라가되 연산자 식은 dynamic 으로 남긴다")
    func followsConstantsButNotOperators() {
        let source = """
            enum Channels {
                static let camera = "com.example/camera"
            }
            let name = Channels.camera
            FlutterMethodChannel(name: Channels.camera, binaryMessenger: m).setMethodCallHandler { _, _ in }
            FlutterMethodChannel(name: name, binaryMessenger: m).setMethodCallHandler { _, _ in }
            FlutterMethodChannel(name: prefix + "/camera", binaryMessenger: m).setMethodCallHandler { _, _ in }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.map(\.channel) == ["com.example/camera", "com.example/camera", "prefix + \"/camera\""])
        #expect(registered.map(\.isDynamic) == [false, false, true])
    }

    @Test("다른 수신자의 같은 이름 멤버와 암시적 멤버는 이 파일의 상수로 풀지 않는다")
    func doesNotStealConstantsAcrossReceivers() {
        // `external.channelName` 의 `external` 은 다른 파일의 타입이다. `.channelName` 의
        // 수신자는 `String` 이지 이 파일의 `Config` 가 아니다. 이름만 보고 풀면 조인 가능한
        // 리터럴로 위장한 틀린 사실이 나간다.
        let source = """
            enum Config { static let channelName = "com.example/camera" }
            final class Other {
                func setup(external: ExternalConfig) {
                    FlutterMethodChannel(name: external.channelName, binaryMessenger: m).setMethodCallHandler { _, _ in }
                    FlutterMethodChannel(name: Config.channelName, binaryMessenger: m).setMethodCallHandler { _, _ in }
                    FlutterMethodChannel(name: .channelName, binaryMessenger: m).setMethodCallHandler { _, _ in }
                }
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.map(\.channel) == ["external.channelName", "com.example/camera", ".channelName"])
        #expect(registered.map(\.isDynamic) == [true, false, true])
    }

    @Test("같은 이름의 상수가 다른 타입에 있으면 수신자 타입의 것을 쓴다")
    func distinguishesConstantsByDeclaringType() {
        let source = """
            struct A { static let name = "a" }
            struct B {
                static let name = "b"
                func attach() {
                    FlutterMethodChannel(name: Self.name, binaryMessenger: m).setMethodCallHandler { _, _ in }
                    FlutterMethodChannel(name: A.name, binaryMessenger: m).setMethodCallHandler { _, _ in }
                    FlutterMethodChannel(name: name, binaryMessenger: m).setMethodCallHandler { _, _ in }
                }
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.map(\.channel) == ["b", "a", "b"])
        #expect(registered.allSatisfy { !$0.isDynamic })
    }

    @Test("같은 타입에 같은 이름이 다른 값으로 두 번 있으면 모른다고 한다")
    func refusesToGuessBetweenConflictingConstants() {
        let source = """
            struct B { static let name = "b" }
            extension B { static let name = "c" }
            FlutterMethodChannel(name: B.name, binaryMessenger: m).setMethodCallHandler { _, _ in }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.first?.isDynamic == true)
        #expect(registered.first?.channel == "B.name")
    }

    @Test("아래에 선언된 상수도 따라간다")
    func resolvesConstantsDeclaredLater() {
        // 프로퍼티는 아래, 사용은 위의 init 안. 1차 패스에서 해석하면 이것을 놓친다.
        let source = """
            final class CameraPlugin {
                init(messenger: Any) {
                    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
                    channel.setMethodCallHandler { _, _ in }
                }
                private static let channelName = "com.example/camera"
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.map(\.channel) == ["com.example/camera"])
        #expect(registered.first?.isDynamic == false)
    }

    @Test("익스텐션에 둔 상수와 명시적 init 호출도 인식한다")
    func resolvesExtensionConstantsAndExplicitInit() {
        let source = """
            extension Config { static let channelName = "com.example/camera" }
            FlutterMethodChannel.init(name: Config.channelName, binaryMessenger: m).setMethodCallHandler { _, _ in }
            """
        #expect(facts(source, of: .channelRegister).map(\.channel) == ["com.example/camera"])
    }

    @Test("함수 안의 지역 상수는 그 함수 안에서만 보인다")
    func localConstantsAreScopedToTheirFunction() {
        // b 의 `name` 은 다른 파일의 전역 상수일 수 있다. a 의 지역 값으로 풀면 확신에 찬 틀린 리터럴이다.
        let source = """
            final class P {
                func a() { let name = "local" }
                func b() { FlutterMethodChannel(name: name, binaryMessenger: m).setMethodCallHandler { _, _ in } }
                func c() {
                    let name = "com.example/c"
                    FlutterMethodChannel(name: name, binaryMessenger: m).setMethodCallHandler { _, _ in }
                }
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.map(\.channel) == ["name", "com.example/c"])
        #expect(registered.map(\.isDynamic) == [true, false])
    }

    @Test("보간이 있는 리터럴은 원문 그대로 dynamic 이다")
    func treatsInterpolationAsDynamic() {
        let source = """
            FlutterMethodChannel(name: "com.example/\\(feature)", binaryMessenger: m).setMethodCallHandler { _, _ in }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.first?.isDynamic == true)
        #expect(registered.first?.channel == "\"com.example/\\(feature)\"")
    }

    @Test("case 의 표현식이 리터럴이 아니면 원문을 dynamic 으로 남긴다")
    func keepsNonLiteralCasesAsDynamic() {
        let source = """
            let channel = FlutterMethodChannel(name: "c", binaryMessenger: m)
            channel.setMethodCallHandler { call, result in
                switch call.method {
                case Method.takePhoto.rawValue: result(nil)
                default: break
                }
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.map(\.method) == ["Method.takePhoto.rawValue"])
        #expect(handled.first?.isDynamic == true)
    }

    @Test("인라인으로 만든 채널에 바로 핸들러를 달아도 채널 이름이 붙는다")
    func recordsInlineChannelRegistration() {
        let source = """
            FlutterMethodChannel(name: "c", binaryMessenger: m).setMethodCallHandler { call, result in
                switch call.method {
                case "ping": result("pong")
                default: break
                }
            }
            registrar.addMethodCallDelegate(self, channel: FlutterMethodChannel(name: "d", binaryMessenger: m))
            """
        let kinds = scan(source).map(\.fact.kind)
        #expect(kinds == [.channelRegister, .methodHandle, .channelRegister])
        #expect(facts(source, of: .channelRegister).map(\.channel) == ["c", "d"])
        #expect(facts(source, of: .methodHandle).first?.channel == "c")
    }

    @Test("FlutterEventChannel 과 BasicMessageChannel 은 읽지 않고 세기만 한다")
    func countsEventAndMessageChannels() {
        let source = """
            let events = FlutterEventChannel(name: "com.example/events", binaryMessenger: m)
            events.setStreamHandler(self)
            let pigeon = BasicMessageChannel<Any?>(name: "dev.flutter.pigeon.CameraApi.takePhoto", binaryMessenger: m)
            pigeon.setMessageHandler { _, _ in }
            """
        let result = BridgeFactScanner().scan(source: source, path: "/p/A.swift")
        #expect(result.facts.isEmpty)
        #expect(result.unscannedEventChannels == 1)
        #expect(result.unscannedMessageChannels == 1)
    }

    @Test("messages 선택은 BasicMessageChannel의 non-nil 핸들러만 message-handle로 낸다")
    func recordsBasicMessageHandlersOnlyWhenOptedIn() {
        let source = """
            let name = "wrong"
            let basic = FlutterBasicMessageChannel<Any?>(name: "literal", binaryMessenger: m)
            let alias = basic
            alias.setMessageHandler { _, _ in }
            basic.setMessageHandler(nil)
            other.setMessageHandler { _, _ in }
            FlutterMethodChannel(name: name, binaryMessenger: m).setMethodCallHandler { _, _ in }
            """
        let result = BridgeFactScanner().scan(source: source, path: "/p/A.swift", messages: true)
        // 수신자를 못 푸는 `other` 도 사실로 남긴다. 버리면 클로저 범위가 목록에서
        // 빠져 그 안의 참조가 다른 핸들러의 공통 등록 근거로 오염된다.
        #expect(result.facts.map(\.fact.kind) == [.messageHandle, .messageHandle])
        #expect(result.facts.map(\.fact.channel) == ["literal", "other"])
        #expect(result.facts.last?.fact.isDynamic == true)
        #expect(result.facts.first?.fact.method == nil)
        #expect(result.unscannedMessageChannels == 1)
    }

    @Test("수신자가 파라미터·필드라도 setMessageHandler 는 동적 이름의 사실과 범위를 남긴다")
    func unresolvedMessageReceiverKeepsFactAndScope() {
        let source = """
            func install(channel: BasicMessageChannel<Any?>) {
                channel.setMessageHandler { _, _ in }
            }
            """
        let result = BridgeFactScanner().scan(source: source, path: "/p/A.swift", messages: true)
        #expect(result.facts.map(\.fact.kind) == [.messageHandle])
        #expect(result.facts.first?.fact.channel == "channel")
        #expect(result.facts.first?.fact.isDynamic == true)
        #expect(result.facts.first?.fact.handlerScope != nil)
        #expect(result.handlerScopes.first?.scopes.count == 1)
    }

    @Test("메시지·이벤트 채널은 메서드 핸들러의 단일 채널 추측을 오염시키지 않는다")
    func otherChannelKindsDoNotContaminateMethodInference() {
        let source = """
            let basic = BasicMessageChannel<Any?>(name: "pigeon", binaryMessenger: m)
            let events = FlutterEventChannel(name: "stream", binaryMessenger: m)
            let channel = FlutterMethodChannel(name: "method", binaryMessenger: m)
            func handle(_ call: FlutterMethodCall, result: FlutterResult) {
                switch call.method {
                case "ping": result("pong")
                default: break
                }
            }
            """
        let result = BridgeFactScanner().scan(source: source, path: "/p/A.swift")
        let handled = result.facts.first { $0.fact.kind == .methodHandle }?.fact
        #expect(handled?.channel == "method")
        #expect(handled?.isChannelInferred == true)
    }

    @Test("qualified generic BasicMessageChannel과 읽기 전용 문자열 별칭을 해석한다")
    func resolvesQualifiedGenericMessageChannels() {
        let source = """
            let prefix = "dev.flutter.pigeon.CameraApi.method"
            let name = prefix
            let channel = Flutter.FlutterBasicMessageChannel<Any?, Any?>(name: name, binaryMessenger: m)
            channel.setMessageHandler { _, _ in }
            """
        let fact = BridgeFactScanner().scan(source: source, path: "/p/A.swift", messages: true).facts.first?.fact
        #expect(fact?.kind == .messageHandle)
        #expect(fact?.isDynamic == false)
        #expect(fact?.channel == "dev.flutter.pigeon.CameraApi.method")
    }

    @Test("보간 채널은 원문과 디코드한 선행 리터럴을 함께 보존한다")
    func preservesInterpolatedMessagePrefix() {
        let source = #"""
            let c = BasicMessageChannel<Any?>(name: "dev.flutter.pigeon.\u{1F4F7}\(suffix)", binaryMessenger: m)
            c.setMessageHandler { _, _ in }
            """#
        let fact = BridgeFactScanner().scan(source: source, path: "/p/A.swift", messages: true).facts.first?.fact
        #expect(fact?.isDynamic == true)
        #expect(fact?.channel == #""dev.flutter.pigeon.\u{1F4F7}\(suffix)""#)
        #expect(fact?.channelPrefix == "dev.flutter.pigeon.📷")
    }

    @Test("BasicMessageChannel 메서드 참조는 closure 범위 근거 없이 fallback한다")
    func messageMethodReferenceHasNoClosureScope() {
        let source = """
            let c = BasicMessageChannel<Any?>(name: "c", binaryMessenger: m)
            c.setMessageHandler(handler)
            """
        let fact = BridgeFactScanner().scan(source: source, path: "/p/A.swift", messages: true).facts.first?.fact
        #expect(fact?.kind == .messageHandle)
        #expect(fact?.handlerScope == nil)
        #expect(fact?.dependencies == nil)
    }

    @Test("events 선택은 setStreamHandler만 stream-handle로 내고 MethodChannel 사실은 버린다")
    func recordsStreamHandlersOnlyWhenOptedIn() {
        let source = """
            let events = FlutterEventChannel(name: "com.example/charging", binaryMessenger: m)
            events.setStreamHandler(self)
            let channel = FlutterMethodChannel(name: "com.example/battery", binaryMessenger: m)
            channel.setMethodCallHandler { call, result in
                switch call.method { case "getBatteryLevel": result(1) default: break }
            }
            let basic = BasicMessageChannel<Any?>(name: "pigeon", binaryMessenger: m)
            basic.setMessageHandler { _, _ in }
            """
        let result = BridgeFactScanner().scan(source: source, path: "/p/A.swift", events: true)
        #expect(result.facts.map(\.fact.kind) == [.streamHandle])
        #expect(result.facts.first?.fact.channel == "com.example/charging")
        #expect(result.facts.first?.fact.isDynamic == false)
        #expect(result.facts.first?.fact.method == nil)
    }

    @Test("풀지 못한 수신자의 setStreamHandler도 동적 이름의 사실로 남긴다")
    func unresolvedStreamReceiverKeepsFact() {
        let source = """
            func install(stream: FlutterStreamHandler, channel: FlutterEventChannel) {
                channel.setStreamHandler(stream)
            }
            """
        let result = BridgeFactScanner().scan(source: source, path: "/p/A.swift", events: true)
        #expect(result.facts.map(\.fact.kind) == [.streamHandle])
        #expect(result.facts.first?.fact.channel == "channel")
        #expect(result.facts.first?.fact.isDynamic == true)
    }

    @Test("nil 스트림 핸들러는 해제라 사실로 남기지 않는다")
    func nilStreamHandlerIsNotAFact() {
        let source = """
            let events = FlutterEventChannel(name: "com.example/charging", binaryMessenger: m)
            events.setStreamHandler(nil)
            """
        let result = BridgeFactScanner().scan(source: source, path: "/p/A.swift", events: true)
        #expect(result.facts.isEmpty)
    }

    @Test("다른 채널 종류로 증명된 수신자의 setStreamHandler는 사실로 남기지 않는다")
    func provenNonEventReceiverProducesNoStreamFact() {
        let source = """
            let methods = FlutterMethodChannel(name: "com.example/methods", binaryMessenger: m)
            methods.setStreamHandler(self)
            let basics = BasicMessageChannel<Any?>(name: "com.example/basic", binaryMessenger: m)
            basics.setStreamHandler(self)
            FlutterMethodChannel(name: "com.example/inline", binaryMessenger: m).setStreamHandler(self)
            """
        let result = BridgeFactScanner().scan(source: source, path: "/p/A.swift", events: true)
        #expect(result.facts.isEmpty)
    }

    @Test("channel: 인자보다 수신자의 증명된 종류가 우선이다")
    func provenReceiverBeatsChannelArgument() {
        let source = """
            let methods = FlutterMethodChannel(name: "com.example/methods", binaryMessenger: m)
            let events = FlutterEventChannel(name: "com.example/events", binaryMessenger: m)
            methods.setStreamHandler(self, channel: events)
            """
        let result = BridgeFactScanner().scan(source: source, path: "/p/A.swift", events: true)
        #expect(result.facts.isEmpty)
    }

    @Test("비교가 참임을 보장하지 않는 조건 형태의 if는 분기 근거를 붙이지 않는다")
    func negatedIfConditionCarriesNoBranchScope() throws {
        let source = """
            let channel = FlutterMethodChannel(name: "c", binaryMessenger: m)
            channel.setMethodCallHandler { call, result in
                if !(call.method == "a") { result(helperA()) }
                if call.method == "b" || flag { result(helperB()) }
                if call.method == "c" { result(helperC()) }
                if (call.method == "d") { result(helperD()) }
            }
            """
        let handled = facts(source, of: .methodHandle)
        // #require — 목록이 짧으면 아래 인덱싱이 트랩해 테스트 런 전체를 멈춘다.
        try #require(handled.map(\.method) == ["a", "b", "c", "d"])
        // 양성 대조군 — 그 `==` 인 조건과 괄호로 감싼 형태는 여전히 범위를 단다.
        // 없으면 "모든 if 에 범위가 안 붙는" 회귀도 이 테스트를 통과한다.
        #expect(handled[2].handlerScope != nil && handled[3].handlerScope != nil)
        #expect(handled[0].handlerScope == nil && handled[1].handlerScope == nil)
    }

    @Test("같은 절의 case 항목들은 같은 분기 범위를 나눈다")
    func siblingCaseItemsShareBranchScope() {
        let source = """
            let channel = FlutterMethodChannel(name: "c", binaryMessenger: m)
            channel.setMethodCallHandler { call, result in
                switch call.method {
                case "a":
                    result(helperA())
                case "b", "c":
                    result(helperB())
                default: break
                }
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.map(\.method) == ["a", "b", "c"])
        #expect(handled.allSatisfy { $0.handlerScope != nil })
        let scopes = handled.map { ($0.handlerScope!.start.line, $0.handlerScope!.end.line) }
        #expect(scopes[0] != scopes[1])
        #expect(scopes[1] == scopes[2])
    }

    @Test("if 조건의 메서드 비교는 then 본문을 분기 범위로 단다")
    func methodComparisonAttachesThenBodyScope() {
        let source = """
            let channel = FlutterMethodChannel(name: "c", binaryMessenger: m)
            channel.setMethodCallHandler { call, result in
                if call.method == "a" {
                    result(helperA())
                }
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.map(\.method) == ["a"])
        #expect(handled.first?.handlerScope != nil)
        // then 본문은 `if` 머리가 아니라 `{`(3행)에서 `}`(5행)까지다.
        #expect(handled.first?.handlerScope?.start.line == 3)
        #expect(handled.first?.handlerScope?.end.line == 5)
    }

    @Test("조건 위치가 아닌 메서드 비교는 범위 없이 사실만 남긴다")
    func nonConditionComparisonKeepsFactWithoutScope() {
        let source = """
            let channel = FlutterMethodChannel(name: "c", binaryMessenger: m)
            channel.setMethodCallHandler { call, result in
                let matches = call.method == "a"
                result(matches)
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.map(\.method) == ["a"])
        #expect(handled.first?.handlerScope == nil)
    }

    @Test("call.method 가 아닌 switch 는 건드리지 않는다")
    func ignoresUnrelatedSwitches() {
        let source = """
            switch state {
            case "idle": break
            default: break
            }
            """
        #expect(scan(source).isEmpty)
    }

    @Test("@objc(Name) 클래스는 module-export, 안의 @objc 메서드는 method-handle 이다")
    func recordsReactNativeModuleAndMethods() {
        let source = """
            @objc(CalendarManager)
            class CalendarManager: NSObject {
                @objc func addEvent(_ name: String, location: String) {}
                @objc(removeEvent:) func remove(_ name: String) {}
                func helper() {}
            }
            """
        let scanned = scan(source)
        let exported = scanned.filter { $0.fact.kind == .moduleExport }
        #expect(exported.map(\.fact.channel) == ["CalendarManager"])
        #expect(exported.first?.fact.target == .reactNative)
        #expect(exported.first?.declaration?.name == "CalendarManager")

        let handled = scanned.filter { $0.fact.kind == .methodHandle }
        #expect(handled.map(\.fact.method) == ["addEvent", "removeEvent"])
        #expect(handled.allSatisfy { $0.fact.channel == "CalendarManager" })
        #expect(handled.map(\.declaration?.indexName) == ["addEvent(_:location:)", "remove(_:)"])
    }

    @Test("@objcMembers 클래스는 Objective-C 에 보이는 메서드만 내보낸다")
    func objcMembersExportsVisibleMethods() {
        let source = """
            @objc(CalendarManager) @objcMembers
            class CalendarManager: NSObject {
                func addEvent(_ name: String) {
                    func format() -> String { "" }
                }
                private func helper() {}
                @objc private func explicitlyExposed() {}
                @nonobjc func swiftOnly() {}
                static func shared() {}
                func `default`() {}
                struct Nested { func notExported() {} }
            }
            extension CalendarManager {
                @objc func removeEvent(_ name: String) {}
                func plain() {}
            }
            private extension CalendarManager {
                func hidden() {}
            }
            """
        // 익스텐션은 클래스의 @objcMembers 를 물려받으므로 plain 도 나간다. 지역 함수·중첩 타입·
        // private 익스텐션·static 은 아니고, 명시적 @objc 가 붙은 private 은 나간다(SE-0186).
        #expect(facts(source, of: .methodHandle).map(\.method) == ["addEvent", "explicitlyExposed", "default", "removeEvent", "plain"])
    }

    @Test("이름 없는 @objc 클래스는 모듈로 보지 않는다")
    func ignoresUnnamedObjectiveCClasses() {
        let source = """
            @objc class Plain: NSObject {
                @objc func tap() {}
            }
            @objcMembers class AlsoPlain: NSObject {
                func tap() {}
            }
            """
        #expect(scan(source).isEmpty)
    }

    @Test("사실은 위치 순으로 정렬되어 두 번 훑어도 같다")
    func outputIsDeterministic() {
        let source = """
            FlutterMethodChannel(name: "b", binaryMessenger: m).setMethodCallHandler { _, _ in }
            FlutterMethodChannel(name: "a", binaryMessenger: m).setMethodCallHandler { _, _ in }
            """
        let first = scan(source)
        let second = scan(source)
        #expect(first == second)
        #expect(first.map(\.fact.location.line) == [1, 2])
    }

    // audioplayers 플러그인의 형태다. 파일 최상위 상수가 채널 이름이고, 프로퍼티는
    // init 인자로 채워지며, `handle` 은 `call` 을 그대로 넘겨 비동기 메서드가 분기한다.
    @Test("init 인자로 채워진 채널과 call 을 그대로 넘기는 한 홉 위임은 등록 채널에 붙는다")
    func injectedChannelAndForwardedHandler() {
        let source = """
            let channelName = "xyz.luan/audioplayers"
            let globalChannelName = "xyz.luan/audioplayers.global"
            class Plugin {
                var methods: FlutterMethodChannel
                var globalMethods: FlutterMethodChannel
                init(methodChannel: FlutterMethodChannel, globalMethodChannel: FlutterMethodChannel) {
                    self.methods = methodChannel
                    self.globalMethods = globalMethodChannel
                    self.globalMethods.setMethodCallHandler(handleGlobalMethodCall)
                }
                static func register(with registrar: FlutterPluginRegistrar) {
                    let methods = FlutterMethodChannel(name: channelName, binaryMessenger: m)
                    let globalMethods = FlutterMethodChannel(name: globalChannelName, binaryMessenger: m)
                    let instance = Plugin(methodChannel: methods, globalMethodChannel: globalMethods)
                    registrar.addMethodCallDelegate(instance, channel: methods)
                }
                func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    Task { await handleAsync(call, result: result) }
                }
                private func handleAsync(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
                    switch call.method {
                    case "pause": result(nil)
                    default: result(nil)
                    }
                }
                private func handleGlobalMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
                    Task { await handleGlobalAsync(call: call, result: result) }
                }
                private func handleGlobalAsync(call: FlutterMethodCall, result: @escaping FlutterResult) async {
                    switch call.method {
                    case "init": result(nil)
                    default: result(nil)
                    }
                }
            }
            """
        let handles = facts(source, of: .methodHandle)
        #expect(Set(handles.map(\.method)) == ["pause", "init"])
        #expect(handles.first { $0.method == "pause" }?.channel == "xyz.luan/audioplayers")
        #expect(handles.first { $0.method == "init" }?.channel == "xyz.luan/audioplayers.global")
        #expect(handles.allSatisfy { !$0.isDynamic && !$0.isChannelInferred })
        let registered = facts(source, of: .channelRegister)
        #expect(Set(registered.map(\.channel)) == ["xyz.luan/audioplayers", "xyz.luan/audioplayers.global"])
        #expect(registered.allSatisfy { !$0.isDynamic })
    }

    @Test("채널 이름의 문자열 연결은 양쪽이 리터럴이면 리터럴로 푼다")
    func concatenatedChannelName() {
        let source = """
            let base = "com.example/plugin"
            func attach(m: FlutterBinaryMessenger) {
                FlutterMethodChannel(name: base + "/methods", binaryMessenger: m).setMethodCallHandler { _, _ in }
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.first?.channel == "com.example/plugin/methods")
        #expect(registered.first?.isDynamic == false)
    }

    @Test("연결의 한쪽을 모르면 리터럴이 아닌 dynamic 으로 남긴다")
    func halfResolvedConcatenationStaysDynamic() {
        let source = """
            let base = "com.example/plugin"
            func attach(m: FlutterBinaryMessenger, suffix: String) {
                FlutterMethodChannel(name: base + suffix, binaryMessenger: m).setMethodCallHandler { _, _ in }
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.first?.isDynamic == true)
        #expect(registered.first?.channel != "com.example/plugin")
    }

    @Test("주입 프로퍼티에 다른 값의 호출 지점이나 다른 대입이 있으면 추측하지 않는다")
    func conflictingInjectionStaysUnknown() {
        let source = """
            class Plugin {
                var channel: FlutterMethodChannel
                init(c: FlutterMethodChannel) { self.channel = c }
                func attach() { channel.setMethodCallHandler { _, _ in } }
            }
            func one(m: FlutterBinaryMessenger) { Plugin(c: FlutterMethodChannel(name: "a", binaryMessenger: m)) }
            func two(m: FlutterBinaryMessenger) { Plugin(c: FlutterMethodChannel(name: "b", binaryMessenger: m)) }
            """
        #expect(facts(source, of: .channelRegister).first?.isDynamic == true)

        let reassigned = """
            class Plugin {
                var channel: FlutterMethodChannel
                init(c: FlutterMethodChannel) { self.channel = c }
                func swap(other: FlutterMethodChannel) { self.channel = other }
                func attach() { channel.setMethodCallHandler { _, _ in } }
            }
            func one(m: FlutterBinaryMessenger) { Plugin(c: FlutterMethodChannel(name: "a", binaryMessenger: m)) }
            """
        #expect(facts(reassigned, of: .channelRegister).first?.isDynamic == true)
    }

    @Test("위임받은 메서드를 서로 다른 채널의 핸들러가 부르면 채널을 고르지 않는다")
    func conflictingForwardersKeepChannelUnknown() {
        let source = """
            class Plugin {
                func attach(m: FlutterBinaryMessenger) {
                    FlutterMethodChannel(name: "a", binaryMessenger: m).setMethodCallHandler(handle1)
                    FlutterMethodChannel(name: "b", binaryMessenger: m).setMethodCallHandler(handle2)
                }
                func handle1(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    Task { await shared(call, result: result) }
                }
                func handle2(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    Task { await shared(call, result: result) }
                }
                private func shared(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
                    switch call.method {
                    case "x": result(nil)
                    default: result(nil)
                    }
                }
            }
            """
        let handles = facts(source, of: .methodHandle)
        #expect(handles.map(\.method) == ["x"])
        #expect(handles.first?.channel == nil)
        #expect(handles.first?.isChannelInferred == false)
    }

    @Test("call 이 아닌 값을 넘기는 호출은 위임으로 보지 않는다")
    func alteredArgumentIsNotForwarding() {
        let source = """
            class Plugin {
                func attach(c1: FlutterMethodChannel, c2: FlutterMethodChannel) {
                    c1.setMethodCallHandler(handle)
                }
                func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    Task { await shared(other, result: result) }
                }
                private func shared(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
                    switch call.method {
                    case "x": result(nil)
                    default: result(nil)
                    }
                }
            }
            """
        let handles = facts(source, of: .methodHandle)
        #expect(handles.map(\.method) == ["x"])
        #expect(handles.first?.channel == nil)
    }

    @Test("주입 프로퍼티와 같은 이름의 지역 파라미터는 주입 채널을 물려받지 않는다")
    func localParameterShadowsInjectedChannel() {
        let source = """
            class Plugin {
                var channel: FlutterMethodChannel
                init(c: FlutterMethodChannel) { self.channel = c }
                func attach(channel: FlutterMethodChannel) { channel.setMethodCallHandler { _, _ in } }
            }
            func make(m: FlutterBinaryMessenger) {
                Plugin(c: FlutterMethodChannel(name: "injected", binaryMessenger: m))
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.first?.isDynamic == true)
        #expect(registered.first?.channel != "injected")
    }

    @Test("주입 레이블을 쓰지 않는 생성자 호출이 있으면 채널을 단정하지 않는다")
    func unlabelledConstructorCallStaysUnknown() {
        let source = """
            class Plugin {
                var channel = FlutterMethodChannel(name: "fallback", binaryMessenger: m)
                init(c: FlutterMethodChannel) { self.channel = c }
                init(other: Int) {}
                func attach() { channel.setMethodCallHandler { _, _ in } }
            }
            func a(m: FlutterBinaryMessenger) { Plugin(c: FlutterMethodChannel(name: "a", binaryMessenger: m)) }
            func b() { Plugin(other: 1) }
            """
        // `Plugin(other:)` 은 `c` 를 거치지 않으므로 그 인스턴스의 채널은 "a" 가 아니다.
        #expect(facts(source, of: .channelRegister).first?.isDynamic == true)
    }

    @Test("Type.init 으로 쓴 생성자 호출도 주입 호출 지점이다")
    func explicitInitConstructorCallResolvesInjection() {
        let source = """
            class Plugin {
                var channel: FlutterMethodChannel
                init(c: FlutterMethodChannel) { self.channel = c }
                func attach() { channel.setMethodCallHandler { _, _ in } }
            }
            func make(m: FlutterBinaryMessenger) {
                Plugin.init(c: FlutterMethodChannel(name: "via-init", binaryMessenger: m))
            }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.first?.channel == "via-init")
        #expect(registered.first?.isDynamic == false)
    }

    @Test("self 아닌 수신자에 같은 이름 프로퍼티가 대입되면 주입 채널을 단정하지 않는다")
    func otherReceiverAssignmentInvalidatesInjection() {
        let source = """
            class Plugin {
                var channel: FlutterMethodChannel
                init(c: FlutterMethodChannel) { self.channel = c }
                func attach() { channel.setMethodCallHandler { _, _ in } }
            }
            func make(m: FlutterBinaryMessenger) {
                Plugin(c: FlutterMethodChannel(name: "a", binaryMessenger: m))
            }
            func rewrite(_ peer: Plugin, with other: FlutterMethodChannel) { peer.channel = other }
            """
        #expect(facts(source, of: .channelRegister).first?.isDynamic == true)
    }

    @Test("본문 안 클로저가 call 이름을 다시 선언하면 위임으로 세지 않는다")
    func closureShadowedCallIsNotForwarding() {
        let source = """
            class Plugin {
                func setup(m: FlutterBinaryMessenger) {
                    let c = FlutterMethodChannel(name: "fixed", binaryMessenger: m)
                    let other = FlutterMethodChannel(name: "other", binaryMessenger: m)
                    c.setMethodCallHandler(handle)
                }
                func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    [call].forEach { call in Task { await handleAsync(call, result: result) } }
                }
                private func handleAsync(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
                    switch call.method {
                    case "ping": result(nil)
                    default: result(nil)
                    }
                }
            }
            """
        let handles = facts(source, of: .methodHandle)
        #expect(handles.map(\.method) == ["ping"])
        #expect(handles.first?.channel == nil)
    }

    @Test("call 을 FlutterMethodCall 자리가 아닌 다른 인자로 넘기면 위임으로 세지 않는다")
    func callPassedToOtherPositionIsNotForwarding() {
        let source = """
            class Plugin {
                func setup(m: FlutterBinaryMessenger) {
                    let c = FlutterMethodChannel(name: "fixed", binaryMessenger: m)
                    let other = FlutterMethodChannel(name: "other", binaryMessenger: m)
                    c.setMethodCallHandler(handle)
                }
                func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                    Task { await shared(result, context: call) }
                }
                private func shared(_ call: FlutterMethodCall, context: FlutterMethodCall,
                                    result: @escaping FlutterResult) async {
                    switch call.method {
                    case "ping": result(nil)
                    default: result(nil)
                    }
                }
            }
            """
        let handles = facts(source, of: .methodHandle)
        #expect(handles.map(\.method) == ["ping"])
        #expect(handles.first?.channel == nil)
    }

    @Test("합친 이름이 채널이 될 수 없는 크기면 리터럴로 단정하지 않는다")
    func oversizedConcatenationStaysDynamic() {
        let chunk = String(repeating: "x", count: 3000)
        let source = """
            let a = "\(chunk)"
            func attach(m: FlutterBinaryMessenger) {
                FlutterMethodChannel(name: a + a, binaryMessenger: m).setMethodCallHandler { _, _ in }
            }
            """
        #expect(facts(source, of: .channelRegister).first?.isDynamic == true)
    }

    @Test("갈라지는 별칭 연결 사슬도 결과 크기 제한 안에서 끝난다")
    func branchingAliasChainTerminates() {
        var lines = ["let a0 = \"x\""]
        for index in 1...40 { lines.append("let a\(index) = a\(index - 1) + a\(index - 1)") }
        lines.append("""
            func attach(m: FlutterBinaryMessenger) {
                FlutterMethodChannel(name: a40, binaryMessenger: m).setMethodCallHandler { _, _ in }
            }
            """)
        // 메모가 없으면 2⁴⁰ 번 풀고, 크기 제한이 없으면 2⁴⁰ 바이트를 만든다.
        #expect(facts(lines.joined(separator: "\n"), of: .channelRegister).first?.isDynamic == true)
    }

    // MARK: Expo Modules

    @Test("Expo Module 클래스는 mechanism이 expo인 module-export를 낸다")
    func expoModuleExport() {
        let source = """
            import ExpoModulesCore

            public class PhotoModule: Module {
                public func definition() -> ModuleDefinition {
                    Name("ExpoPhoto")
                    Function("pick") { (filter: String) in filter }
                    AsyncFunction("upload") { _ in }
                }
            }
            """
        let scanned = scan(source)
        let exported = scanned.filter { $0.fact.kind == .moduleExport }
        #expect(exported.count == 1)
        #expect(exported.first?.fact.channel == "ExpoPhoto")
        #expect(exported.first?.fact.mechanism == .expo)
        #expect(exported.first?.fact.target == .reactNative)
        #expect(exported.first?.fact.isDynamic == false)
        #expect(exported.first?.declaration?.name == "PhotoModule")

        // Function 계열은 JS 메서드지만 이름 경계 사실이 아니라 mechanism을 싣지 않는다.
        let handled = scanned.filter { $0.fact.kind == .methodHandle }
        #expect(handled.map(\.fact.method) == ["pick", "upload"])
        #expect(handled.allSatisfy { $0.fact.channel == "ExpoPhoto" && $0.fact.mechanism == nil })
    }

    @Test("Name이 없으면 모듈 이름은 클래스 이름이다")
    func expoModuleNameDefaultsToClassName() {
        let source = """
            import ExpoModulesCore

            class BatteryModule: Module {
                func definition() -> ModuleDefinition {
                    Function("level") { 0 }
                }
            }
            """
        let exported = facts(source, of: .moduleExport)
        #expect(exported.map(\.channel) == ["BatteryModule"])
        #expect(exported.first?.mechanism == .expo)
    }

    @Test("마지막 Name 호출이 모듈 이름을 덮어쓴다")
    func expoModuleLastNameWins() {
        let source = """
            import ExpoModulesCore

            class SoundModule: Module {
                func definition() -> ModuleDefinition {
                    Name("first")
                    Name("ExpoSound")
                }
            }
            """
        #expect(facts(source, of: .moduleExport).map(\.channel) == ["ExpoSound"])
    }

    @Test("View 정의가 있으면 모듈 이름으로 component-export를 낸다")
    func expoViewComponentExport() {
        let source = """
            import ExpoModulesCore

            class PhotoModule: Module {
                func definition() -> ModuleDefinition {
                    Name("ExpoPhoto")
                    View(PhotoView.self) {
                        Prop("url") { view, url in }
                    }
                }
            }
            """
        let components = facts(source, of: .componentExport)
        // JS 의 requireNativeViewManager 는 모듈 이름으로 기본 뷰를 찾는다.
        #expect(components.count == 1)
        #expect(components.first?.channel == "ExpoPhoto")
        #expect(components.first?.mechanism == .expo)
    }

    @Test("ExpoModule 매크로 모듈은 인자 이름과 JS 메서드를 낸다")
    func expoMacroModule() {
        let source = """
            import ExpoModulesCore

            @ExpoModule("ExpoCrypto")
            class CryptoModule {
                @JS func digest(_ input: String) -> String { input }
                @JS("sign") func signData(_ data: String) -> String { data }
                @JS(.concurrent) func slow() {}
                func helper() {}
            }
            """
        let scanned = scan(source)
        let exported = scanned.filter { $0.fact.kind == .moduleExport }
        #expect(exported.map(\.fact.channel) == ["ExpoCrypto"])
        #expect(exported.first?.fact.mechanism == .expo)

        let handled = scanned.filter { $0.fact.kind == .methodHandle }
        // @JS(.concurrent) 의 첫 인자는 옵션이라 이름이 아니다 — 함수 이름으로 둔다.
        #expect(handled.map(\.fact.method) == ["digest", "sign", "slow"])
    }

    @Test("ExpoModule 매크로 인자가 없으면 클래스 이름이다")
    func expoMacroModuleDefaultName() {
        let source = """
            import ExpoModulesCore

            @ExpoModule
            class SensorModule {
                @JS func read() {}
            }
            """
        #expect(facts(source, of: .moduleExport).map(\.channel) == ["SensorModule"])
    }

    @Test("ExpoModulesCore를 임포트하지 않은 Module 상속은 사실을 내지 않는다")
    func ignoresModuleInheritanceWithoutExpoImport() {
        let source = """
            class Plugin: Module {
                func definition() -> ModuleDefinition {
                    Name("Wrong")
                }
            }
            """
        #expect(scan(source).isEmpty)
    }

    @Test("definition 밖의 동명 호출은 Expo 사실로 보지 않는다")
    func ignoresLookalikeCallsOutsideDefinition() {
        let source = """
            import ExpoModulesCore

            class Helper {
                func definition() -> Int { 0 }
                func build() {
                    Name("not-a-module")
                    View {}
                }
            }
            """
        #expect(scan(source).isEmpty)
    }

    @Test("definition 안 클로저의 동명 호출은 DSL 문장이 아니다")
    func ignoresNestedClosureCalls() {
        let source = """
            import ExpoModulesCore

            class CameraModule: Module {
                func definition() -> ModuleDefinition {
                    Function("snap") {
                        Name("inner")
                        print("x")
                    }
                }
            }
            """
        let exported = facts(source, of: .moduleExport)
        // 클로저 안의 Name은 모듈 이름이 아니므로 기본값인 클래스 이름이 남는다.
        #expect(exported.map(\.channel) == ["CameraModule"])
        #expect(facts(source, of: .methodHandle).map(\.method) == ["snap"])
    }

    @Test("멤버 체인이 붙은 DSL 호출도 JS 메서드다")
    func expoDSLCallWithMemberChain() {
        // expo-haptics 처럼 AsyncFunction(…) {…}.runOnQueue(.main) 형태다.
        // 안쪽 호출이 바깥 호출의 callee 자리에 서도 체인 전체가 직접 문장이면
        // DSL 문장이다.
        let source = """
            import ExpoModulesCore

            class HapticsModule: Module {
                func definition() -> ModuleDefinition {
                    Name("ExpoHaptics")
                    AsyncFunction("notify") { (type: String) in type }
                        .runOnQueue(.main)
                    Function("sync") { 0 }.runOnQueue(.utility)
                }
            }
            """
        let handled = facts(source, of: .methodHandle)
        #expect(handled.map(\.method) == ["notify", "sync"])
        #expect(handled.allSatisfy { $0.channel == "ExpoHaptics" })
    }

    @Test("다른 호출의 인자인 DSL 호출은 문장이 아니다")
    func expoDSLCallAsArgumentIsNotAStatement() {
        // callee 통과를 허용해도 인자 자리는 여전히 DSL 문장이 아니다.
        let source = """
            import ExpoModulesCore

            class HapticsModule: Module {
                func definition() -> ModuleDefinition {
                    Name("ExpoHaptics")
                    print(AsyncFunction("hidden") { 0 })
                }
            }
            """
        #expect(facts(source, of: .methodHandle).isEmpty)
    }

    @Test("인자 자리의 멤버 체인 DSL 호출도 문장이 아니다")
    func expoChainedDSLCallAsArgumentIsNotAStatement() {
        // 체인 꼭대기 호출이 인자면 안쪽 DSL 호출도 인자다.
        let source = """
            import ExpoModulesCore

            class HapticsModule: Module {
                func definition() -> ModuleDefinition {
                    Name("ExpoHaptics")
                    print(AsyncFunction("hidden") { 0 }.runOnQueue(.main))
                }
            }
            """
        #expect(facts(source, of: .methodHandle).isEmpty)
    }

    @Test("DSL 클로저 안의 멤버 체인 호출은 문장이 아니다")
    func expoChainedDSLCallInsideClosureIsNotAStatement() {
        let source = """
            import ExpoModulesCore

            class HapticsModule: Module {
                func definition() -> ModuleDefinition {
                    Function("snap") {
                        AsyncFunction("inner") { 0 }.runOnQueue(.main)
                    }
                }
            }
            """
        #expect(facts(source, of: .methodHandle).map(\.method) == ["snap"])
    }

    @Test("definition을 찾지 못한 Expo 모듈은 이름을 동적으로 남긴다")
    func expoModuleWithoutVisibleDefinitionIsDynamic() {
        let source = """
            import ExpoModulesCore

            class LocationModule: Module {
            }
            """
        let exported = facts(source, of: .moduleExport)
        #expect(exported.count == 1)
        #expect(exported.first?.mechanism == .expo)
        // 다른 파일의 익스텐션에 Name() 이 있을 수 있어 리터럴로 확정하지 않는다.
        #expect(exported.first?.isDynamic == true)
        #expect(exported.first?.channel == "LocationModule")
    }

    @Test("클래스가 없는 파일의 익스텐션 definition도 Expo 모듈이다")
    func expoModuleDefinedInExtensionOnly() {
        let source = """
            import ExpoModulesCore

            extension RemoteModule {
                func definition() -> ModuleDefinition {
                    Name("ExpoRemote")
                    Function("ping") { true }
                }
            }
            """
        let scanned = scan(source)
        let exported = scanned.filter { $0.fact.kind == .moduleExport }
        #expect(exported.map(\.fact.channel) == ["ExpoRemote"])
        #expect(exported.first?.fact.mechanism == .expo)
        #expect(facts(source, of: .methodHandle).map(\.method) == ["ping"])
    }

    @Test("Expo 모듈과 코어 RN 모듈은 같은 파일에서 구분된다")
    func expoAndCoreModulesInOneFile() {
        let source = """
            import ExpoModulesCore

            @objc(LegacyManager)
            class LegacyManager: NSObject {
                @objc func oldWay() {}
            }

            class ModernModule: Module {
                func definition() -> ModuleDefinition {
                    Name("ExpoModern")
                }
            }
            """
        let exported = facts(source, of: .moduleExport)
        #expect(exported.count == 2)
        let core = exported.first { $0.channel == "LegacyManager" }
        let expo = exported.first { $0.channel == "ExpoModern" }
        #expect(core?.mechanism == nil)
        #expect(expo?.mechanism == .expo)
    }

    @Test("익스텐션의 definition도 ExpoModulesCore 임포트 없이는 Expo 사실이 아니다")
    func extensionDefinitionRequiresExpoImport() {
        let source = """
            extension RemoteModule {
                func definition() -> ModuleDefinition {
                    Name("ExpoRemote")
                    Function("ping") { true }
                }
            }
            """
        #expect(scan(source).isEmpty)
    }

    @Test("같은 타입의 익스텐션이 여러 개여도 Expo 사실은 한 번만 낸다")
    func conformanceAndPlainExtensionDoNotDoubleEmit() {
        let source = """
            import ExpoModulesCore

            extension CounterModule: Module {
                func definition() -> ModuleDefinition {
                    Name("Counter")
                    Function("tick") { true }
                }
            }
            extension CounterModule {
                func increment() {}
            }
            """
        let scanned = scan(source)
        #expect(scanned.filter { $0.fact.kind == .moduleExport }.count == 1)
        #expect(scanned.filter { $0.fact.kind == .methodHandle }.map(\.fact.method) == ["tick"])
    }

    @Test("비-Expo 클래스의 definition을 익스텐션이 Expo 증거로 쓰지 않는다")
    func plainClassDefinitionIsNotExtensionEvidence() {
        let source = """
            import ExpoModulesCore

            class Weird {
                func definition() -> ModuleDefinition {
                    Function("go") { true }
                }
            }
            extension Weird {
                func unrelated() {}
            }
            """
        #expect(scan(source).filter { $0.fact.mechanism == .expo }.isEmpty)
    }

    @Test("@JS의 한정 옵션 인자는 메서드 이름이 아니라 함수 이름 폴백이다")
    func qualifiedJSOptionFallsBackToFunctionName() {
        let source = """
            import ExpoModulesCore

            @ExpoModule
            class SensorModule {
                @JS(JSMethodOptions.concurrent) func measure() {}
            }
            """
        let methods = facts(source, of: .methodHandle)
        #expect(methods.map(\.method) == ["measure"])
    }

    @Test("@ExpoModule의 라벨 붙은 첫 인자는 모듈 이름이 아니다")
    func labeledExpoModuleArgumentIsNotTheName() {
        let source = """
            import ExpoModulesCore

            @ExpoModule(classes: [SensorView.self])
            class SensorModule {}
            """
        let exported = facts(source, of: .moduleExport)
        #expect(exported.map(\.channel) == ["SensorModule"])
    }
}
