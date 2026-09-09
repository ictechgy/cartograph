import CartographSyntax
import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("브리지 사실 문서")
struct BridgeFactsTests {
    @Test("SDK 참조 위치를 브리지의 감싸는 선언으로 사용하지 않는다")
    func externalOccurrenceIsNotADeclaration() {
        let site = SourceLocation(path: "/p/Plugin.swift", line: 3, column: 6)
        let fact = BridgeFact(kind: .methodHandle, target: .flutter, channel: "A", method: "run", location: site)
        let declaration = EnclosingDeclaration(name: "install", indexName: "install()", qualifiedName: "install()", line: 3)
        let external = IndexedSymbol(usr: "sdk:install", name: "install()", kind: .function,
            module: "SDK", location: site, isExternal: true)
        let resolved = BridgeSymbolResolver(snapshot: .init(symbols: [external]))
            .resolve([ScannedBridgeFact(fact: fact, declaration: declaration)])
        #expect(resolved.first?.symbol?.usr == nil)
    }

    @Test("채널만 미해석인 핸들러를 동적 메서드 분기라고 단정하지 않는다")
    func dynamicChannelDoesNotImplyDynamicMethod() {
        let fact = BridgeFact(kind: .methodHandle, target: .flutter, channel: "factoryName()", method: "run",
            isDynamic: true, location: .init(path: "/p/Plugin.swift", line: 3, column: 1))
        let document = BridgeFactsDocument(tool: .init(name: "cartograph", version: "test"),
            generatedAt: "t", project: "/p", facts: [fact])
        #expect(document.limitations.contains {
            $0.hasPrefix("dynamic-method-names: 1") && $0.contains("channel or method name")
        })
        #expect(!document.limitations.contains { $0.contains("branch on a non-literal name") })
    }

    @Test("Objective-C 식별자는 정확하고 유일한 Clang 선언에서만 붙인다")
    func objectiveCIndexIdentity() {
        let fact = BridgeFact(kind: .methodHandle, target: .flutter, channel: "A", method: "run",
            location: .init(path: "/p/Plugin.m", line: 8, column: 1), sourceLanguage: .objectiveC)
        let declaration = EnclosingDeclaration(name: "handle:", indexName: "handle:", qualifiedName: "P.handle:", line: 5)
        let scanned = [ScannedBridgeFact(fact: fact, declaration: declaration)]
        func symbol(_ usr: String, line: Int = 5) -> IndexedSymbol {
            IndexedSymbol(usr: usr, name: "handle:", kind: .method, module: "P",
                location: .init(path: "/p/Plugin.m", line: line, column: 1))
        }
        func resolve(_ symbols: [IndexedSymbol]) -> BridgeFact {
            BridgeSymbolResolver(snapshot: IndexSnapshot(symbols: symbols)).resolve(scanned)[0]
        }
        #expect(resolve([symbol("c:objc(cs)P(im)handle:")]).symbol?.usr == "c:objc(cs)P(im)handle:")
        #expect(resolve([]).symbol == nil)
        #expect(resolve([symbol("c:other", line: 4)]).symbol == nil)
        #expect(resolve([symbol("s:fake")]).symbol == nil)
        #expect(resolve([symbol("c:a"), symbol("c:b")]).symbol == nil)
    }

    @Test("외부 핸들러 본문의 공백은 등록 채널을 확실히 알 때만 좁힌다")
    func scopesKnownOpaqueHandlers() throws {
        let source = """
            import Flutter
            func install() {
                let a = FlutterMethodChannel(name: "A", binaryMessenger: messenger)
                let b = FlutterMethodChannel(name: "B", binaryMessenger: messenger)
                a.setMethodCallHandler(other.handle)
                b.setMethodCallHandler { call, result in result(nil) }
            }
            """
        let document = try makeService(files: ["/p/Plugin.swift": source], snapshot: IndexSnapshot()).bridgeFacts()
        let scope = try #require(document.limitationScopes?.first)
        #expect(scope.channels == ["A"])
        #expect(document.limitations[scope.limitationIndex].hasPrefix("opaque-handler-bodies: 1"))
        let unknown = source.replacingOccurrences(of: "name: \"A\"", with: "name: channelName")
        let unscoped = try makeService(files: ["/p/Plugin.swift": unknown], snapshot: IndexSnapshot()).bridgeFacts()
        #expect(unscoped.limitationScopes == nil)
        #expect(unscoped.limitations.contains { $0.hasPrefix("opaque-handler-bodies: 1") })
    }

    @Test("범위를 모르는 본문 하나가 있으면 알려진 채널 목록을 완전한 범위로 내지 않는다")
    func unknownOpaqueHandlerPreventsNarrowing() {
        let document = BridgeFactsDocument(
            tool: .init(name: "cartograph", version: "test"), generatedAt: "2026-09-08T00:00:00Z", project: "/p",
            facts: [], opaqueHandlerChannels: ["A", nil]
        )
        #expect(document.limitationScopes == nil)
        #expect(document.limitations.contains { $0.hasPrefix("opaque-handler-bodies: 2") })
    }

    @Test("RN만 선택하면 Flutter 본문 공백도 함께 제외한다")
    func targetFilterDropsOpaqueFlutterGaps() throws {
        let source = """
            func install() {
                let a = FlutterMethodChannel(name: "A", binaryMessenger: messenger)
                a.setMethodCallHandler(factory.makeHandler())
            }
            """
        let document = try makeService(files: ["/p/Plugin.swift": source, "/p/RN.m": Self.moduleSource], snapshot: IndexSnapshot())
            .bridgeFacts(target: .reactNative)
        #expect(document.limitationScopes == nil)
        #expect(!document.limitations.contains { $0.hasPrefix("opaque-handler-bodies:") })
    }

    @Test("ObjC 사실에 출처 언어를 싣고 일반 ObjC 공백은 채널 리터럴로 좁히지 않는다")
    func objectiveCEvidenceAndConservativeGap() throws {
        let source = """
            @implementation Plugin
            + (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
                FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"A" binaryMessenger:registrar.messenger];
                [channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
                    if ([call.method isEqualToString:@"run"]) { result(nil); }
                }];
            }
            @end
            """
        var symbols = SnapshotBuilder()
        symbols.symbol("s:FakePlugin", name: "Plugin", kind: .classType, path: "/p/Plugin.swift")
        symbols.symbol("s:FakeHandler", name: "handle(_:result:)", kind: .method, path: "/p/Plugin.swift", parent: "s:FakePlugin")
        let document = try makeService(files: ["/p/Plugin.m": source], snapshot: symbols.build()).bridgeFacts()
        #expect(document.facts.map(\.kind) == ["channel-register", "method-handle"])
        #expect(document.facts.allSatisfy { $0.sourceLanguage == .objectiveC && $0.symbol == nil })
        #expect(document.limitations.contains { $0.hasPrefix("objective-c-sources:") })
        #expect(document.limitationScopes == nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        #expect(try JSONDecoder().decode(BridgeFactsDocument.self, from: data) == document)
        #expect(String(decoding: data, as: UTF8.self).contains("\"sourceLanguage\":\"objective-c\""))
    }

    @Test("저장된 클로저와 파일 밖 함수도 본문을 못 읽으면 채널 공백을 낸다")
    func scopesStoredClosureAndUnknownFunction() throws {
        for argument in ["handler", "fromSDK"] {
            let source = """
                func install() {
                    let channel = FlutterMethodChannel(name: "A", binaryMessenger: messenger)
                    let handler = { (call: FlutterMethodCall, result: FlutterResult) in result(nil) }
                    channel.setMethodCallHandler(\(argument))
                }
                """
            let document = try makeService(files: ["/p/Plugin.swift": source], snapshot: IndexSnapshot()).bridgeFacts()
            #expect(document.limitationScopes?.first?.channels == ["A"])
            #expect(document.limitations.contains { $0.hasPrefix("opaque-handler-bodies: 1") })
        }
    }

    @Test("교환 형식에 담을 수 없는 이름을 가진 문서를 내보내지 않는다")
    func rejectsUnrepresentableBridgeNames() {
        let multiline = "\"\"\"\nA\nB\n\"\"\""
        for name in ["\"\"", "\"   \"", multiline] {
            let source = """
                func install() {
                    let channel = FlutterMethodChannel(name: \(name), binaryMessenger: messenger)
                    channel.setMethodCallHandler(other.handle)
                }
                """
            #expect(throws: (any Error).self) {
                try makeService(files: ["/p/Plugin.swift": source], snapshot: IndexSnapshot()).bridgeFacts()
            }
        }
    }

    @Test("로컬 함수 본문을 읽었으면 이름 참조만으로 opaque 경고를 만들지 않는다")
    func readableLocalHandlerIsNotOpaque() throws {
        let source = """
            func install() {
                let channel = FlutterMethodChannel(name: "A", binaryMessenger: messenger)
                channel.setMethodCallHandler(handle)
            }
            func handle(_ call: FlutterMethodCall, result: FlutterResult) {
                switch call.method { case "run": result(nil); default: break }
            }
            """
        let document = try makeService(files: ["/p/Plugin.swift": source], snapshot: IndexSnapshot()).bridgeFacts()
        #expect(document.facts.contains { $0.method == "run" && $0.channel == "A" })
        #expect(!document.limitations.contains { $0.hasPrefix("opaque-handler-bodies:") })
    }

    @Test("Swift 이스케이프를 실제 채널 값으로 풀어 스코프가 잘못된 이름을 가리키지 않는다")
    func decodedLiteralScope() throws {
        let source = #"""
            func install() {
                let channel = FlutterMethodChannel(name: "c\u{61}mera", binaryMessenger: messenger)
                channel.setMethodCallHandler(other.handle)
            }
            """#
        let document = try makeService(files: ["/p/Plugin.swift": source], snapshot: IndexSnapshot()).bridgeFacts()
        #expect(document.facts.first?.channel == "camera")
        #expect(document.limitationScopes?.first?.channels == ["camera"])
    }

    @Test("선행 한계 뒤의 스코프 인덱스와 다채널 합집합을 유지한다")
    func scopeIndexAndUnion() {
        let document = BridgeFactsDocument(
            tool: .init(name: "cartograph", version: "test"), generatedAt: "2026-09-08T00:00:00Z", project: "/p",
            facts: [.init(kind: .channelRegister, target: .flutter, channel: "runtimeName", isDynamic: true,
                          location: .init(path: "/p/A.swift", line: 1, column: 1))],
            opaqueHandlerChannels: ["B", "A", "A"]
        )
        #expect(document.limitationScopes?.first?.limitationIndex == 1)
        #expect(document.limitationScopes?.first?.channels == ["A", "B"])
    }

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
        // `addMethodCallDelegate(CameraPlugin(), channel:)` 이 타입을 말해 주므로 추측이 아니다.
        #expect(!document.limitations.contains { $0.hasPrefix("inferred-channels") })
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
        // Objective-C 로 쓴 Flutter 핸들러는 여기 없다는 것도 문서가 말해야 isthmus 가 오류로 읽지 않는다.
        #expect(document.limitations.contains { $0.hasPrefix("objective-c-sources: 1 Objective-C file(s)") })
    }

    @Test("target 필터가 제외한 사실 수를 빈 선택에도 알린다")
    func targetFilterReportsDroppedFacts() throws {
        let service = makeService(
            files: ["/p/Sources/CameraPlugin.swift": Self.pluginSource],
            snapshot: makeSnapshot()
        )

        let document = try service.bridgeFacts(
            generatedAt: fixedDate,
            target: .reactNative
        )

        #expect(document.facts.isEmpty)
        #expect(document.target == nil)
        #expect(document.limitations == [
            "target-filter: 2 fact(s) did not match react-native",
        ])
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

    @Test("브리지 프로젝트는 tmp 표기와 사용자 링크에 무관한 realpath이며 사실은 상대 경로다")
    func bridgeProjectUsesRealPath() throws {
        let root = "/private/tmp/cartograph-project-\(UUID().uuidString)"
        let manager = FileManager.default
        try manager.createDirectory(atPath: root + "/project", withIntermediateDirectories: true)
        defer { try? manager.removeItem(atPath: root) }
        try manager.createSymbolicLink(atPath: root + "/alias", withDestinationPath: root + "/project")
        try Self.pluginSource.write(toFile: root + "/project/CameraPlugin.swift", atomically: true, encoding: .utf8)
        let paths = [root + "/project", String(root.dropFirst("/private".count)) + "/project", root + "/alias"]
        for path in paths {
            var configuration = CartographConfiguration.default
            configuration.projectPath = path
            let service = CartographService(configuration: configuration, environment: CartographEnvironment(
                indexProviderOverride: StaticIndexProvider(IndexSnapshot()), usesSyntaxCache: false
            ))
            let json = try service.exportBridgeFacts(generatedAt: fixedDate).output
            let document = try JSONDecoder().decode(BridgeFactsDocument.self, from: Data(json.utf8))
            #expect(document.project == root + "/project")
            #expect(!document.facts.isEmpty)
            #expect(document.facts.allSatisfy { $0.location.path == "CameraPlugin.swift" })
        }
    }

    @Test("프로젝트 경로를 해결할 수 없으면 브리지 문서를 내보내지 않는다")
    func refusesUnresolvableProject() {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/tmp/cartograph-missing-\(UUID().uuidString)"
        let service = CartographService(configuration: configuration, environment: CartographEnvironment(
            indexProviderOverride: StaticIndexProvider(IndexSnapshot())
        ))
        #expect(throws: CartographError.self) { try service.exportBridgeFacts() }
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
