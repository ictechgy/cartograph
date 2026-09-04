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

    @Test("FlutterPlugin 스타일에서는 파일에 채널이 하나면 handle 메서드의 case 가 추측으로 그 채널에 붙는다")
    func fallsBackToSingleChannelInFile() {
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
        #expect(handled.first?.fact.isChannelInferred == true)
        // 클로저가 아니라 메서드 안이므로 감싸는 선언은 `handle` 이다.
        #expect(handled.first?.declaration?.name == "handle")
        #expect(handled.first?.declaration?.indexName == "handle(_:result:)")
        #expect(handled.first?.declaration?.qualifiedName == "CameraPlugin.handle")
        #expect(handled.first?.declaration?.line == 6)
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

    @Test("한 단계 상수는 따라가고 그 이상은 dynamic 으로 남긴다")
    func followsOneLevelOfConstants() {
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
        #expect(registered.map(\.channel) == ["com.example/camera", "name", "prefix + \"/camera\""])
        #expect(registered.map(\.isDynamic) == [false, true, true])
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
}
