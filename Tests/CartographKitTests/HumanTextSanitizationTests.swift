import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

/// routes·bridges·schema 의 `--format text` 와 `--explain` 계열, 찾지 못한 이름 문구가 Core 의 필터를 지나는지.
///
/// 파일 이름에는 ESC·BEL 이, Swift 식별자에는 U+202E 가 들어갈 수 있다. 이 출력들은 터미널로 바로 가므로
/// 저장소가 고른 시퀀스가 화면을 지우거나(ESC[2J) 클립보드를 바꾸거나(OSC 52) 이름을 뒤집어 보이게 한다.
@Suite("사람용 Kit 텍스트의 제어·형식 문자 정화")
struct HumanTextSanitizationTests {
    /// 터미널에 클립보드를 바꾸라고 시키는 OSC 52 시퀀스.
    private static let clipboard = "\u{1B}]52;c;ZWNobyBwd25lZA==\u{07}"
    private static let tool = BridgeFactsDocument.Tool(name: "cartograph", version: "0.0.0")
    private let fixedDate = Date(timeIntervalSince1970: 1_788_480_000)

    /// 개행 말고 제어(Cc)·형식(Cf) 문자가 남았는지. 개행은 사람용 형식이 줄을 나누는 데 쓴다.
    private static func hasHiddenScalars(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let category = scalar.properties.generalCategory
            return scalar != "\n" && (category == .control || category == .format)
        }
    }

    private func makeService(
        _ snapshot: IndexSnapshot,
        files: [String: String] = [:],
        configure: (inout CartographConfiguration) -> Void = { _ in }
    ) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configure(&configuration)
        return CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(files: files),
                indexProviderOverride: StaticIndexProvider(snapshot)
            )
        )
    }

    // MARK: routes·bridges·schema 텍스트

    @Test("routes 텍스트는 경로·채널·심볼 이름의 제어·형식 문자를 빼고 사실마다 한 줄을 지킨다")
    func routeCallsTextStripsHiddenScalars() {
        let fact = RouteCallFact(
            method: "GET", channel: "/api/\u{1B}[2Kitems", isDynamic: false, pathAnchor: .root,
            location: SourceLocation(path: "/p/Sources/\(Self.clipboard)Api\n.swift", line: 3, column: 5),
            symbol: .init(qualifiedName: "Api.\u{202E}load", usr: nil)
        )
        let document = RouteCallsDocument(
            tool: Self.tool, generatedAt: "2026-10-18T00:00:00.000Z", project: "/p", facts: [fact],
            includesTests: false, service: nil, limitations: ["dynamic-routes: \u{1B}[1A1 call"]
        )

        let text = document.renderText()

        #expect(!Self.hasHiddenScalars(text))
        #expect(text == """
            Sources/]52;c;ZWNobyBwd25lZA==Api.swift:3:5  GET /api/[2Kitems  (root)  Api.load

            1 route call(s) · target http
              limitation: dynamic-routes: [1A1 call

            """)
    }

    @Test("routes 명령의 텍스트 형식은 파일 이름에 든 OSC 52 와 ESC 를 터미널로 보내지 않는다")
    func exportedRouteCallsTextStripsFileNameSequences() throws {
        let wrappers = """
            {"format": "http-wrappers", "version": 1, "wrappers": [
              {"language": "swift", "kind": "constructor", "owner": "Endpoint", "name": "init",
               "pathArg": {"label": "path"}, "defaultMethod": "GET", "pathAnchor": "root"}
            ]}
            """
        let source = """
            struct Endpoint { init(path: String) {} }
            func items() -> Endpoint { Endpoint(path: "/api/items") }
            """
        let service = makeService(IndexSnapshot(), files: [
            "/p/Sources/\(Self.clipboard)Api\u{1B}[2K.swift": source, "/w/http-wrappers.json": wrappers,
        ])

        let outcome = try service.exportRouteCalls(
            generatedAt: fixedDate, asText: true, wrappersPath: "/w/http-wrappers.json"
        )

        #expect(!Self.hasHiddenScalars(outcome.output))
        #expect(outcome.output.hasPrefix("Sources/]52;c;ZWNobyBwd25lZA==Api[2K.swift:2:"))
        #expect(outcome.output.contains("\n1 route call(s) · target http\n"))
    }

    @Test("bridges·schema 텍스트는 경로·채널·메서드·심볼 이름의 제어·형식 문자를 빼고 사실마다 한 줄을 지킨다")
    func bridgeFactsTextStripsHiddenScalars() {
        let fact = BridgeFact(
            kind: .methodHandle, target: .flutter, channel: "com.example/\u{1B}[2Jcamera", method: "take\u{202E}Photo",
            location: SourceLocation(path: "/p/Sources/\(Self.clipboard)Camera\r\n.swift", line: 9, column: 14),
            symbol: .init(qualifiedName: "Camera\u{202E}Plugin.handle", usr: "s:handle")
        )
        let document = BridgeFactsDocument(
            tool: Self.tool, generatedAt: "2026-10-18T00:00:00.000Z", project: "/p", facts: [fact],
            extraLimitations: ["unscanned-sources: \u{1B}[1A1 file"]
        )

        let text = document.renderText()

        #expect(!Self.hasHiddenScalars(text))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // 사실 한 줄 + 빈 줄 + 요약 + 한계 줄들 + 끝 개행 뒤의 빈 조각
        #expect(lines.count == document.facts.count + 2 + document.limitations.count + 1)
        let factLine = "Sources/]52;c;ZWNobyBwd25lZA==Camera.swift:9:14  method-handle  "
            + "channel=com.example/[2Jcamera  method=takePhoto  s:handle"
        #expect(lines.first.map(String.init) == factLine)
        #expect(text.contains("\n  limitation: unscanned-sources: [1A1 file\n"))
    }

    /// 타입 이름에 U+202E 가 든 Flutter 플러그인. Swift 문법상 U+202A–U+202E 는 식별자 글자다.
    private static let reversedPluginSource = """
        import Flutter
        public final class Camera\u{202E}Plugin: NSObject, FlutterPlugin {
            public static func register(with registrar: FlutterPluginRegistrar) {
                let channel = FlutterMethodChannel(name: "com.example/camera", binaryMessenger: registrar.messenger())
                registrar.addMethodCallDelegate(Camera\u{202E}Plugin(), channel: channel)
            }
            public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                switch call.method {
                case "takePhoto": result(nil)
                default: result(FlutterMethodNotImplemented)
                }
            }
        }
        """

    @Test("bridges 명령의 텍스트 형식은 파일 이름과 타입 이름의 제어·형식 문자를 터미널로 보내지 않는다")
    func exportedBridgeFactsTextStripsHiddenScalars() throws {
        let service = makeService(
            IndexSnapshot(), files: ["/p/Sources/\(Self.clipboard)Camera.swift": Self.reversedPluginSource]
        )

        let outcome = try service.exportBridgeFacts(generatedAt: fixedDate, asText: true)

        #expect(!Self.hasHiddenScalars(outcome.output))
        #expect(outcome.output.contains("Sources/]52;c;ZWNobyBwd25lZA==Camera.swift:9:14  method-handle"))
        #expect(outcome.output.contains("  CameraPlugin.handle"))
        #expect(outcome.output.contains("\n2 bridge fact(s) · target flutter\n"))
    }

    // MARK: --explain 과 찾지 못한 이름

    @Test("dead --explain 은 선언 이름과 후보 위치의 제어·형식 문자를 빼고 설명한다")
    func explainRetentionStripsHiddenScalars() throws {
        var builder = SnapshotBuilder()
        builder.symbol(
            "s:Home", name: "Home\u{202E}View", kind: .structType, module: "App",
            path: "/p/\u{1B}[2JHome.swift", attributes: [.entryPoint]
        )
        builder.symbol("s:Dead", name: "Dead\(Self.clipboard)Helper", module: "App", path: "/p/D.swift")
        let repository = "Repo\u{202E}sitory"
        builder.symbol("s:A", name: repository, kind: .classType, module: "Data", path: "/p/\(Self.clipboard)A.swift")
        builder.symbol("s:B", name: repository, kind: .classType, module: "Domain", path: "/p/B\u{1B}[2K.swift")
        let service = makeService(builder.build())

        let retained = try service.explainRetention(of: "s:Home").output
        #expect(!Self.hasHiddenScalars(retained))
        #expect(retained.hasPrefix("App.HomeView is retained because"))

        let dead = try service.explainRetention(of: "s:Dead")
        #expect(dead.output == "App.Dead]52;c;ZWNobyBwd25lZA==Helper is not reachable from any retained root.\n")
        #expect(dead.findingCount == 1)

        let ambiguous = try service.explainRetention(of: repository).output
        #expect(ambiguous == """
            'Repository' matches 2 declarations. Ask again with one of the names or USRs below:
              /p/]52;c;ZWNobyBwd25lZA==A.swift:1  class Data.Repository
                s:A
              /p/B[2K.swift:1  class Domain.Repository
                s:B

            """)
    }

    @Test("cycles --explain 은 순환 경로와 모호 후보의 제어·형식 문자를 빼고 줄 구조는 지킨다")
    func explainCyclesStripsHiddenScalars() throws {
        var builder = SnapshotBuilder()
        builder.symbol("s:Alpha", name: "Al\u{202E}pha", kind: .structType, module: "App", path: "/p/Alpha.swift")
        builder.symbol("s:Beta", name: "Beta\u{1B}[1A\r", kind: .structType, module: "App", path: "/p/Beta.swift")
        builder.symbol("s:T1", name: "Twin\(Self.clipboard)", kind: .structType, module: "A", path: "/p/T1.swift")
        // 줄 끝의 복귀는 이어 붙는 개행과 한 글자("\r\n")로 묶인다. 그래도 줄이 합쳐지면 안 된다.
        builder.symbol("s:T2\r", name: "Twin\(Self.clipboard)", kind: .structType, module: "B", path: "/p/T2.swift")
        builder.reference(from: "s:Alpha", to: "s:Beta", kind: .call)
        builder.reference(from: "s:Beta", to: "s:Alpha", kind: .call)
        let service = makeService(builder.build())

        let explained = try service.explainCycles(of: "s:Alpha", level: .symbol)
        #expect(!Self.hasHiddenScalars(explained.output))
        #expect(explained.findingCount == 1)
        let lines = explained.output.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "App.Alpha is part of 1 cycle(s):")
        #expect(lines.contains { $0.hasPrefix("  ") && $0.contains("App.Alpha") && $0.contains("App.Beta[1A") })
        #expect(lines.last == "")

        let outside = try service.explainCycles(of: "s:T1", level: .symbol)
        #expect(outside.output == "A.Twin]52;c;ZWNobyBwd25lZA== is not part of any cycle.\n")

        let ambiguous = try service.explainCycles(of: "Twin\(Self.clipboard)", level: .symbol).output
        #expect(!Self.hasHiddenScalars(ambiguous))
        #expect(ambiguous.hasPrefix(
            "'Twin]52;c;ZWNobyBwd25lZA==' matches 2 declarations. Pass one of these USRs instead:\n"
        ))
        // 머리 줄 + 후보 두 줄 + 끝 개행 뒤의 빈 조각
        let candidates = ambiguous.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(candidates.count == 4)
        #expect(candidates.contains("  A.Twin]52;c;ZWNobyBwd25lZA==  s:T1"))
        #expect(candidates.contains("  B.Twin]52;c;ZWNobyBwd25lZA==  s:T2"))
    }

    @Test("rules --explain 은 레이어·규칙 이름과 이유·안내의 제어·형식 문자를 빼고 줄 구조는 지킨다")
    func explainRulesStripsHiddenScalars() throws {
        var builder = SnapshotBuilder()
        builder.symbol("HomeView", kind: .structType, module: "Presentation", path: "/p/HomeView.swift")
        let service = makeService(builder.build()) {
            $0.layers = [LayerDefinition(name: "UI\u{1B}[2K", patterns: ["Presentation"])]
            $0.rules = [LayerRule(
                name: "no \(Self.clipboard)data", from: "UI\u{1B}[2K", deny: ["Data"],
                rationale: "keep \u{1B}[31mviews\u{1B}[0m testable", hint: "inject \u{202E}a use case"
            )]
        }

        let explained = try service.explainRules(of: "Presentation", level: .module)

        #expect(explained.output == """
            Presentation is in layer 'UI[2K'.
              matched: Presentation against 'Presentation'
              rules from 'UI[2K':
                no ]52;c;ZWNobyBwd25lZA==data
                  rationale: keep [31mviews[0m testable
                  hint: inject a use case

            """)
    }

    @Test("찾지 못한 이름의 추천과 표준 오류 문구도 제어·형식 문자를 빼고, JSON 은 이름을 그대로 둔다")
    func notFoundMessagesStripHiddenScalars() throws {
        var builder = SnapshotBuilder()
        builder.symbol(
            "s:Home", name: "Home\u{202E}View", kind: .structType, module: "App",
            path: "/p/Home.swift", attributes: [.entryPoint]
        )
        let service = makeService(builder.build())

        let explained = try service.explainRetention(of: "HomeView")
        #expect(explained.subjectNotFound)
        #expect(explained.output == "No declaration matches 'HomeView'. Similar names: App.HomeView.\n")

        let rules = try service.explainRules(of: "HomeView", level: .symbol)
        #expect(rules.output == "No node matches 'HomeView'. Similar names: App.HomeView.\n")

        let queried = try service.query(symbol: "HomeView")
        let message = try #require(queried.notFoundMessage)
        #expect(!Self.hasHiddenScalars(message))
        #expect(message.hasPrefix("no declaration matches 'HomeView'. Similar names: App.HomeView"))
        // 에이전트가 읽는 JSON 은 이름을 바꾸지 않는다. 되물을 때 그 이름이 그대로 맞아야 한다.
        #expect(queried.output.contains("Home\u{202E}View"))
    }

    // MARK: 값 속 개행

    @Test("dead --explain 의 모호 후보 목록은 경로 속 개행으로 가짜 후보·USR 줄을 만들지 못한다")
    func candidateListLinesFollowCandidateCount() throws {
        // 파일 이름에는 개행이 들어갈 수 있다. 사용자는 이 목록의 USR 을 복사해 다시 묻는다.
        let forged = "/p/A.swift\n  /p/Trusted.swift:1  class Data.Repository\n    s:trusted\n  /p/X"
        var builder = SnapshotBuilder()
        builder.symbol("s:A", name: "Repository", kind: .classType, module: "Data", path: forged)
        builder.symbol("s:B", name: "Repository", kind: .classType, module: "Domain", path: "/p/B.swift")

        let output = try makeService(builder.build()).explainRetention(of: "Repository").output

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 머리 줄 + 후보마다 위치·USR 두 줄 + 끝 개행 뒤의 빈 조각
        #expect(lines.count == 1 + 2 * 2 + 1)
        #expect(!lines.contains("    s:trusted"))
        let site: String = "  /p/A.swift  /p/Trusted.swift:1  class Data.Repository    s:trusted  /p/X:1"
            + "  class Data.Repository"
        #expect(lines[1] == site)
        #expect(lines[2] == "    s:A")
    }

    @Test("cycles·rules --explain 의 파일 레벨 설명은 경로 속 개행으로 후보·검사 줄을 늘리지 못한다")
    func fileLevelExplanationLinesFollowStructure() throws {
        // 파일 레벨 정점의 식별자와 위치는 경로다. 이름이 같은 두 파일을 물으면 후보 줄에, 레이어가 없는
        // 파일을 물으면 검사한 후보 줄에 경로가 실린다.
        let forged = "/p/X\n  App.A.swift  /p/Trusted.swift\n/A.swift"
        var builder = SnapshotBuilder()
        builder.symbol("s:First", name: "First", kind: .structType, module: "App", path: forged)
        builder.symbol("s:Second", name: "Second", kind: .structType, module: "App", path: "/p/Y/A.swift")
        let service = makeService(builder.build())

        for output in [
            try service.explainCycles(of: "A.swift", level: .file).output,
            try service.explainRules(of: "A.swift", level: .file).output,
        ] {
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // 머리 줄 + 후보 두 줄 + 끝 개행 뒤의 빈 조각
            #expect(lines.count == 1 + 2 + 1)
            #expect(lines.contains("  App.A.swift  /p/X  App.A.swift  /p/Trusted.swift/A.swift"))
            #expect(!lines.contains("  App.A.swift  /p/Trusted.swift"))
        }

        let orphan = try service.explainRules(of: forged, level: .file).output
        #expect(orphan == "App.A.swift belongs to no layer.\n"
            + "  checked: A.swift, App.A.swift, App, /p/X  App.A.swift  /p/Trusted.swift/A.swift\n")
    }

    @Test("rules --explain 은 설정의 레이어·규칙 이름 속 개행으로 설명 줄을 늘리지 못한다")
    func layerExplanationLinesFollowStructure() throws {
        // rationale·hint 는 LayerRule 이 한 줄로 접지만 레이어 이름과 규칙의 name·from 은 그대로 온다.
        let layer = "UI\n  matched: Data against 'Data'"
        var builder = SnapshotBuilder()
        builder.symbol("HomeView", kind: .structType, module: "Presentation", path: "/p/HomeView.swift")
        let service = makeService(builder.build()) {
            $0.layers = [LayerDefinition(name: layer, patterns: ["Presentation"])]
            $0.rules = [LayerRule(name: "no data\n      hint: run the fix script", from: layer, deny: ["Data"])]
        }

        let explained = try service.explainRules(of: "Presentation", level: .module)

        #expect(explained.output == """
            Presentation is in layer 'UI  matched: Data against 'Data''.
              matched: Presentation against 'Presentation'
              rules from 'UI  matched: Data against 'Data'':
                no data      hint: run the fix script

            """)
    }

    @Test("--explain 의 설명 문장과 찾지 못한 이름 문구도 이름 속 개행으로 줄을 늘리지 못한다")
    func explanationSentencesKeepTheirLines() throws {
        // 줄 구조는 값이 아니라 문장 틀이 정해야 한다. 이름 속 개행은 그 줄 안에서 빠진다.
        var builder = SnapshotBuilder()
        builder.symbol(
            "s:Root", name: "Root", kind: .structType, module: "App", path: "/p/Root.swift", attributes: [.entryPoint]
        )
        builder.symbol("s:Mid", name: "Mid\n  App.Forged", kind: .structType, module: "App", path: "/p/Mid.swift")
        builder.symbol("s:Leaf", name: "Leaf", kind: .structType, module: "App", path: "/p/Leaf.swift")
        builder.symbol("s:Dead", name: "Dead\nHelper", module: "App", path: "/p/Dead.swift")
        builder.symbol("s:Home", name: "Home\nView", kind: .structType, module: "App", path: "/p/Home.swift")
        builder.reference(from: "s:Root", to: "s:Mid", kind: .call)
        builder.reference(from: "s:Mid", to: "s:Leaf", kind: .call)
        builder.reference(from: "s:Leaf", to: "s:Mid", kind: .call)
        let service = makeService(builder.build())

        #expect(try service.explainRetention(of: "s:Leaf").output
            == "App.Leaf is reachable:\n  App.Root → App.Mid  App.Forged → App.Leaf\n")
        #expect(try service.explainRetention(of: "s:Dead").output
            == "App.DeadHelper is not reachable from any retained root.\n")

        let cycle = try service.explainCycles(of: "s:Leaf", level: .symbol).output
        let lines = cycle.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "App.Leaf is part of 1 cycle(s):")
        // 머리 줄 + 순환 경로 한 줄 + (있으면) 끊을 후보 한 줄 + 끝 개행 뒤의 빈 조각
        #expect(lines.count == (cycle.contains("weakest link") ? 4 : 3))
        #expect(!lines.contains { $0.hasPrefix("  App.Forged") })

        let similar = [GraphNode(id: "s:Home", name: "Home\nView", kind: .structType, module: "App")]
        #expect(CartographService.describeNotFound("HomeView", similar: similar, noun: "node")
            == "No node matches 'HomeView'. Similar names: App.HomeView.\n")
        let message = try #require(try service.query(symbol: "HomeView").notFoundMessage)
        #expect(message.hasPrefix("no declaration matches 'HomeView'. Similar names: App.HomeView"))
        #expect(!message.contains("\n"))
    }
}
