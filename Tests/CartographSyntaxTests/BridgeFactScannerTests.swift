import CartographCore
@testable import CartographSyntax
import Testing

@Suite("브리지 사실 스캐너")
struct BridgeFactScannerTests {
    private func scan(_ source: String, path: String = "/p/Plugin.swift") -> [ScannedBridgeFact] {
        BridgeFactScanner().scan(source: source, path: path)
    }

    private func facts(_ source: String, of kind: BridgeFact.Kind) -> [BridgeFact] {
        scan(source).map(\.fact).filter { $0.kind == kind }
    }

    @Test("FlutterMethodChannel 생성은 채널 이름과 함께 channel-create 로 기록된다")
    func recordsChannelCreation() {
        let source = """
            import Flutter
            final class CameraPlugin {
                let channel = FlutterMethodChannel(name: "com.example/camera", binaryMessenger: messenger)
            }
            """
        let created = facts(source, of: .channelCreate)
        #expect(created.count == 1)
        #expect(created.first?.channel == "com.example/camera")
        #expect(created.first?.target == .flutter)
        #expect(created.first?.isDynamic == false)
        #expect(created.first?.location == SourceLocation(path: "/p/Plugin.swift", line: 3, column: 19))
    }

    @Test("setMethodCallHandler 는 수신자 변수를 따라 채널 이름을 찾는다")
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
        #expect(handled.allSatisfy { !$0.isDynamic })
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

    @Test("FlutterPlugin 스타일에서는 파일에 채널이 하나면 handle 메서드의 case 가 그 채널에 붙는다")
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
        // 클로저가 아니라 메서드 안이므로 감싸는 선언은 `handle` 이다.
        #expect(handled.first?.declaration?.name == "handle")
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
    }

    @Test("한 단계 상수는 따라가고 그 이상은 dynamic 으로 남긴다")
    func followsOneLevelOfConstants() {
        let source = """
            enum Channels {
                static let camera = "com.example/camera"
            }
            let name = Channels.camera
            let direct = FlutterMethodChannel(name: Channels.camera, binaryMessenger: m)
            let indirect = FlutterMethodChannel(name: name, binaryMessenger: m)
            let computed = FlutterMethodChannel(name: prefix + "/camera", binaryMessenger: m)
            """
        let created = facts(source, of: .channelCreate)
        #expect(created.map(\.channel) == ["com.example/camera", "name", "prefix + \"/camera\""])
        #expect(created.map(\.isDynamic) == [false, true, true])
    }

    @Test("같은 이름의 상수가 다른 값으로 두 번 있으면 모른다고 한다")
    func refusesToGuessBetweenConflictingConstants() {
        let source = """
            struct A { static let name = "a" }
            struct B { static let name = "b" }
            let channel = FlutterMethodChannel(name: B.name, binaryMessenger: m)
            """
        let created = facts(source, of: .channelCreate)
        #expect(created.first?.isDynamic == true)
        #expect(created.first?.channel == "B.name")
    }

    @Test("보간이 있는 리터럴은 dynamic 이다")
    func treatsInterpolationAsDynamic() {
        let source = """
            let channel = FlutterMethodChannel(name: "com.example/\\(feature)", binaryMessenger: m)
            """
        let created = facts(source, of: .channelCreate)
        #expect(created.first?.isDynamic == true)
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

    @Test("인라인으로 만든 채널에 바로 핸들러를 달아도 생성과 등록을 모두 기록한다")
    func recordsInlineChannelRegistration() {
        let source = """
            FlutterMethodChannel(name: "c", binaryMessenger: m).setMethodCallHandler { call, result in
                switch call.method {
                case "ping": result("pong")
                default: break
                }
            }
            """
        let kinds = scan(source).map(\.fact.kind)
        #expect(kinds == [.channelCreate, .channelRegister, .methodHandle])
        #expect(facts(source, of: .methodHandle).first?.channel == "c")
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
        #expect(handled.map(\.declaration?.name) == ["addEvent", "remove"])
    }

    @Test("이름 없는 @objc 클래스는 모듈로 보지 않는다")
    func ignoresUnnamedObjectiveCClasses() {
        let source = """
            @objc class Plain: NSObject {
                @objc func tap() {}
            }
            """
        #expect(scan(source).isEmpty)
    }

    @Test("사실은 위치 순으로 정렬되어 두 번 훑어도 같다")
    func outputIsDeterministic() {
        let source = """
            let b = FlutterMethodChannel(name: "b", binaryMessenger: m)
            let a = FlutterMethodChannel(name: "a", binaryMessenger: m)
            """
        let first = scan(source)
        let second = scan(source)
        #expect(first == second)
        #expect(first.map(\.fact.location.line) == [1, 2])
    }
}
