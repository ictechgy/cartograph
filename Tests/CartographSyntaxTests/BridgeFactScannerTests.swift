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

    @Test("다른 수신자의 같은 이름 멤버는 이 파일의 상수로 풀지 않는다")
    func doesNotStealConstantsAcrossReceivers() {
        // `external.channelName` 의 `external` 은 다른 파일의 타입이다. 이름만 보고 풀면
        // 조인 가능한 리터럴로 위장한 틀린 사실이 나간다.
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
        #expect(registered.map(\.channel) == ["external.channelName", "com.example/camera", "com.example/camera"])
        #expect(registered.map(\.isDynamic) == [true, false, false])
    }

    @Test("같은 이름의 상수가 다른 값으로 두 번 있으면 모른다고 한다")
    func refusesToGuessBetweenConflictingConstants() {
        let source = """
            struct A { static let name = "a" }
            struct B { static let name = "b" }
            FlutterMethodChannel(name: B.name, binaryMessenger: m).setMethodCallHandler { _, _ in }
            """
        let registered = facts(source, of: .channelRegister)
        #expect(registered.first?.isDynamic == true)
        #expect(registered.first?.channel == "B.name")
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

    @Test("FlutterEventChannel 은 읽지 않고 세기만 한다")
    func countsEventChannels() {
        let source = """
            let events = FlutterEventChannel(name: "com.example/events", binaryMessenger: m)
            events.setStreamHandler(self)
            """
        let result = BridgeFactScanner().scan(source: source, path: "/p/A.swift")
        #expect(result.facts.isEmpty)
        #expect(result.unscannedEventChannels == 1)
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

    @Test("@objcMembers 클래스는 표식 없는 메서드도 내보낸다")
    func objcMembersExportsEveryMethod() {
        let source = """
            @objc(CalendarManager) @objcMembers
            class CalendarManager: NSObject {
                func addEvent(_ name: String) {}
                func helper() {}
            }
            """
        #expect(facts(source, of: .methodHandle).map(\.method) == ["addEvent", "helper"])
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
