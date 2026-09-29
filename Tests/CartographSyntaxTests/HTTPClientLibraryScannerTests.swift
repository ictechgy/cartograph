import CartographCore
@testable import CartographSyntax
import Testing

/// 래퍼 선언 없이 읽는 Swift HTTP 라이브러리(Foundation·URLComponents·Alamofire·Moya) 규칙.
///
/// 기대값의 인코딩·결합 규칙은 `experiments/http-client-oracle` 가 로컬 HTTP 서버로 잰 실제 요청 줄과 같다.
@Suite("HTTP 라이브러리 스캐너")
struct HTTPClientLibraryScannerTests {
    private func scan(_ source: String, path: String = "/p/App.swift", wrappers: [HTTPWrapperDeclaration] = []) -> RouteCallScanResult {
        let surface = HTTPRouteCallScanner.declarations(source: source, path: path)
        return HTTPRouteCallScanner(wrappers: wrappers, surface: surface).scan(source: source, path: path)
    }

    private func routes(_ source: String) -> [String] {
        scan(source).calls.map(\.fact).map(Self.describe)
    }

    /// 여러 파일을 한 문서처럼 읽어 라우터 사실까지 합친다.
    private func project(_ files: [String: String], wrappers: [HTTPWrapperDeclaration] = []) -> (calls: [ScannedRouteCall], counts: RouteCallScanCounts) {
        var surface = HTTPDeclarationSurface()
        for (path, source) in files { surface.merge(HTTPRouteCallScanner.declarations(source: source, path: path)) }
        let scanner = HTTPRouteCallScanner(wrappers: wrappers, surface: surface)
        var calls: [ScannedRouteCall] = []
        var counts = RouteCallScanCounts()
        var tables: [HTTPTargetMemberTable] = []
        var recipes: [HTTPRouterRecipe] = []
        for path in files.keys.sorted() {
            let result = scanner.scan(source: files[path] ?? "", path: path)
            calls += result.calls
            counts = counts + result.counts
            tables += result.routerTables
            recipes += result.routerRecipes
        }
        let owners = Set(wrappers.filter { $0.kind == .constructor }.compactMap(\.ownerComponents.last))
        let routers = HTTPRouteCallScanner.routerRouteCalls(tables: tables, recipes: recipes, surface: surface, declaredDescriptorOwners: owners)
        return (calls + routers.calls, counts + routers.counts)
    }

    private static func describe(_ fact: RouteCallFact) -> String {
        let channel = fact.isDynamic ? "dynamic(\(fact.channelPrefix ?? "-"))" : (fact.channel ?? "nil")
        return "\(fact.method ?? "?") \(channel) \(fact.pathAnchor.rawValue)"
    }

    // MARK: - Foundation

    @Test("appendingPathComponent 는 조각의 물음표·샵·퍼센트를 인코딩하고 앞 슬래시 하나만 뗀다")
    func appendingPathComponentEncodesLikeFoundation() {
        let source = """
            func a() {
                let base = URL(string: "https://api.example.com/v1")!
                _ = URLRequest(url: base.appendingPathComponent("users?draft=1"))
                _ = URLRequest(url: base.appendingPathComponent("a#b"))
                _ = URLRequest(url: base.appendingPathComponent("a%20b"))
                _ = URLRequest(url: base.appendingPathComponent("//x"))
                _ = URLRequest(url: base.appending(component: "a/b"))
                _ = URLRequest(url: base.appending(path: "c d/é"))
            }
            """
        #expect(routes(source) == [
            "GET /v1/users%3Fdraft=1 root", "GET /v1/a%23b root", "GET /v1/a%2520b root", "GET /v1//x root",
            "GET /v1/a%2Fb root", "GET /v1/c%20d/%C3%A9 root",
        ])
    }

    @Test("리터럴 base 에 상대 해석하면 RFC 3986 병합으로 root 를 확정한다")
    func literalRelativeBase() {
        let source = """
            enum Server { static let base = URL(string: "https://api.example.com/v1")! }
            func a(unknown: URL) {
                _ = URLRequest(url: URL(string: "items", relativeTo: URL(string: "https://api.example.com/v1/"))!)
                _ = URLRequest(url: URL(string: "items", relativeTo: Server.base)!)
                _ = URLRequest(url: URL(string: "/items", relativeTo: Server.base)!)
                _ = URLRequest(url: URL(string: "items", relativeTo: unknown)!)
            }
            """
        #expect(routes(source) == ["GET /v1/items root", "GET /items root", "GET /items root", "GET /items base"])
    }

    @Test("조각 전체가 값이면 component 는 세그먼트 하나, 경로를 뜻하는 값은 경로 전체라 dynamic 이다")
    func bareValueComponents() {
        let source = """
            final class Client {
                var requestPath = ""
                func a(userId: String) {
                    let base = URL(string: "https://api.example.com/v1/users")!
                    _ = URLRequest(url: base.appendingPathComponent(userId))
                    _ = URLRequest(url: base.appending(component: userId))
                    _ = URLRequest(url: base.appending(path: userId))
                    _ = URLRequest(url: base.appendingPathComponent(requestPath))
                }
            }
            """
        #expect(routes(source) == [
            "GET /v1/users/{} root", "GET /v1/users/{} root", "GET dynamic(/v1/users/) root", "GET dynamic(/v1/users/) root",
        ])
    }

    @Test("타입 멤버의 URL 상수와 단일 식 계산 프로퍼티를 base 로 푼다")
    func memberURLConstants() {
        let source = """
            enum Server {
                static let base = URL(string: "https://api.example.com/v2")!
                static let optionalBase = URL(string: "https://api.example.com/v3")
                static var computed: URL { URL(string: "https://api.example.com/v4")! }
            }
            final class Loader {
                let root = URL(string: "https://cdn.example.com")!
                func a() {
                    _ = URLRequest(url: Server.base.appendingPathComponent("items"))
                    _ = URLRequest(url: Server.optionalBase!.appendingPathComponent("items"))
                    _ = URLRequest(url: Server.computed.appendingPathComponent("items"))
                    _ = URLRequest(url: root.appendingPathComponent("logo"))
                    _ = URLRequest(url: self.root.appendingPathComponent("icon"))
                }
            }
            """
        #expect(routes(source) == [
            "GET /v2/items root", "GET /v3/items root", "GET /v4/items root", "GET /logo root", "GET /icon root",
        ])
    }

    @Test("URLComponents 의 path 는 인코딩하고 percentEncodedPath 는 그대로 쓴다")
    func urlComponents() {
        let source = """
            func a() {
                var components = URLComponents()
                components.scheme = "https"
                components.host = "api.example.com"
                components.path = "/v1/search?draft"
                components.queryItems = [URLQueryItem(name: "q", value: "x")]
                _ = URLRequest(url: components.url!)
            }
            func b() {
                var components = URLComponents(string: "https://api.example.com/v1")!
                components.path += "/users"
                _ = URLSession.shared.dataTask(with: components.url!)
            }
            func c() {
                var components = URLComponents()
                components.scheme = "https"
                components.host = "api.example.com"
                components.percentEncodedPath = "/v1/a%2fb"
                _ = URLRequest(url: components.url!)
            }
            func d(id: String) {
                var components = URLComponents(string: "https://api.example.com")!
                components.path = "/v1/items/\\(id)"
                _ = URLRequest(url: components.url!)
            }
            """
        let found = scan(source).calls.map(\.fact)
        #expect(found.map(Self.describe) == [
            "GET /v1/search%3Fdraft root", "GET /v1/users root", "GET /v1/a%2Fb root", "GET /v1/items/{} root",
        ])
        #expect(found.first?.authority == "api.example.com")
    }

    @Test("조건부로 바뀌거나 inout 으로 넘긴 URLComponents 와 host 없는 상대 경로는 사실이 아니다")
    func unprovableComponents() {
        let source = """
            func a(flag: Bool) {
                var components = URLComponents(string: "https://api.example.com")!
                if flag { components.path = "/v1/a" }
                _ = URLRequest(url: components.url!)
            }
            func b() {
                var components = URLComponents(string: "https://api.example.com")!
                tweak(&components)
                _ = URLRequest(url: components.url!)
            }
            func c() {
                var components = URLComponents(string: "https://api.example.com")!
                components.path = "v1/relative"
                _ = URLRequest(url: components.url!)
            }
            func tweak(_ components: inout URLComponents) {}
            """
        let result = scan(source)
        #expect(result.calls.isEmpty)
        #expect(result.counts.unreadableSinks == 3)
    }

    @Test("URL 을 받는 dataTaskPublisher 는 GET 이고 URLRequest 를 받으면 사실이 아니다")
    func dataTaskPublisher() {
        let source = """
            func a(request: URLRequest) {
                _ = URLSession.shared.dataTaskPublisher(for: URL(string: "https://api.example.com/feed")!)
                _ = URLSession.shared.dataTaskPublisher(for: request)
            }
            """
        #expect(routes(source) == ["GET /feed root"])
    }

    @Test("원시값 enum case 의 rawValue 를 경로 상수로 푼다")
    func enumRawValues() {
        let source = """
            enum Path: String {
                case users = "/users"
                case health
            }
            func a() {
                _ = URLRequest(url: URL(string: "https://api.example.com" + Path.users.rawValue)!)
                _ = URLRequest(url: URL(string: "https://api.example.com/\\(Path.health.rawValue)")!)
            }
            """
        #expect(routes(source) == ["GET /users root", "GET /health root"])
    }

    // MARK: - Alamofire 호출

    @Test("AF·Session 요청은 method 인자를, 없으면 메서드의 기본 동사를 쓴다")
    func alamofireRequests() {
        let source = """
            import Alamofire
            final class Api {
                let session: Session
                init(session: Session) { self.session = session }
                func a(id: Int, data: Data) {
                    AF.request("https://api.example.com/v1/users", method: .post)
                    AF.request("https://api.example.com/v1/users/\\(id)")
                    Session.default.download("https://api.example.com/v1/export")
                    session.upload(data, to: "https://api.example.com/v1/upload")
                    session.streamRequest(URL(string: "https://api.example.com/v1/stream")!, method: .get)
                    AF.request("https://api.example.com/v1/tunnel", method: .connect)
                    AF.request("https://api.example.com/v1/raw", method: HTTPMethod(rawValue: "PATCH"))
                }
            }
            """
        #expect(routes(source) == [
            "POST /v1/users root", "GET /v1/users/{} root", "GET /v1/export root", "POST /v1/upload root",
            "GET /v1/stream root", "? /v1/tunnel root", "PATCH /v1/raw root",
        ])
    }

    @Test("라우터·URLRequest 인자는 호출 지점의 사실이 아니고, 문자열 매개변수 통과는 선언되지 않은 래퍼로 센다")
    func alamofireRequestConvertibles() {
        let source = """
            import Alamofire
            enum Router { case users }
            func a(router: Router, request: URLRequest, path: String, url: URL) {
                AF.request(Router.users)
                AF.request(router)
                AF.request(request)
                AF.upload(Data(), with: request)
                AF.request(path)
                AF.request(url, method: .delete)
            }
            """
        let result = scan(source)
        #expect(result.calls.isEmpty)
        #expect(result.counts.undeclaredWrapperSinks == 2)
        #expect(result.counts.unreadableSinks == 0)
    }

    @Test("프로젝트가 Session 타입을 선언하면 Session 표기는 Alamofire 증거가 아니다")
    func projectSessionTypeIsNotAlamofire() {
        let source = """
            struct Session { func request(_ path: String) {} }
            func a(session: Session) {
                session.request("https://api.example.com/v1/users")
                AF.request("https://api.example.com/v1/items")
            }
            """
        #expect(routes(source) == ["GET /v1/items root"])
    }

    @Test("Alamofire URLRequest 생성자와 method 대입의 동사를 읽는다")
    func alamofireURLRequestVerbs() {
        let source = """
            func a() throws {
                _ = try URLRequest(url: "https://api.example.com/v1/a", method: .put)
                var b = URLRequest(url: URL(string: "https://api.example.com/v1/b")!)
                b.method = .delete
                var c = URLRequest(url: URL(string: "https://api.example.com/v1/c")!)
                c.httpMethod = HTTPMethod.patch.rawValue
                _ = (b, c)
            }
            """
        #expect(routes(source) == ["PUT /v1/a root", "? /v1/b root", "? /v1/c root"])
    }

    @Test("Alamofire URLRequest 의 method 대입은 요청이 밖으로 나가지 않으면 확정한다")
    func alamofireMethodAssignment() {
        let source = """
            func a() async throws {
                var b = URLRequest(url: URL(string: "https://api.example.com/v1/b")!)
                b.method = .delete
                _ = try await URLSession.shared.data(for: b)
                var c = URLRequest(url: URL(string: "https://api.example.com/v1/c")!)
                c.httpMethod = HTTPMethod.patch.rawValue
                _ = try await URLSession.shared.data(for: c)
            }
            """
        #expect(routes(source) == ["DELETE /v1/b root", "PATCH /v1/c root"])
    }

    // MARK: - Moya

    private static let moyaAPI = """
        import Moya
        enum UserAPI {
            case list
            case detail(id: Int)
            case search(query: String)
            case avatar
            case root
        }
        """

    private static let moyaTarget = """
        import Moya
        extension UserAPI: TargetType {
            var baseURL: URL { URL(string: "https://api.example.com/v1")! }
            var path: String {
                switch self {
                case .list: return "/users"
                case .detail(let id): return "/users/\\(id)"
                case .search: return "users/search?draft=1"
                case .avatar: return "users/avatar"
                case .root: return ""
                }
            }
            var method: Moya.Method {
                switch self {
                case .list, .detail, .search: return .get
                default: return .post
                }
            }
            var task: Task { .requestPlain }
            var headers: [String: String]? { nil }
        }
        """

    @Test("Moya 타겟은 case 마다 route-call 하나이고 경로는 baseURL.appendingPathComponent 의미다")
    func moyaTargetCases() throws {
        let result = project(["/p/UserAPI.swift": Self.moyaAPI, "/p/UserAPI+Target.swift": Self.moyaTarget])
        let calls = result.calls.sorted { ($0.declaration?.qualifiedName ?? "") < ($1.declaration?.qualifiedName ?? "") }
        #expect(calls.map { "\($0.declaration?.qualifiedName ?? "-") \(Self.describe($0.fact))" } == [
            "UserAPI.avatar POST /v1/users/avatar root",
            "UserAPI.detail GET /v1/users/{} root",
            "UserAPI.list GET /v1/users root",
            "UserAPI.root POST /v1 root",
            "UserAPI.search GET /v1/users/search%3Fdraft=1 root",
        ])
        let detail = try #require(calls.first { $0.declaration?.name == "detail" })
        #expect(detail.declaration?.indexName == "detail(id:)")
        #expect(detail.declaration?.start?.path == "/p/UserAPI.swift")
        #expect(detail.fact.location.path == "/p/UserAPI+Target.swift")
        #expect(detail.fact.location.line == 7)
        #expect(detail.fact.authority == "api.example.com")
        #expect(result.counts == RouteCallScanCounts())
    }

    @Test("원시값을 경로로 쓰는 Moya enum 과 모르는 baseURL 은 base 앵커다")
    func moyaRawValuePaths() {
        let source = """
            import Moya
            enum Paths: String, TargetType {
                case users
                case posts = "blog/posts"
                var baseURL: URL { Config.baseURL }
                var path: String { rawValue }
                var method: Moya.Method { .get }
                var task: Task { .requestPlain }
                var headers: [String: String]? { nil }
            }
            """
        let result = project(["/p/Paths.swift": source])
        #expect(result.calls.map { Self.describe($0.fact) }.sorted() == ["GET /blog/posts base", "GET /users base"])
    }

    @Test("프로젝트 프로토콜의 기본 구현 baseURL 을 준수 타입이 물려받는다")
    func moyaProtocolDefaultBaseURL() {
        let source = """
            import Moya
            protocol BaseTarget: TargetType {}
            extension BaseTarget {
                var baseURL: URL { URL(string: "https://api.example.com/v9")! }
                var headers: [String: String]? { nil }
            }
            enum FeedAPI: BaseTarget {
                case latest
                var path: String { "feed/latest" }
                var method: Moya.Method { .get }
                var task: Task { .requestPlain }
            }
            """
        #expect(project(["/p/Feed.swift": source]).calls.map { Self.describe($0.fact) } == ["GET /v9/feed/latest root"])
    }

    @Test("where 가 붙은 분기와 읽지 못한 경로는 dynamic 이고 동사를 모르면 methodDynamic 이다")
    func moyaUnreadableArms() {
        let source = """
            import Moya
            enum SearchAPI: TargetType {
                case query(String)
                case page(Int)
                var baseURL: URL { URL(string: "https://api.example.com")! }
                var path: String {
                    switch self {
                    case .query(let text) where text.isEmpty: return "/empty"
                    case .query: return "/search"
                    case .page(let number): return makePath(number)
                    }
                }
                var method: Moya.Method { currentMethod() }
                var task: Task { .requestPlain }
                var headers: [String: String]? { nil }
            }
            """
        let facts = project(["/p/Search.swift": source]).calls.map(\.fact)
        #expect(facts.map(Self.describe) == ["? dynamic(-) base", "? dynamic(/) root"])
        #expect(facts.map(\.channel) == ["\"/empty\"", "makePath(number)"])
    }

    @Test("저장 프로퍼티로 경로를 받는 기술자 타겟은 선언되지 않은 래퍼로 세고, 선언했으면 세지 않는다")
    func moyaDescriptorTargets() {
        let source = """
            import Moya
            struct Request: TargetType {
                let path: String
                let method: Moya.Method
                var baseURL: URL { URL(string: "https://api.example.com")! }
                var task: Task { .requestPlain }
                var headers: [String: String]? { nil }
            }
            """
        let undeclared = project(["/p/Request.swift": source])
        #expect(undeclared.calls.isEmpty)
        #expect(undeclared.counts.undeclaredWrapperSinks == 1)
        let wrapper = HTTPWrapperDeclaration(
            language: "swift", kind: .constructor, owner: "Request", name: "init", methodArg: .init(label: "method"),
            pathArg: .init(label: "path"), methodEnum: ["get": "GET"], pathAnchor: .base
        )
        #expect(project(["/p/Request.swift": source], wrappers: [wrapper]).counts.undeclaredWrapperSinks == 0)
    }

    @Test("비열거 Moya 타겟은 타입 선언을 심볼로 하는 사실 하나다")
    func moyaStructTarget() throws {
        let source = """
            import Moya
            struct HealthTarget: TargetType {
                var baseURL: URL { URL(string: "https://api.example.com")! }
                var path: String { "/health" }
                var method: Moya.Method { .head }
                var task: Task { .requestPlain }
                var headers: [String: String]? { nil }
            }
            """
        let call = try #require(project(["/p/Health.swift": source]).calls.first)
        #expect(Self.describe(call.fact) == "HEAD /health root")
        #expect(call.declaration?.qualifiedName == "HealthTarget")
        #expect(call.declaration?.start?.line == 2)
    }

    @Test("프로젝트가 TargetType 을 직접 선언하면 Moya 타겟으로 읽지 않는다")
    func projectTargetTypeIsNotMoya() {
        let source = """
            protocol TargetType { var path: String { get } }
            enum Local: TargetType {
                case a
                var path: String { "/a" }
            }
            """
        let result = project(["/p/Local.swift": source])
        #expect(result.calls.isEmpty)
        #expect(result.counts == RouteCallScanCounts())
    }

    @Test("경로 멤버가 없는 타겟은 모델링하지 못한 라우터로 센다")
    func moyaTargetWithoutPath() {
        let source = """
            import Moya
            enum Remote: TargetType { case a }
            """
        let result = project(["/p/Remote.swift": source])
        #expect(result.calls.isEmpty)
        #expect(result.counts.unmodelledRouters == 1)
    }

    // MARK: - Alamofire 라우터

    @Test("Alamofire 라우터는 asURLRequest 의 결합 방식으로 case 별 사실을 내고 안쪽 싱크를 세지 않는다")
    func alamofireRouter() {
        let source = """
            import Alamofire
            enum Router: URLRequestConvertible {
                case users, user(id: Int), create
                static let baseURLString = "https://api.example.com/v3"
                var method: HTTPMethod {
                    switch self {
                    case .users, .user: .get
                    case .create: .post
                    }
                }
                var path: String {
                    switch self {
                    case .users, .create: "/users"
                    case let .user(id): "/users/\\(id)"
                    }
                }
                func asURLRequest() throws -> URLRequest {
                    let url = try Router.baseURLString.asURL()
                    var request = URLRequest(url: url.appendingPathComponent(path))
                    request.method = method
                    return request
                }
            }
            """
        let result = project(["/p/Router.swift": source])
        #expect(result.calls.map { "\($0.declaration?.name ?? "-") \(Self.describe($0.fact))" } == [
            "users GET /v3/users root", "create POST /v3/users root", "user GET /v3/users/{} root",
        ])
        #expect(result.counts == RouteCallScanCounts())
    }

    @Test("라우터의 relativeTo·문자열 연결 결합과 httpMethod 원시값 대입을 읽는다")
    func alamofireRouterJoins() {
        let relative = """
            import Alamofire
            enum Relative: URLRequestConvertible {
                case items
                var path: String { "items" }
                var method: HTTPMethod { .get }
                func asURLRequest() throws -> URLRequest {
                    var request = URLRequest(url: URL(string: path, relativeTo: URL(string: "https://api.example.com/v1/"))!)
                    request.httpMethod = method.rawValue
                    return request
                }
            }
            """
        let concatenated = """
            import Alamofire
            enum Joined: URLRequestConvertible {
                case items
                var path: String { "/items" }
                func asURLRequest() throws -> URLRequest {
                    try URLRequest(url: URL(string: "https://api.example.com/v2" + path)!, method: .post)
                }
            }
            """
        let result = project(["/p/Relative.swift": relative, "/p/Joined.swift": concatenated])
        #expect(result.calls.map { Self.describe($0.fact) }.sorted() == ["GET /v1/items root", "POST /v2/items root"])
    }

    @Test("요청 조립을 읽지 못한 라우터는 사실 대신 센다")
    func unmodelledAlamofireRouter() {
        let source = """
            import Alamofire
            enum Opaque: URLRequestConvertible {
                case a
                var path: String { "/a" }
                func asURLRequest() throws -> URLRequest { URLRequest(url: makeURL()) }
            }
            """
        let result = project(["/p/Opaque.swift": source])
        #expect(result.calls.isEmpty)
        #expect(result.counts.unmodelledRouters == 1)
        #expect(result.counts.unreadableSinks == 0)
    }

    // MARK: - 한계

    @Test("URL 을 바꾸는 Moya 매핑·Alamofire 어댑터와 모델링하지 않는 클라이언트 import 를 센다")
    func coverageCounts() {
        let source = """
            import APIKit
            import OpenAPIRuntime
            import Moya
            let custom = { (target: UserAPI) -> Endpoint in
                Endpoint(url: "https://mirror.example.com" + target.path, sampleResponseClosure: { .networkResponse(200, Data()) },
                         method: target.method, task: target.task, httpHeaderFields: nil)
            }
            let headersOnly = { (target: UserAPI) -> Endpoint in
                Endpoint(url: URL(target: target).absoluteString, sampleResponseClosure: { .networkResponse(200, Data()) },
                         method: target.method, task: target.task, httpHeaderFields: ["A": "b"])
            }
            final class Rewriter: RequestAdapter {
                func adapt(_ urlRequest: URLRequest, for session: Session, completion: @escaping (Result<URLRequest, Error>) -> Void) {
                    var request = urlRequest
                    request.url = URL(string: "https://mirror.example.com")
                    completion(.success(request))
                }
            }
            """
        let counts = scan(source).counts
        #expect(counts.urlRewriters == 2)
        #expect(counts.unmodelledClientImports == ["APIKit": 1])
        #expect(counts.generatedClientImports == 1)
    }
}
