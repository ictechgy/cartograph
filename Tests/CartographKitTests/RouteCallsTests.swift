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
