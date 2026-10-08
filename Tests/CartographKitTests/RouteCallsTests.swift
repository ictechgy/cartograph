import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("HTTP 호출 문서")
struct RouteCallsTests {
    private static let apiSource = """
        enum Verb: String { case get = "GET", post = "POST" }
        struct Endpoint {
            init(method: Verb, path: String) {}
            static func items() -> Endpoint { Endpoint(method: .get, path: "/api/items") }
            static func item(id: String) -> Endpoint { Endpoint(method: .get, path: "/api/items/\\(id)") }
            static func file(name: String) -> Endpoint { Endpoint(method: .post, path: "/files/\\(name).json") }
        }
        func relative(base: String) -> URLRequest { URLRequest(url: URL(string: "\\(base)items")!) }
        func passThrough(path: String) -> URLRequest { URLRequest(url: URL(string: path)!) }
        final class Loader {
            var target: URL?
            func load() { _ = URLRequest(url: target!) }
        }
        """

    private static let wrappersFile = """
        {"format": "http-wrappers", "version": 1, "wrappers": [
          {"language": "swift", "kind": "constructor", "owner": "Endpoint", "name": "init",
           "methodArg": {"label": "method"}, "pathArg": {"label": "path"},
           "methodEnum": {"get": "GET", "post": "POST"}, "pathAnchor": "root", "service": "example-api"},
          {"language": "kotlin", "kind": "function", "owner": "net.Api", "name": "call",
           "pathArg": {"index": 0}, "defaultMethod": "GET", "pathAnchor": "base"}
        ]}
        """

    private let fixedDate = Date(timeIntervalSince1970: 1_788_480_000)

    private func makeService(
        files: [String: String], snapshot: IndexSnapshot? = IndexSnapshot(), projectPath: String = "/p"
    ) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = projectPath
        return CartographService(configuration: configuration, environment: CartographEnvironment(
            fileSystem: InMemoryFileSystem(files: files),
            indexProviderOverride: snapshot.map(StaticIndexProvider.init)
        ))
    }

    private func document(
        _ service: CartographService, includeTests: Bool = false, service name: String? = nil
    ) throws -> RouteCallsDocument {
        try service.routeCalls(generatedAt: fixedDate, wrappersPath: "/w/http-wrappers.json", includeTests: includeTests, service: name)
    }

    private static func moyaTargetSource(
        declaration: String = "enum UserTarget { case users }", pathBody: String
    ) -> String {
        """
        import Moya
        \(declaration)
        extension UserTarget: TargetType {
            var baseURL: URL { URL(string: "https://api.example.com")! }
            var path: String \(pathBody)
            var method: Moya.Method { .get }
            var task: Task { .requestPlain }
            var headers: [String: String]? { nil }
        }
        """
    }

    private func crossFileMoyaDocument(
        routeSource: String, pathBody: String, targetDeclaration: String = "enum UserTarget { case users }"
    ) throws -> RouteCallsDocument {
        try crossFileMoyaDocument(routeSources: [routeSource], pathBody: pathBody, targetDeclaration: targetDeclaration)
    }

    private func crossFileMoyaDocument(
        routeSources: [String], pathBody: String, targetDeclaration: String = "enum UserTarget { case users }"
    ) throws -> RouteCallsDocument {
        var files = Dictionary(uniqueKeysWithValues: routeSources.enumerated().map { index, source in
            ("/p/Sources/RoutePaths\(index).swift", source)
        })
        files["/p/Sources/UserTarget.swift"] = Self.moyaTargetSource(
            declaration: targetDeclaration, pathBody: pathBody
        )
        let service = makeService(files: files)
        return try service.routeCalls(generatedAt: fixedDate)
    }

    private func expectDynamicMoyaRoute(routeSource: String, pathBody: String) throws {
        let result = try crossFileMoyaDocument(routeSource: routeSource, pathBody: pathBody)
        let fact = try #require(result.facts.first)
        #expect(result.facts.count == 1)
        #expect(fact.method == "GET")
        #expect(fact.dynamic)
        #expect(fact.channel != "/users")
        #expect(fact.symbol?.qualifiedName == "UserTarget.users")
        #expect(result.limitations == ["missing-route-usrs: 1 route-call fact(s) lack indexed identities"])
    }

    private func expectResolvedMoyaRoute(routeSource: String, pathBody: String) throws {
        let result = try crossFileMoyaDocument(routeSource: routeSource, pathBody: pathBody)
        let fact = try #require(result.facts.first)
        #expect(result.facts.count == 1)
        #expect(fact.method == "GET")
        #expect(fact.channel == "/users")
        #expect(!fact.dynamic)
        #expect(fact.symbol?.qualifiedName == "UserTarget.users")
        #expect(fact.symbol?.usr == nil)
        #expect(result.limitations == ["missing-route-usrs: 1 route-call fact(s) lack indexed identities"])
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let text = try CartographService.encodeSortedJSON(value)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: 문서 머리말

    @Test("호출이 0건이어도 http target 과 client 역할, 테스트 소스 선언을 싣는다")
    func emptyClientDocumentKeepsHTTPTarget() throws {
        let service = makeService(files: ["/p/Sources/A.swift": "struct A {}"])
        let object = try json(try service.routeCalls(generatedAt: fixedDate))
        #expect(object["target"] as? String == "http")
        #expect(object["platform"] as? String == "swift")
        #expect(object["format"] as? String == "bridge-facts")
        #expect(object["version"] as? Int == 1)
        #expect(object["roles"] as? [String] == ["client"])
        #expect(object["sourceSets"] as? [String: String] == ["tests": "excluded"])
        #expect((object["facts"] as? [Any])?.isEmpty == true)
        #expect(object["service"] == nil)
        #expect(object["generatedAt"] as? String == "2026-09-04T00:00:00.000Z")
    }

    // MARK: 사실과 USR

    @Test("래퍼 호출에 감싸는 선언의 인덱스 USR 이 붙고 위치는 프로젝트 상대 경로다")
    func attachesUSRsAndRelativeLocations() throws {
        var builder = SnapshotBuilder(module: "App", path: "/p/Sources/Api.swift")
        builder.symbol("s:Endpoint", name: "Endpoint", kind: .structType, line: 2)
        builder.symbol("s:items", name: "items()", kind: .method, line: 4, parent: "s:Endpoint")
        let service = makeService(
            files: ["/p/Sources/Api.swift": Self.apiSource, "/w/http-wrappers.json": Self.wrappersFile],
            snapshot: builder.build()
        )
        let facts = try document(service).facts
        let items = try #require(facts.first { $0.channel == "/api/items" })
        #expect(items.symbol?.usr == "s:items")
        #expect(items.symbol?.qualifiedName == "Endpoint.items")
        #expect(items.location.path == "Sources/Api.swift")
        #expect(items.method == "GET")
        #expect(items.service == "example-api")
        #expect(facts.map(\.channel) == ["/api/items", "/api/items/{}", "\"/files/\\(name).json\"", "URL(string: \"\\(base)items\")!"])
    }

    @Test("인덱스가 없으면 qualifiedName 만 싣고 missing-route-usrs 가 그 이유를 말한다")
    func worksWithoutAnIndex() throws {
        let service = makeService(
            files: ["/p/Sources/Api.swift": Self.apiSource, "/w/http-wrappers.json": Self.wrappersFile], snapshot: nil
        )
        let result = try document(service)
        #expect(!result.facts.isEmpty)
        #expect(result.facts.allSatisfy { $0.symbol?.usr == nil && $0.symbol?.qualifiedName != nil })
        let missing = try #require(result.limitations.first { $0.hasPrefix("missing-route-usrs:") })
        #expect(missing.contains("no index store was found"))
    }

    @Test("읽지 못한 것은 계약의 호출 측 접두사로 센다")
    func limitationsUseClientPrefixes() throws {
        let service = makeService(files: ["/p/Sources/Api.swift": Self.apiSource, "/w/http-wrappers.json": Self.wrappersFile])
        let limitations = try document(service).limitations
        let prefixes = limitations.map { String($0.prefix { $0 != ":" }) + ":" }
        #expect(prefixes == [
            "route-call-coverage:", "ambiguous-base-join:", "http-wrapper-undeclared:", "missing-route-usrs:",
        ])
        #expect(limitations.contains { $0.hasPrefix("ambiguous-base-join: 1 ") })
    }

    @Test("선언과 맞는 심볼이 없거나 호출이 0건인 래퍼를 알린다")
    func unresolvedWrappers() throws {
        let wrappers = """
            {"format": "http-wrappers", "version": 1, "wrappers": [
              {"language": "swift", "kind": "function", "owner": "Missing", "name": "call",
               "pathArg": {"index": 0}, "defaultMethod": "GET", "pathAnchor": "root"},
              {"language": "swift", "kind": "constructor", "owner": "Idle", "name": "init",
               "pathArg": {"label": "path"}, "defaultMethod": "GET", "pathAnchor": "root"}
            ]}
            """
        let service = makeService(files: [
            "/p/Sources/Idle.swift": "struct Idle { init(path: String) {} }", "/w/http-wrappers.json": wrappers,
        ])
        let limitations = try document(service).limitations
        #expect(limitations == [
            "http-wrapper-unresolved: 2 declared wrapper(s) matched no declaration or no call in the scanned sources: Missing.call, Idle.init",
        ])
    }

    // MARK: 테스트 소스

    @Test("테스트 소스는 기본으로 읽지 않고, 포함하면 testSource 와 included 를 선언한다")
    func testSourcePolicy() throws {
        let call = "func t() { _ = Endpoint(method: .get, path: \"/t\") }"
        let files = [
            "/p/Sources/Api.swift": Self.apiSource, "/w/http-wrappers.json": Self.wrappersFile,
            "/p/Tests/ApiTests/ApiTests.swift": call, "/p/AppUITests/Flow.swift": call, "/p/Sources/StubTests.swift": call,
        ]
        let excluded = try document(makeService(files: files))
        #expect(excluded.sourceSets.tests == "excluded")
        #expect(!excluded.facts.contains { $0.channel == "/t" })
        let included = try document(makeService(files: files), includeTests: true)
        #expect(included.sourceSets.tests == "included")
        let tests = included.facts.filter { $0.channel == "/t" }
        #expect(tests.count == 3)
        #expect(tests.allSatisfy { $0.testSource == true })
        #expect(included.facts.filter { $0.channel != "/t" }.allSatisfy { $0.testSource == nil })
    }

    @Test("테스트 소스 판정은 프로젝트 상대 경로로만 한다")
    func testSourceUsesRelativePath() {
        let variants = ["/work/Tests/app"]
        #expect(!CartographService.isTestSource("/work/Tests/app/Sources/A.swift", baseVariants: variants))
        #expect(CartographService.isTestSource("/work/Tests/app/Tests/A.swift", baseVariants: variants))
        #expect(CartographService.isTestSource("/work/Tests/app/Sources/FeatureTests/A.swift", baseVariants: variants))
        #expect(CartographService.isTestSource("/work/Tests/app/Sources/AThingTests.swift", baseVariants: variants))
        #expect(!CartographService.isTestSource("/work/Tests/app/Sources/TestSupport/A.swift", baseVariants: variants))
    }

    // MARK: service

    @Test("문서 service 와 같은 사실 service 는 생략하고, 다르면 내보내기 전에 거부한다")
    func serviceRules() throws {
        let files = ["/p/Sources/Api.swift": Self.apiSource, "/w/http-wrappers.json": Self.wrappersFile]
        let same = try document(makeService(files: files), service: "example-api")
        #expect(same.service == "example-api")
        #expect(same.facts.allSatisfy { $0.service == nil })
        #expect(throws: CartographError.self) { try document(makeService(files: files), service: "other") }
    }

    // MARK: 선언 파일

    @Test("선언 파일의 모르는 필드와 잘못된 값을 거부한다")
    func rejectsInvalidWrapperFiles() {
        let valid = #""language": "swift", "kind": "function", "owner": "A", "name": "b", "pathArg": {"index": 0}, "pathAnchor": "root""#
        let invalid = [
            "not json",
            #"{"format": "http-wrappers", "version": 1, "wrappers": [], "extra": 1}"#,
            #"{"format": "other", "version": 1, "wrappers": []}"#,
            #"{"format": "http-wrappers", "version": true, "wrappers": []}"#,
            #"{"format": "http-wrappers", "version": 1, "wrappers": {}}"#,
            #"{"format": "http-wrappers", "version": 1, "wrappers": [7]}"#,
            #"{"format": "http-wrappers", "version": 1, "wrappers": [{\#(valid), "defaultMethod": "GET", "note": 1}]}"#,
            #"{"format": "http-wrappers", "version": 1, "wrappers": [{\#(valid)}]}"#,
            #"{"format": "http-wrappers", "version": 1, "wrappers": [{\#(valid), "defaultMethod": "get"}]}"#,
            #"{"format": "http-wrappers", "version": 1, "wrappers": [{\#(valid), "defaultMethod": "GET", "methodEnum": {"x": "FETCH"}}]}"#,
            #"{"format": "http-wrappers", "version": 1, "wrappers": [{\#(valid), "defaultMethod": "GET", "methodEnum": []}]}"#,
            #"{"format": "http-wrappers", "version": 1, "wrappers": [{\#(valid.replacingOccurrences(of: "swift", with: "ruby")), "defaultMethod": "GET"}]}"#,
            #"{"format": "http-wrappers", "version": 1, "wrappers": [{\#(valid), "defaultMethod": "GET", "methodArg": {}}]}"#,
            #"{"format": "http-wrappers", "version": 1, "wrappers": [{\#(valid), "defaultMethod": "GET", "methodArg": {"index": -1}}]}"#,
            #"{"format": "http-wrappers", "version": 1, "wrappers": [{\#(valid), "defaultMethod": "GET", "methodArg": {"index": 1.5}}]}"#,
            #"{"format": "http-wrappers", "version": 1, "wrappers": [{\#(valid), "defaultMethod": "GET", "methodArg": {"label": ""}}]}"#,
        ]
        for text in invalid {
            #expect(throws: CartographError.self, "\(text)") { try HTTPWrapperFile.parse(Data(text.utf8), path: "/w.json") }
        }
    }

    @Test("선언 파일의 모든 필드를 읽고 다른 언어의 선언도 형식만 검증한다")
    func parsesWrapperFile() throws {
        let wrappers = try HTTPWrapperFile.parse(Data(Self.wrappersFile.utf8), path: "/w.json")
        #expect(wrappers.count == 2)
        let swift = wrappers[0]
        #expect(swift.kind == .constructor && swift.owner == "Endpoint" && swift.name == "init")
        #expect(swift.methodArg == .init(label: "method") && swift.pathArg == .init(label: "path"))
        #expect(swift.methodEnum == ["get": "GET", "post": "POST"])
        #expect(swift.pathAnchor == .root && swift.service == "example-api")
        #expect(wrappers[1].language == "kotlin" && wrappers[1].pathArg == .init(index: 0) && wrappers[1].defaultMethod == "GET")
    }

    @Test("v2 suffix를 닫힌 형식으로 읽고 suffix 없는 v1과 v2는 같은 선언이다")
    func parsesVersionTwoWrapperSuffix() throws {
        let base = """
            {"format":"http-wrappers","version":VERSION,"wrappers":[{
              "language":"kotlin","kind":"function","owner":"Api","name":"call",
              "pathArg":{"index":0},"defaultMethod":"GET","pathAnchor":"base"
            }]}
            """
        let legacy = try HTTPWrapperFile.parse(
            Data(base.replacingOccurrences(of: "VERSION", with: "1").utf8),
            path: "/w.json"
        )
        let versionTwo = try HTTPWrapperFile.parse(
            Data(base.replacingOccurrences(of: "VERSION", with: "2").utf8),
            path: "/w.json"
        )
        #expect(legacy == versionTwo)
        #expect(legacy[0].pathSuffix.isEmpty)

        let suffix = """
            {"format":"http-wrappers","version":2,"wrappers":[{
              "language":"kotlin","kind":"function","owner":"Api","name":"call",
              "pathArg":{"index":0},"defaultMethod":"GET","pathAnchor":"base",
              "pathSuffix":[
                {"literal":"fixed/segment"},
                {"argument":{"label":"id"},"shape":"scalar"},
                {"argument":{"index":2},"shape":"array"}
              ]
            }]}
            """
        let parsed = try HTTPWrapperFile.parse(Data(suffix.utf8), path: "/w.json")
        #expect(parsed[0].pathSuffix == [
            .literal("fixed/segment"),
            .argument(.init(label: "id"), shape: .scalar),
            .argument(.init(index: 2), shape: .array),
        ])
        for language in ["go", "python"] {
            let foreign = try HTTPWrapperFile.parse(
                Data(suffix.replacingOccurrences(of: "kotlin", with: language).utf8),
                path: "/w.json"
            )
            #expect(foreign[0].language == language)
            #expect(foreign[0].pathSuffix == parsed[0].pathSuffix)
        }
    }

    @Test("v1 suffix와 열린 v2 suffix 항목, 잘못된 shape, 32개 초과를 거부한다")
    func rejectsInvalidVersionTwoWrapperSuffix() {
        let wrapper = """
            "language":"swift","kind":"function","owner":"Api","name":"call",
            "pathArg":{"index":0},"defaultMethod":"GET","pathAnchor":"base"
            """
        func document(version: Int, suffix: String) -> String {
            """
            {"format":"http-wrappers","version":\(version),"wrappers":[{
              \(wrapper),"pathSuffix":\(suffix)
            }]}
            """
        }
        let tooMany = Array(repeating: #"{"literal":"x"}"#, count: 33).joined(separator: ",")
        let invalid = [
            document(version: 1, suffix: #"[{"literal":"x"}]"#),
            document(version: 2, suffix: #"[{"literal":"x","extra":1}]"#),
            document(version: 2, suffix: #"[{"literal":""}]"#),
            document(version: 2, suffix: #"[{"literal":"."}]"#),
            document(version: 2, suffix: #"[{"literal":".."}]"#),
            document(version: 2, suffix: #"[{"literal":"\u0001"}]"#),
            document(version: 2, suffix: #"[{"literal":"\uD800"}]"#),
            document(
                version: 2,
                suffix: #"[{"literal":"x","argument":{"index":1},"shape":"scalar"}]"#
            ),
            document(version: 2, suffix: #"[{"argument":{"index":1},"shape":"many"}]"#),
            document(version: 2, suffix: "[\(tooMany)]"),
        ]
        for text in invalid {
            #expect(throws: CartographError.self, "\(text)") {
                try HTTPWrapperFile.parse(Data(text.utf8), path: "/w.json")
            }
        }
    }

    @Test("wrapper parser는 정확히 1 MiB를 받고 한 byte 초과는 크기 오류로 거부한다")
    func wrapperFileSizeLimit() throws {
        let prefix = Data(#"{"format":"http-wrappers","version":2,"wrappers":[]}"#.utf8)
        var exact = prefix
        exact.append(Data(repeating: 0x20, count: HTTPWrapperFile.maximumBytes - prefix.count))
        #expect(try HTTPWrapperFile.parse(exact, path: "/w.json").isEmpty)
        var over = exact
        over.append(0x20)
        do {
            _ = try HTTPWrapperFile.parse(over, path: "/w.json")
            Issue.record("cap+1 input should fail")
        } catch let error as CartographError {
            #expect(error.errorDescription?.contains("exceeds 1 MiB") == true)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("미상 main 뒤의 알려진 suffix도 조립 공백을 계량한다")
    func reportsSuffixOnDynamicMain() throws {
        let wrappers = """
            {"format":"http-wrappers","version":2,"wrappers":[{
              "language":"swift","kind":"function","owner":"Client","name":"request",
              "pathArg":{"label":"path"},"defaultMethod":"GET","pathAnchor":"root",
              "pathSuffix":[{"literal":"detail"}]
            }]}
            """
        let source = """
            final class Client {
                func request(path: String) {}
                func load() { request(path: "/base/" + value() + "-tail") }
            }
            """
        let document = try makeService(files: ["/p/Sources/Client.swift": source, "/w/model.json": wrappers])
            .routeCalls(wrappersPath: "/w/model.json")
        #expect(document.facts.count == 1)
        #expect(try #require(document.facts.first).dynamic)
        #expect(document.limitations.contains("http-wrapper-unresolved: 1 call(s) had unresolved configured suffix segments"))
    }

    @Test("적용하지 못한 v2 suffix 호출은 dynamic 사실과 기존 unresolved 한계를 함께 남긴다")
    func reportsUnresolvedVersionTwoWrapperSuffix() throws {
        let wrappers = """
            {"format":"http-wrappers","version":2,"wrappers":[{
              "language":"swift","kind":"function","owner":"Client","name":"request",
              "pathArg":{"label":"path"},"defaultMethod":"GET","pathAnchor":"root",
              "pathSuffix":[{"argument":{"label":"segments"},"shape":"array"}]
            }]}
            """
        let source = """
            final class Client {
                func request(path: String, segments: [String]) {}
                func load(segments: [String]) {
                    request(path: "/v1/items", segments: segments)
                }
            }
            """
        let result = try document(makeService(files: [
            "/p/Sources/Client.swift": source,
            "/w/http-wrappers.json": wrappers,
        ]))
        let fact = try #require(result.facts.first)
        #expect(fact.dynamic)
        #expect(fact.channelPrefix == "/v1/items")
        #expect(result.limitations.contains(
            "http-wrapper-unresolved: 1 call(s) had unresolved configured suffix segments"
        ))
    }

    @Test("선언 파일을 읽지 못하면 경로를 고치라고 안내한다")
    func unreadableWrapperFile() {
        let service = makeService(files: ["/p/Sources/Api.swift": Self.apiSource])
        #expect(throws: CartographError.self) { try document(service) }
    }

    // MARK: JSON

    @Test("JSON 은 정렬된 키로 두 번 인코딩해도 같고 선택 필드는 값이 있을 때만 싣는다")
    func deterministicJSONWithOptionalFields() throws {
        let source = """
            struct Endpoint { init(method: Verb, path: String) {} }
            func a(verb: Verb) { _ = Endpoint(method: verb, path: "/v1/items/550e8400-e29b-41d4-a716-446655440000?x=1") }
            """
        let files = ["/p/Sources/Api.swift": source, "/w/http-wrappers.json": Self.wrappersFile]
        let first = try makeService(files: files).exportRouteCalls(generatedAt: fixedDate, wrappersPath: "/w/http-wrappers.json")
        let second = try makeService(files: files).exportRouteCalls(generatedAt: fixedDate, wrappersPath: "/w/http-wrappers.json")
        #expect(first.output == second.output)
        let facts = try #require(try json(try document(makeService(files: files)))["facts"] as? [[String: Any]])
        let fact = try #require(facts.first)
        #expect(fact["kind"] as? String == "route-call")
        #expect(fact["method"] == nil)
        #expect(fact["methodDynamic"] as? Bool == true)
        #expect(fact["channel"] as? String == "/v1/items/{}")
        #expect(fact["maskedSegments"] as? Int == 1)
        #expect(fact["queryTailStripped"] as? Bool == true)
        #expect(fact["testSource"] == nil)
        #expect(fact["channelPrefix"] == nil)
        let text = try makeService(files: files).exportRouteCalls(generatedAt: fixedDate, asText: true, wrappersPath: "/w/http-wrappers.json")
        #expect(text.output.contains("? /v1/items/{}"))
        #expect(text.output.contains("1 route call(s) · target http"))
    }

    @Test("채널을 모르는 dynamic 사실은 channel 키를 null 로 싣는다")
    func nullChannelIsEncoded() throws {
        let wrappers = """
            {"format": "http-wrappers", "version": 1, "wrappers": [
              {"language": "swift", "kind": "function", "owner": "Client", "name": "send",
               "pathArg": {"label": "route"}, "defaultMethod": "GET", "pathAnchor": "base"}
            ]}
            """
        let source = "final class Client {\n    func send(path: String) {}\n    func a() { send(path: \"/x\") }\n}"
        let files = ["/p/Sources/Client.swift": source, "/w/http-wrappers.json": wrappers]
        let text = try makeService(files: files).exportRouteCalls(generatedAt: fixedDate, wrappersPath: "/w/http-wrappers.json").output
        #expect(text.contains("\"channel\" : null"))
        #expect(text.contains("\"pathAnchor\" : \"base\""))
    }

    // MARK: 라이브러리 라우터

    @Test("Moya case 사실은 래퍼 없이 나오고 다른 파일의 enum case 선언 USR 이 붙는다")
    func moyaCasesCarryEnumCaseUSRs() throws {
        let api = "import Moya\nenum UserAPI {\n    case list\n    case detail(id: Int)\n}\n"
        let target = """
            import Moya
            extension UserAPI: TargetType {
                var baseURL: URL { URL(string: "https://api.example.com/v1")! }
                var path: String {
                    switch self {
                    case .list: return "/users"
                    case .detail(let id): return "/users/\\(id)"
                    }
                }
                var method: Moya.Method { .get }
                var task: Task { .requestPlain }
                var headers: [String: String]? { nil }
            }
            """
        var builder = SnapshotBuilder(module: "App", path: "/p/Sources/UserAPI.swift")
        builder.symbol("s:UserAPI", name: "UserAPI", kind: .enumType, line: 2)
        builder.symbol("s:list", name: "list", kind: .enumCase, line: 3, parent: "s:UserAPI")
        builder.symbol("s:detail", name: "detail(id:)", kind: .enumCase, line: 4, parent: "s:UserAPI")
        let files = ["/p/Sources/UserAPI.swift": api, "/p/Sources/UserAPI+Target.swift": target]
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration, environment: CartographEnvironment(
            fileSystem: InMemoryFileSystem(files: files), indexProviderOverride: StaticIndexProvider(builder.build())
        ))
        let result = try service.routeCalls(generatedAt: fixedDate)
        #expect(result.facts.map { "\($0.method ?? "?") \($0.channel ?? "nil") \($0.symbol?.usr ?? "-")" } == [
            "GET /v1/users s:list", "GET /v1/users/{} s:detail",
        ])
        #expect(result.facts.map(\.symbol?.qualifiedName) == ["UserAPI.list", "UserAPI.detail"])
        #expect(result.facts.allSatisfy { $0.location.path == "Sources/UserAPI+Target.swift" })
        #expect(result.limitations.isEmpty)
    }

    @Test("다른 파일의 문자열 원시값 경로는 Moya enum case 사실의 동사와 채널을 보존한다")
    func crossFileRawEnumRoutePathIsResolved() throws {
        try expectResolvedMoyaRoute(
            routeSource: "enum RoutePaths: String { case users = \"/users\" }",
            pathBody: "{ RoutePaths.users.rawValue }"
        )
    }

    @Test("다른 파일 protocol의 associatedtype 이름은 라우터 익스텐션의 전역 경로 타입을 가린다")
    func crossFileAssociatedTypeShadowsStaticType() throws {
        let result = try crossFileMoyaDocument(
            routeSource: """
                protocol UserTargetProtocol { associatedtype RoutePaths }
                enum RoutePaths: String { case users = "/wrong" }
                """,
            pathBody: "{ RoutePaths.users.rawValue }",
            targetDeclaration: "enum UserTarget: UserTargetProtocol { case users }"
        )
        let fact = try #require(result.facts.first)
        #expect(result.facts.count == 1)
        #expect(fact.dynamic)
        #expect(fact.channel != "/wrong")
    }

    @Test("조건부 enum case는 한 분기만 보여도 원시값을 추측하지 않는다")
    func conditionalSingleBranchRawEnumRoutePathRemainsDynamic() throws {
        try expectDynamicMoyaRoute(
            routeSource: """
                enum RoutePaths: String {
                #if STAGING
                    case users = "/staging"
                #endif
                }
                """,
            pathBody: "{ RoutePaths.users.rawValue }"
        )
    }

    @Test("조건부 분기마다 같은 enum case가 있으면 원시값을 추측하지 않는다")
    func conditionalMultiBranchRawEnumRoutePathRemainsDynamic() throws {
        try expectDynamicMoyaRoute(
            routeSource: """
                enum RoutePaths: String {
                #if STAGING
                    case users = "/staging"
                #else
                    case users = "/production"
                #endif
                }
                """,
            pathBody: "{ RoutePaths.users.rawValue }"
        )
    }

    @Test("같은 enum 사슬의 다른 파일 정의가 있으면 원시값을 추측하지 않는다")
    func duplicateCrossFileRawEnumRoutePathRemainsDynamic() throws {
        let result = try crossFileMoyaDocument(
            routeSources: [
                "enum RoutePaths: String { case users = \"/a\" }",
                "enum RoutePaths: String { case users = \"/b\" }",
            ],
            pathBody: "{ RoutePaths.users.rawValue }"
        )
        let fact = try #require(result.facts.first)
        #expect(result.facts.count == 1)
        #expect(fact.dynamic)
        #expect(fact.channel != "/a")
        #expect(fact.channel != "/b")
    }

    @Test("무조건부 enum case는 주변의 다른 조건부 선언과 함께 원시값을 보존한다")
    func unconditionalRawEnumRoutePathRemainsResolved() throws {
        try expectResolvedMoyaRoute(
            routeSource: """
                enum RoutePaths: String {
                #if STAGING
                    case staging = "/staging"
                #endif
                    case users = "/users"
                }
                """,
            pathBody: "{ RoutePaths.users.rawValue }"
        )
    }

    @Test("다른 파일의 정적 문자열 멤버도 Moya enum case 사실의 동사와 채널을 보존한다")
    func crossFileStaticMemberRoutePathIsResolved() throws {
        try expectResolvedMoyaRoute(
            routeSource: "enum RoutePaths { static let users = \"/users\" }",
            pathBody: "{ RoutePaths.users }"
        )
    }

    @Test("명시한 StaticString 정적 멤버는 문자열 리터럴처럼 해석하지 않는다")
    func explicitStaticStringMemberRemainsDynamic() throws {
        try expectDynamicMoyaRoute(
            routeSource: "enum RoutePaths { static let users: StaticString = \"/users\" }",
            pathBody: "{ RoutePaths.users }"
        )
    }

    @Test("문자열 리터럴 프로토콜을 따르는 사용자 타입의 정적 멤버는 해석하지 않는다")
    func customStringLiteralMemberRemainsDynamic() throws {
        try expectDynamicMoyaRoute(
            routeSource: """
                struct CustomPath: ExpressibleByStringLiteral {
                    init(stringLiteral: String) {}
                }
                enum RoutePaths { static let users: CustomPath = "/users" }
                """,
            pathBody: "{ RoutePaths.users }"
        )
    }

    @Test("명시한 String과 Swift.String 정적 멤버는 문자열 경로로 해석한다")
    func explicitStringMembersResolveStaticPath() throws {
        try expectResolvedMoyaRoute(
            routeSource: "enum RoutePaths { static let users: String = \"/users\" }",
            pathBody: "{ RoutePaths.users }"
        )
        try expectResolvedMoyaRoute(
            routeSource: "enum RoutePaths { static let users: Swift.String = \"/users\" }",
            pathBody: "{ RoutePaths.users }"
        )
    }

    @Test("다른 파일의 원시값 enum을 typealias로 쓴 경로도 Moya enum case 사실을 보존한다")
    func crossFileTypealiasRawEnumRoutePathIsResolved() throws {
        try expectResolvedMoyaRoute(
            routeSource: "typealias Paths = RoutePaths\nenum RoutePaths: String { case users = \"/users\" }",
            pathBody: "{ Paths.users.rawValue }"
        )
    }

    @Test("다른 파일의 중첩 네임스페이스 정적 멤버도 소유 타입을 확인해 해석한다")
    func crossFileNestedNamespaceStaticMemberRoutePathIsResolved() throws {
        try expectResolvedMoyaRoute(
            routeSource: "enum Namespace { enum RoutePaths { static let users = \"/users\" } }",
            pathBody: "{ Namespace.RoutePaths.users }"
        )
    }

    @Test("공유하는 작은 정적 문자열 참조는 순환으로 잘못 거부하지 않는다")
    func crossFileSharedStaticReferencesRemainResolved() throws {
        let result = try crossFileMoyaDocument(
            routeSource: "enum RoutePaths { static let root = \"/users\"; static let users = RoutePaths.root + RoutePaths.root }",
            pathBody: "{ RoutePaths.users }"
        )
        let fact = try #require(result.facts.first)
        #expect(result.facts.count == 1)
        #expect(!fact.dynamic)
        #expect(result.facts.first?.channel == "/users/users")
        #expect(fact.symbol?.qualifiedName == "UserTarget.users")
    }

    @Test("최대 경로 길이를 넘는 정적 문자열 조립은 값을 만들지 않고 dynamic 으로 남긴다")
    func crossFileOverBudgetStaticStringRemainsDynamic() throws {
        var declarations = ["enum RoutePaths { static let p0 = \"/a\""]
        for index in 1...12 {
            declarations.append("static let p\(index) = RoutePaths.p\(index - 1) + RoutePaths.p\(index - 1)")
        }
        declarations.append("}")
        let routeSource = declarations.joined(separator: "\n")
        let underBudget = try crossFileMoyaDocument(routeSource: routeSource, pathBody: "{ RoutePaths.p2 }")
        let smallFact = try #require(underBudget.facts.first)
        #expect(underBudget.facts.count == 1)
        #expect(!smallFact.dynamic)
        #expect(smallFact.channel == "/a/a/a/a")
        try expectDynamicMoyaRoute(
            routeSource: routeSource,
            pathBody: "{ RoutePaths.p12 }"
        )
    }

    @Test("깊은 정적 문자열 별칭 사슬은 제한 안에서만 해석한다")
    func crossFileDeepStaticStringChainIsBounded() throws {
        var declarations = ["enum RoutePaths { static let p0 = \"/users\""]
        for index in 1...65 {
            declarations.append("static let p\(index) = RoutePaths.p\(index - 1) + \"/next\"")
        }
        declarations.append("}")
        try expectDynamicMoyaRoute(
            routeSource: declarations.joined(separator: "\n"),
            pathBody: "{ RoutePaths.p65 }"
        )
    }

    @Test("알 수 없거나 모호한 다른 파일의 원시값 경로는 추측하지 않고 dynamic 으로 남긴다")
    func crossFileUnknownAndAmbiguousPathsRemainDynamic() throws {
        try expectDynamicMoyaRoute(
            routeSource: "enum RoutePaths: String { case users = \"/users\" }",
            pathBody: "{ RoutePaths.missing.rawValue }"
        )
        try expectDynamicMoyaRoute(
            routeSource: """
                enum FeatureA { enum RoutePaths: String { case users = "/a" } }
                enum FeatureB { enum RoutePaths: String { case users = "/b" } }
                """,
            pathBody: "{ RoutePaths.users.rawValue }"
        )
        try expectDynamicMoyaRoute(
            routeSource: """
                enum FeatureA { enum RoutePaths { static let users = "/a" } }
                enum FeatureB { enum RoutePaths { static let users = "/b" } }
                """,
            pathBody: "{ RoutePaths.users }"
        )
        try expectDynamicMoyaRoute(
            routeSource: """
                typealias Paths = Other
                typealias Other = Paths
                enum RoutePaths: String { case users = "/users" }
                """,
            pathBody: "{ Paths.users.rawValue }"
        )
    }

    @Test("동적·변경 가능 Moya 경로는 정적 채널로 오인하지 않고 연관값 경로는 템플릿을 보존한다")
    func dynamicMutableAndParameterDependentPathsRemainDynamic() throws {
        try expectDynamicMoyaRoute(
            routeSource: "enum RoutePaths { static let users = \"/users\" }",
            pathBody: "{ runtimePath() }"
        )
        try expectDynamicMoyaRoute(
            routeSource: "enum RoutePaths { static var users = \"/users\" }",
            pathBody: "{ RoutePaths.users }"
        )
        try expectDynamicMoyaRoute(
            routeSource: "enum RoutePaths { static let users = \"/users\" }",
            pathBody: """
                {
                    var value = "/users"
                    value += "/mutable"
                    return value
                }
                """
        )

        let parameterDependentTarget = Self.moyaTargetSource(
            declaration: "enum UserTarget { case user(id: String) }",
            pathBody: """
                {
                    switch self {
                    case .user(let id): return "/users/" + id
                    }
                }
                """
        )
        let result = try makeService(files: [
            "/p/Sources/RoutePaths.swift": "enum RoutePaths { static let users = \"/users\" }",
            "/p/Sources/UserTarget.swift": parameterDependentTarget,
        ]).routeCalls(generatedAt: fixedDate)
        let fact = try #require(result.facts.first)
        #expect(result.facts.count == 1)
        #expect(fact.method == "GET")
        #expect(fact.channel == "/users/{}")
        #expect(!fact.dynamic)
        #expect(fact.symbol?.qualifiedName == "UserTarget.user")
        #expect(result.limitations == ["missing-route-usrs: 1 route-call fact(s) lack indexed identities"])
    }

    @Test("라이브러리 한계를 계약의 호출 측 접두사로 알린다")
    func libraryLimitations() throws {
        let source = """
            import APIKit
            import OpenAPIURLSession
            import Moya
            import Alamofire
            enum Remote: TargetType { case a }
            let mapping = { (target: Remote) -> Endpoint in
                Endpoint(url: "https://mirror.example.com", sampleResponseClosure: { .networkResponse(200, Data()) },
                         method: .get, task: .requestPlain, httpHeaderFields: nil)
            }
            """
        let result = try makeService(files: ["/p/Sources/Net.swift": source]).routeCalls(generatedAt: fixedDate)
        #expect(result.facts.isEmpty)
        let prefixes = result.limitations.map { String($0.prefix { $0 != ":" }) + ":" }
        #expect(prefixes == ["route-call-coverage:", "route-call-coverage:", "url-rewrite-interceptors:", "generated-client-unscanned:"])
        #expect(result.limitations[0].contains("1 router type(s)"))
        #expect(result.limitations[1].contains("(APIKit)"))
    }
}
