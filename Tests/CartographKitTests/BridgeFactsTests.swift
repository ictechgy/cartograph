import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("브리지 사실 문서")
struct BridgeFactsTests {
    private static let pluginSource = """
        import Flutter
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

    private static let moduleSource = """
        @implementation RNCalendar
        RCT_EXPORT_MODULE(Calendar)
        RCT_EXPORT_METHOD(addEvent:(NSString *)name) {}
        @end
        """

    private func makeService(files: [String: String], snapshot: IndexSnapshot) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        return CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(files: files),
                indexProviderOverride: StaticIndexProvider(snapshot)
            )
        )
    }

    private func makeSnapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder(module: "App", path: "/p/Sources/CameraPlugin.swift")
        builder.symbol("s:CameraPlugin", name: "CameraPlugin", kind: .classType, line: 2)
        builder.symbol("s:register", name: "register(with:)", kind: .method, line: 3, parent: "s:CameraPlugin")
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method, line: 7, parent: "s:CameraPlugin")
        return builder.build()
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_788_480_000)

    @Test("교환 문서의 사실 위치는 프로젝트 상대 경로다")
    func bridgeFactLocationsAreProjectRelative() throws {
        let service = makeService(
            files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource],
            snapshot: makeSnapshot()
        )

        let document = try service.bridgeFacts(generatedAt: fixedDate)

        #expect(document.facts.map(\.location.path) == [
            "Sources/CameraPlugin.swift",
            "Sources/CameraPlugin.swift",
        ])
    }

    @Test("교환 문서의 생성 시각은 UTC 밀리초 형식이다")
    func bridgeFactsUseUTCMillisecondTimestamp() throws {
        let service = makeService(files: ["/p/Sources/A.swift": "struct A {}"], snapshot: IndexSnapshot())

        let document = try service.bridgeFacts(generatedAt: fixedDate)

        #expect(document.generatedAt == "2026-09-04T00:00:00.000Z")
    }

    @Test("구문에서 찾은 사실에 인덱스의 USR 이 붙는다")
    func attachesIndexUSRs() throws {
        let service = makeService(
            files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource],
            snapshot: makeSnapshot()
        )
        let document = try service.bridgeFacts(generatedAt: fixedDate)
        let handled = try #require(document.facts.first { $0.kind == "method-handle" })
        #expect(handled.symbol?.usr == "s:handle")
        // 표기는 계약의 것(`CameraPlugin.register`)이다. 인덱스의 표기는 USR 이 대신한다.
        #expect(handled.symbol?.qualifiedName == "CameraPlugin.handle")
        #expect(handled.channel == "com.example/camera")
        #expect(handled.method == "takePhoto")

        let registered = try #require(document.facts.first { $0.kind == "channel-register" })
        #expect(registered.symbol?.usr == "s:register")
        #expect(document.limitations.contains { $0.hasPrefix("inferred-channels: 1") })
        #expect(!document.limitations.contains { $0.hasPrefix("missing-handler-usrs") })
    }

    @Test("오버로드가 있으면 인자 라벨까지 같은 선언에 USR 을 붙인다")
    func prefersFullSelectorOverNearestLine() throws {
        // `handle(_:)` 이 줄로는 더 가깝다. 기본 이름만 보면 그쪽에 붙는다.
        var builder = SnapshotBuilder(module: "App", path: "/p/Sources/CameraPlugin.swift")
        builder.symbol("s:CameraPlugin", name: "CameraPlugin", kind: .classType, line: 2)
        builder.symbol("s:handleOne", name: "handle(_:)", kind: .method, line: 6, parent: "s:CameraPlugin")
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method, line: 20, parent: "s:CameraPlugin")
        let service = makeService(files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource], snapshot: builder.build())
        let handled = try #require(try service.bridgeFacts(generatedAt: fixedDate).facts.first { $0.kind == "method-handle" })
        #expect(handled.symbol?.usr == "s:handle")
    }

    @Test("인덱스에 없는 선언은 구문의 이름만 남고 한계로 센다")
    func reportsUnresolvedSymbols() throws {
        let service = makeService(
            files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource],
            snapshot: IndexSnapshot()
        )
        let document = try service.bridgeFacts(generatedAt: fixedDate)
        #expect(document.facts.allSatisfy { $0.symbol?.usr == nil })
        #expect(document.facts.first?.symbol?.qualifiedName == "CameraPlugin.register")
        #expect(document.limitations.contains { $0 == "missing-handler-usrs: 1 method handlers have only a qualified name" })
    }

    @Test("Objective-C 의 RN 매크로도 함께 담기고 대상은 다수결이다")
    func mergesObjectiveCFactsAndPicksMajorityTarget() throws {
        let service = makeService(
            files: [
                "/p/Sources/CameraPlugin.swift": Self.pluginSource,
                "/p/ios/RNCalendar.m": Self.moduleSource,
            ],
            snapshot: makeSnapshot()
        )
        let document = try service.bridgeFacts(generatedAt: fixedDate)
        #expect(document.facts.map(\.kind) == ["channel-register", "method-handle", "module-export", "method-handle"])
        #expect(document.target == "flutter")
        #expect(document.limitations.contains {
            $0.hasPrefix("mixed-targets: ") && $0.contains("flutter 2, react-native 2") && $0.contains("counts tie")
        })
        // Objective-C 쪽 사실은 선언 정보 자체가 없다. "USR 없는 핸들러" 가 아니라 따로 센다.
        #expect(!document.limitations.contains { $0.hasPrefix("missing-handler-usrs") })
        #expect(document.limitations.contains { $0.hasPrefix("objective-c-handlers: 1") })
    }

    @Test("사실이 없으면 대상은 null 로 적히고 한계는 없다")
    func emptyProjectIsQuiet() throws {
        let service = makeService(files: ["/p/Sources/A.swift": "struct A {}"], snapshot: IndexSnapshot())
        let document = try service.bridgeFacts(generatedAt: fixedDate)
        #expect(document.facts.isEmpty)
        #expect(document.target == nil)
        #expect(document.limitations.isEmpty)
        // 계약은 키 생략이 아니라 null 이다.
        let json = try service.exportBridgeFacts(generatedAt: fixedDate).output
        #expect(json.contains("\"target\" : null"))
    }

    @Test("라벨이 안 맞고 기본 이름이 같은 후보가 여럿이면 USR 을 붙이지 않는다")
    func refusesAmbiguousBaseNameFallback() throws {
        var builder = SnapshotBuilder(module: "App", path: "/p/Sources/CameraPlugin.swift")
        builder.symbol("s:CameraPlugin", name: "CameraPlugin", kind: .classType, line: 2)
        builder.symbol("s:handleOne", name: "handle(_:)", kind: .method, line: 6, parent: "s:CameraPlugin")
        builder.symbol("s:handleTwo", name: "handle(_:reply:)", kind: .method, line: 20, parent: "s:CameraPlugin")
        let service = makeService(files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource], snapshot: builder.build())
        let handled = try #require(try service.bridgeFacts(generatedAt: fixedDate).facts.first { $0.kind == "method-handle" })
        #expect(handled.symbol?.usr == nil)
        #expect(handled.symbol?.qualifiedName == "CameraPlugin.handle")
    }

    @Test("인덱스 경로와 디스크 경로의 표기가 달라도 USR 이 붙는다")
    func attachesUSRsAcrossPathSpellings() throws {
        // 인덱스는 `/private/tmp` 로, 디스크 걷기는 `/tmp` 로 같은 곳을 가리킨다. macOS 의 실제 상황이다.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cartograph-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("CameraPlugin.swift")
        try Self.pluginSource.write(to: file, atomically: true, encoding: .utf8)
        let resolved = file.resolvingSymlinksInPath().path
        guard resolved != file.path else { return }

        var builder = SnapshotBuilder(module: "App", path: resolved)
        builder.symbol("s:CameraPlugin", name: "CameraPlugin", kind: .classType, line: 2)
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method, line: 7, parent: "s:CameraPlugin")
        var configuration = CartographConfiguration.default
        configuration.projectPath = directory.path
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(indexProviderOverride: StaticIndexProvider(builder.build()))
        )
        let handled = try #require(try service.bridgeFacts(generatedAt: fixedDate).facts.first { $0.kind == "method-handle" })
        #expect(handled.symbol?.usr == "s:handle")
    }

    @Test("JSON 은 계약의 머리말을 담고 키가 정렬되어 두 번 인코딩해도 같다")
    func jsonFollowsExchangeFormat() throws {
        let service = makeService(
            files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource],
            snapshot: makeSnapshot()
        )
        let first = try service.exportBridgeFacts(generatedAt: fixedDate).output
        let second = try service.exportBridgeFacts(generatedAt: fixedDate).output
        #expect(first == second)
        #expect(first.contains("\"format\" : \"bridge-facts\""))
        #expect(first.contains("\"version\" : 1"))
        #expect(first.contains("\"platform\" : \"swift\""))
        #expect(first.contains("\"generatedAt\" : \"2026-09-04T00:00:00.000Z\""))
        #expect(first.contains("\"dynamic\" : false"))

        let decoded = try JSONDecoder().decode(BridgeFactsDocument.self, from: Data(first.utf8))
        #expect(decoded.facts.count == 2)
    }

    @Test("@objc(Name) 클래스와 이벤트 채널은 한계로 센다")
    func countsAssumedModulesAndEventChannels() throws {
        let source = """
            @objc(Coordinator) class Coordinator: NSObject { @objc func start() {} }
            let events = FlutterEventChannel(name: "e", binaryMessenger: m)
            let pigeon = BasicMessageChannel<Any?>(name: "p", binaryMessenger: m)
            """
        let service = makeService(files: ["/p/Sources/A.swift": source], snapshot: IndexSnapshot())
        let document = try service.bridgeFacts(generatedAt: fixedDate)
        #expect(document.facts.map(\.kind) == ["module-export", "method-handle"])
        #expect(document.limitations.contains { $0.hasPrefix("objc-named-classes: 1 module-export and 1 method-handle") })
        #expect(document.limitations.contains { $0.hasPrefix("unscanned-event-channels: 1") })
        #expect(document.limitations.contains { $0.hasPrefix("unscanned-message-channels: 1") })
    }

    @Test("채널을 모르면 키를 빼지 않고 null 로 적는다")
    func encodesUnknownChannelAsNull() throws {
        let fact = BridgeFact(
            kind: .methodHandle,
            target: .flutter,
            channel: nil,
            method: "ping",
            location: SourceLocation(path: "/p/A.swift", line: 1, column: 1)
        )
        let document = BridgeFactsDocument(
            tool: .init(name: "cartograph", version: "0"), generatedAt: "t", project: "/p", facts: [fact]
        )
        let json = try CartographService.encodeSortedJSON(document)
        #expect(json.contains("\"channel\" : null"))
        #expect(!json.contains("\"symbol\""))
        #expect(document.limitations.contains { $0.hasPrefix("unattributed-method-handles: 1") })
    }

    @Test("경로 필터 밖의 소스는 훑지 않는다")
    func respectsPathFilter() throws {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configuration.exclude = ["**/Vendor/**"]
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(files: ["/p/Vendor/Plugin.swift": Self.pluginSource]),
                indexProviderOverride: StaticIndexProvider(IndexSnapshot())
            )
        )
        #expect(try service.bridgeFacts(generatedAt: fixedDate).facts.isEmpty)
    }

    @Test("텍스트 형식은 사실마다 한 줄이고 요약으로 끝난다")
    func rendersText() throws {
        let service = makeService(
            files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource],
            snapshot: makeSnapshot()
        )
        let text = try service.exportBridgeFacts(generatedAt: fixedDate, asText: true).output
        #expect(text.contains("Sources/CameraPlugin.swift:9:14  method-handle  channel=com.example/camera  method=takePhoto  s:handle"))
        #expect(text.contains("2 bridge fact(s) · target flutter\n"))
    }
}
