import CartographCore
@testable import CartographSyntax
import Testing

@Suite("HTTP 호출 스캐너")
struct HTTPRouteCallScannerTests {
    /// 합성 픽스처의 생성자 래퍼. 레이블 인자, enum 동사.
    private static let endpoint = HTTPWrapperDeclaration(
        language: "swift", kind: .constructor, owner: "Endpoint", name: "init",
        methodArg: .init(label: "method"), pathArg: .init(label: "path"),
        methodEnum: ["get": "GET", "post": "POST", "delete": "DELETE"], pathAnchor: .root, service: "example-api"
    )
    /// 합성 픽스처의 함수 래퍼. 동사 인자를 생략하면 POST.
    private static let send = HTTPWrapperDeclaration(
        language: "swift", kind: .function, owner: "Client", name: "send",
        methodArg: .init(label: "method"), pathArg: .init(label: "path"), defaultMethod: "POST", pathAnchor: .root
    )

    private static let prelude = """
        enum Verb: String { case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE" }
        struct Endpoint {
            init(method: Verb, path: String, auth: Bool = false) {}
        }
        final class Client {
            func send(path: String, method: String = "POST", body: String? = nil) {}
        }

        """

    private func scan(
        _ body: String, wrappers: [HTTPWrapperDeclaration] = [endpoint, send], isTestSource: Bool = false,
        resolvedValues: [CartographCore.SourceLocation: String] = [:]
    ) -> RouteCallScanResult {
        HTTPRouteCallScanner(wrappers: wrappers).scan(
            source: Self.prelude + body, path: "/p/App.swift", isTestSource: isTestSource, resolvedValues: resolvedValues
        )
    }

    private func facts(_ body: String, wrappers: [HTTPWrapperDeclaration] = [endpoint, send]) -> [RouteCallFact] {
        scan(body, wrappers: wrappers).calls.map(\.fact)
    }

    private func routes(_ body: String, wrappers: [HTTPWrapperDeclaration] = [endpoint, send]) -> [String] {
        facts(body, wrappers: wrappers).map { "\($0.method ?? "?") \($0.channel ?? "nil")" }
    }

    /// 프렐류드 뒤 본문의 줄 번호. 프렐류드는 7줄이다.
    private func line(_ bodyLine: Int) -> Int { bodyLine + 7 }

    // MARK: 동사와 인자 바인딩

    @Test("레이블 생성자 래퍼의 암시적 멤버 동사를 methodEnum 으로 바꾼다")
    func constructorWrapperWithImplicitMemberVerb() throws {
        let fact = try #require(facts("func a() { _ = Endpoint(method: .get, path: \"/items\") }").first)
        #expect(fact.method == "GET")
        #expect(fact.channel == "/items")
        #expect(fact.isDynamic == false)
        #expect(fact.pathAnchor == .root)
        #expect(fact.service == "example-api")
        #expect(fact.location == CartographCore.SourceLocation(path: "/p/App.swift", line: line(1), column: 16))
    }

    @Test("한정된 enum case 와 정확한 대문자 문자열만 동사다")
    func qualifiedCaseAndExactLiteralVerbs() {
        let body = """
            func a() { _ = Endpoint(method: Verb.post, path: "/a") }
            extension Client {
                func b() { send(path: "/b", method: "DELETE") }
                func c() { send(path: "/c", method: "get") }
                func d() { _ = Endpoint(method: .patch, path: "/d") }
            }
            """
        #expect(routes(body) == ["POST /a", "DELETE /b", "? /c", "? /d"])
    }

    @Test("동사 인자를 생략하면 기본값을, 리터럴이 아닌 인자가 있으면 methodDynamic 을 낸다")
    func defaultMethodOnlyWhenOmitted() {
        let body = """
            extension Client {
                func a() { send(path: "/a") }
                func b(verb: String) { send(path: "/b", method: verb) }
            }
            """
        #expect(routes(body) == ["POST /a", "? /b"])
    }

    @Test("같은 파일 상수로 동사를 푼다")
    func constantVerb() {
        #expect(routes("let verb = \"PATCH\"\nextension Client { func a() { send(path: \"/a\", method: verb) } }") == ["PATCH /a"])
    }

    // MARK: 경로 조립

    @Test("같은 파일 상수와 연결을 치환하고 세그먼트 전체 보간은 {} 가 된다")
    func constantsConcatenationAndInterpolation() {
        let body = """
            let root = "/api"
            extension Endpoint {
                static let items = root + "/v1/items"
                static func a(id: String) -> Endpoint { Endpoint(method: .get, path: "\\(items)/\\(id)") }
                static func b(id: String, sub: String) -> Endpoint { Endpoint(method: .get, path: Self.items + "/\\(id)/tags/\\(sub)") }
                static func c() -> Endpoint {
                    let local = "/local"
                    return Endpoint(method: .get, path: local)
                }
            }
            func d() { _ = Endpoint(method: .get, path: Endpoint.items) }
            """
        #expect(routes(body) == ["GET /api/v1/items/{}", "GET /api/v1/items/{}/tags/{}", "GET /local", "GET /api/v1/items"])
    }

    @Test("부분 세그먼트 보간은 증명된 접두사와 함께 dynamic 이다")
    func partialSegmentIsDynamic() throws {
        let fact = try #require(facts("func a(name: String) { _ = Endpoint(method: .get, path: \"/files/\\(name).json\") }").first)
        #expect(fact.isDynamic)
        #expect(fact.channelPrefix == "/files/")
        #expect(fact.channel == "\"/files/\\(name).json\"")
    }

    @Test("리터럴의 첫 물음표·샵 뒤를 떼고 queryTailStripped 를 단다")
    func literalQueryTail() {
        let body = """
            func a(page: Int, id: String) {
                _ = Endpoint(method: .get, path: "/items?page=\\(page)")
                _ = Endpoint(method: .get, path: "/items/\\(id)?expand=true")
                _ = Endpoint(method: .get, path: "/docs#top")
            }
            """
        let found = facts(body)
        #expect(found.map(\.channel) == ["/items", "/items/{}", "/docs"])
        #expect(found.allSatisfy { $0.queryTailStripped })
    }

    @Test("끝에 붙은 지역 변수는 query 꼬리로 증명될 때만 뗀다")
    func suffixComposition() {
        let body = """
            func a(q: String, tag: String?) {
                let suffix = q.isEmpty ? "" : "?q=\\(q)"
                _ = Endpoint(method: .get, path: "/search\\(suffix)")
                let mapped = tag.map { "?tag=" + $0 } ?? ""
                _ = Endpoint(method: .get, path: "/tags\\(mapped)")
                var open = ""
                open = q
                _ = Endpoint(method: .get, path: "/open\\(open)")
                _ = Endpoint(method: .get, path: "/a\\(suffix)/b")
            }
            """
        let found = facts(body)
        #expect(found.map(\.channel) == ["/search", "/tags", "\"/open\\(open)\"", "\"/a\\(suffix)/b\""])
        #expect(found.map(\.queryTailStripped) == [true, true, false, false])
        #expect(found.map(\.channelPrefix) == [nil, nil, "/open", "/a"])
    }

    @Test("전체 URL 에서 userinfo·query 를 떼고 host 를 소문자 authority 로 싣는다")
    func fullURLStripping() throws {
        let fact = try #require(facts("func a() { _ = Endpoint(method: .get, path: \"https://user:pw@API.Example.com:8443/v1/items?token=abc\") }").first)
        #expect(fact.channel == "/v1/items")
        #expect(fact.authority == "api.example.com:8443")
        #expect(fact.pathAnchor == .root)
        #expect(fact.queryTailStripped)
    }

    @Test("host 에 값이 섞인 URL 과 값으로 시작하는 경로는 base 앵커다")
    func dynamicHostAndLeadingValue() {
        let body = """
            func a(host: String, base: String) {
                _ = Endpoint(method: .get, path: "https://\\(host)/v1/items")
                _ = Endpoint(method: .get, path: "\\(base)/items")
                _ = Endpoint(method: .get, path: "\\(base)items")
            }
            """
        let found = facts(body)
        #expect(found.map(\.channel?.first) == ["/", "/", "\""])
        #expect(found.map(\.pathAnchor) == [.base, .base, .base])
        #expect(found[2].isDynamic)
        #expect(found[2].limitation == HTTPRouteComposer.ambiguousBaseJoin)
    }

    @Test("고엔트로피 세그먼트와 웹훅 경로를 가리고, dynamic 원문에도 같은 규칙을 적용한다")
    func maskingEverywhere() throws {
        let body = """
            func a(name: String) {
                _ = Endpoint(method: .get, path: "/v1/items/550e8400-e29b-41d4-a716-446655440000")
                _ = Endpoint(method: .post, path: "https://hooks.slack.com/services/T0000/B0000/XXXXXXXXXXXXXXXX")
                _ = Endpoint(method: .get, path: "https://user:secret@api.example.com/v1/a1b2c3d4e5f6a7b8c9/\\(name).json?token=abc")
            }
            """
        let found = facts(body)
        #expect(found.map(\.channel) == ["/v1/items/{}", "/{}/{}/{}/{}", found[2].channel])
        #expect(found.map(\.maskedSegments) == [1, 4, 1])
        let dynamic = found[2]
        #expect(dynamic.isDynamic)
        #expect(dynamic.channelPrefix == "/v1/{}/")
        let text = try #require(dynamic.channel)
        for secret in ["secret", "token", "a1b2c3d4e5f6a7b8c9"] { #expect(!text.contains(secret)) }
    }

    @Test("여러 줄 호출은 호출식이 시작하는 줄과 UTF-8 바이트 열을 보고한다")
    func multiLineLocation() throws {
        let body = """
            func a() {
                let 값 = Endpoint(
                    method: .get,
                    path: "/multi"
                )
            }
            """
        let fact = try #require(facts(body).first)
        // `값` 은 UTF-8 로 3바이트다. 글자 열(13)이 아니라 바이트 열(15)이어야 한다.
        #expect(fact.location.line == line(2))
        #expect(fact.location.column == 15)
    }

    @Test("값 흐름이 증명한 파일 밖 상수를 치환한다")
    func valueFlowResolvedConstant() throws {
        let body = "func a() { _ = Endpoint(method: .get, path: Remote.path) }"
        #expect(facts(body).first?.isDynamic == true)
        let column = try #require(body.utf8.firstRange(of: "Remote".utf8)).lowerBound
        let offset = body.utf8.distance(from: body.utf8.startIndex, to: column) + 1
        let resolved = scan(body, resolvedValues: [CartographCore.SourceLocation(path: "/p/App.swift", line: line(1), column: offset): "/remote"])
        #expect(resolved.calls.map(\.fact.channel) == ["/remote"])
    }

    @Test("경로 인자가 없는 래퍼 호출은 채널 없는 dynamic 이다")
    func missingPathArgument() throws {
        let wrapper = HTTPWrapperDeclaration(
            language: "swift", kind: .function, owner: "Client", name: "send",
            methodArg: nil, pathArg: .init(label: "route"), defaultMethod: "GET", pathAnchor: .base
        )
        let fact = try #require(facts("extension Client { func a() { send(path: \"/x\") } }", wrappers: [wrapper]).first)
        #expect(fact.isDynamic && fact.channel == nil && fact.pathAnchor == .base && fact.method == "GET")
    }

    // MARK: 생성자 호출 모양

    @Test("생성자 래퍼를 여러 표기로 알아보고 다르게 한정된 이름은 받지 않는다")
    func constructorSpellings() {
        let body = """
            extension Endpoint {
                static func a() -> Endpoint { Self(method: .get, path: "/a") }
                static func b() -> Endpoint { .init(method: .get, path: "/b") }
                static func c() -> Endpoint { Endpoint.init(method: .get, path: "/c") }
                static func d() -> Endpoint { App.Endpoint(method: .get, path: "/d") }
                static func e() -> Query { .init(name: "q", value: "/e") }
            }
            func g() { _ = Endpoint(verb: .get, route: "/g") }
            """
        #expect(routes(body) == ["GET /a", "GET /b", "GET /c", "GET /d"])
    }

    @Test("모듈로 한정한 소유 타입은 다르게 한정된 같은 이름을 받지 않는다")
    func qualifiedOwner() {
        let wrapper = HTTPWrapperDeclaration(
            language: "swift", kind: .constructor, owner: "Network.Endpoint", name: "init",
            methodArg: .init(label: "method"), pathArg: .init(label: "path"), methodEnum: ["get": "GET"], pathAnchor: .root
        )
        let body = """
            func a() { _ = Network.Endpoint(method: .get, path: "/a") }
            func b() { _ = Endpoint(method: .get, path: "/b") }
            func c() { _ = Other.Endpoint(method: .get, path: "/c") }
            """
        #expect(routes(body, wrappers: [wrapper]) == ["GET /a", "GET /b"])
    }

    @Test("래퍼 자신의 본문 안에서 일어나는 위임은 호출 지점이 아니다")
    func wrapperBodyIsSkipped() {
        let body = """
            extension Endpoint {
                init(get path: String) { self.init(method: .get, path: path) }
            }
            """
        let result = scan(body)
        #expect(result.calls.isEmpty)
        #expect(result.counts.undeclaredWrapperSinks == 0)
    }

    // MARK: 함수 호출 모양

    @Test("함수 래퍼는 소유 타입 안·self·정적 한정·표기된 수신자에서만 맞는다")
    func functionSpellings() {
        let body = """
            extension Client {
                func a() { send(path: "/a") }
                func b() { self.send(path: "/b") }
            }
            struct Screen {
                let client: Client
                func c() { client.send(path: "/c") }
                func d() { Client.send(path: "/d") }
                func e() { send(path: "/e") }
                func send(path: String) {}
            }
            """
        #expect(routes(body) == ["POST /a", "POST /b", "POST /c", "POST /d"])
    }

    @Test("수신자 타입을 증명하지 못한 동명 호출은 사실 대신 센다")
    func unprovenReceiverIsCounted() {
        let body = """
            func a(any: AnyObject, subject: Subject) {
                any.send(path: "/a")
                subject.send(42)
            }
            """
        let result = scan(body)
        #expect(result.calls.isEmpty)
        #expect(result.counts.unprovenReceiverCalls == 1)
    }

    @Test("모듈 함수 래퍼는 한정 없는 호출로 맞고, 같은 이름의 메서드를 가진 타입 안에서는 아니다")
    func moduleFunctionWrapper() {
        let wrapper = HTTPWrapperDeclaration(
            language: "swift", kind: .function, owner: "Networking", name: "request",
            methodArg: .init(index: 0), pathArg: .init(index: 1), pathAnchor: .base
        )
        let body = """
            func request(_ method: String, _ path: String) {}
            func a() { request("GET", "/a") }
            struct Local {
                func request(_ method: String, _ path: String) {}
                func b() { request("GET", "/b") }
            }
            func c() { Networking.request("PUT", "items") }
            """
        let found = facts(body, wrappers: [wrapper])
        #expect(found.map { "\($0.method ?? "?") \($0.channel ?? "nil") \($0.pathAnchor.rawValue)" } == ["GET /a base", "PUT /items base"])
    }

    // MARK: 매개변수 통과

    @Test("매개변수를 경로로 흘려보내면 선언되지 않은 래퍼로 세고, 선언된 래퍼 타입의 매개변수면 세지 않는다")
    func passThroughClassification() {
        let body = """
            func fetch(path: String) -> Endpoint { Endpoint(method: .get, path: path) }
            func load(route: String) -> URLRequest { URLRequest(url: URL(string: "\\(route)?x=1")!) }
            func make(endpoint: Endpoint) -> URLRequest { URLRequest(url: URL(string: endpoint.path)!) }
            """
        let result = scan(body)
        #expect(result.calls.isEmpty)
        #expect(result.counts.undeclaredWrapperSinks == 2)
        #expect(result.counts.unreadableSinks == 0)
    }

    @Test("선언된 함수 래퍼의 본문 안 싱크는 래퍼 구현이라 세지 않는다")
    func sinkInsideDeclaredFunctionWrapper() {
        let body = """
            extension Client {
                func send(path: String, method: String) {
                    var request = URLRequest(url: URL(string: path)!)
                    request.httpMethod = method
                }
            }
            """
        let result = scan(body)
        #expect(result.calls.isEmpty)
        #expect(result.counts == RouteCallScanCounts())
    }

    // MARK: 직접 요청

    @Test("URLRequest 의 동사는 같은 본문의 httpMethod 대입으로 정하고 모르면 methodDynamic 이다")
    func directRequestMethods() {
        let body = """
            func a() {
                let request = URLRequest(url: URL(string: "https://api.example.com/a")!)
                _ = request
            }
            func b() {
                var request = URLRequest(url: URL(string: "https://api.example.com/b")!)
                request.httpMethod = "PUT"
            }
            func c(verb: String) {
                var request = URLRequest(url: URL(string: "https://api.example.com/c")!)
                request.httpMethod = verb
            }
            func d() {
                var request = URLRequest(url: URL(string: "https://api.example.com/d")!)
                request.httpMethod = "PUT"
                request.httpMethod = "POST"
            }
            func e() -> URLRequest {
                var request = URLRequest(url: URL(string: "https://api.example.com/e")!)
                return request
            }
            func f() -> URLRequest { URLRequest(url: URL(string: "https://api.example.com/f")!) }
            func g() async throws { _ = try await URLSession.shared.data(for: URLRequest(url: URL(string: "https://api.example.com/g")!)) }
            """
        #expect(routes(body, wrappers: []) == ["GET /a", "PUT /b", "? /c", "? /d", "? /e", "? /f", "GET /g"])
    }

    @Test("URL 을 받는 세션 호출은 GET 이고, 요청 변수를 받는 호출은 사실이 아니다")
    func sessionCalls() {
        let body = """
            func a(session: URLSession, request: URLRequest) async throws {
                _ = try await session.data(from: URL(string: "https://api.example.com/a")!)
                _ = session.dataTask(with: request)
            }
            """
        #expect(routes(body, wrappers: []) == ["GET /a"])
    }

    @Test("상대 해석과 슬래시 결합은 결합 방식대로 앵커를 정한다")
    func joinSemantics() {
        let body = """
            func a(base: URL) {
                guard let rooted = URL(string: "/v1/a", relativeTo: base) else { return }
                _ = URLRequest(url: rooted)
                _ = URLRequest(url: URL(string: "v1/b", relativeTo: base)!)
                _ = URLRequest(url: base.appendingPathComponent("/v1/c"))
                _ = URLRequest(url: URL(string: "https://api.example.com/v1/")!.appendingPathComponent("d"))
                _ = URLRequest(url: base.appending(path: "v1").appending(path: "e"))
            }
            """
        let found = facts(body, wrappers: [])
        #expect(found.map { "\($0.channel ?? "nil") \($0.pathAnchor.rawValue)" }
            == ["/v1/a root", "/v1/b base", "/v1/c base", "/v1/d root", "/v1/e base"])
        #expect(found[3].authority == "api.example.com")
    }

    @Test("읽을 수 없는 요청 URL 은 사실 대신 센다")
    func unreadableSinks() {
        let body = """
            final class Loader {
                var target: URL?
                func a() { _ = URLRequest(url: target!) }
                func b() { _ = URLRequest(url: URL(string: "relative/only")!) }
                func c(link: String) { _ = URLRequest(url: URL(string: link.lowercased())!) }
            }
            """
        let result = scan(body, wrappers: [])
        #expect(result.calls.isEmpty)
        #expect(result.counts.unreadableSinks == 2)
        #expect(result.counts.undeclaredWrapperSinks == 1)
    }

    @Test("웹 뷰 페이지 탐색과 기술자 실행기의 싱크는 사실도 한계도 아니다")
    func pageLoadsAndDescriptorExecutors() {
        let body = """
            final class Browser {
                var page: URL?
                func a(webView: WebView) { webView.load(URLRequest(url: page!)) }
                func b(webView: WebView) { webView.load(URLRequest(url: URL(string: "https://example.com/help")!)) }
            }
            func execute(endpoint: Endpoint, base: URL) -> URLRequest {
                let components = URLComponents(url: base, resolvingAgainstBaseURL: false)
                return URLRequest(url: components!.url!)
            }
            """
        let result = scan(body)
        #expect(result.calls.isEmpty)
        #expect(result.counts == RouteCallScanCounts())
    }

    // MARK: 리뷰 회귀

    @Test("scheme 리터럴 뒤 host 값과 경로를 연결하면 host 뒤 경로가 base 앵커다")
    func concatenatedDynamicHost() {
        let body = """
            let fixedHost = "api.example.com"
            func a(host: String) {
                _ = URLRequest(url: URL(string: "https://" + host + "/v1/items")!)
                _ = URLRequest(url: URL(string: "https://" + host + ":8443/v1/items?x=1")!)
                _ = URLRequest(url: URL(string: "https://" + fixedHost + "/v1/items")!)
                _ = URLRequest(url: URL(string: "https://" + host)!)
            }
            """
        let found = facts(body, wrappers: [])
        #expect(found.map { "\($0.channel ?? "nil") \($0.pathAnchor.rawValue) \($0.authority ?? "-")" } == [
            "/v1/items base -", "/v1/items base -", "/v1/items root api.example.com", found[3].channel.map { "\($0) base -" },
        ])
        #expect(found[3].isDynamic && found[3].channelPrefix == nil)
    }

    @Test("여러 리터럴로 나뉜 query·userinfo·고엔트로피 세그먼트도 dynamic 원문에 남지 않는다")
    func sanitizesAcrossLiteralTokens() throws {
        let body = """
            final class Api {
                var base = ""
                func a() { _ = URLRequest(url: URL(string: base + "/v1?token=" + "A1b2C3d4E5f6")!) }
                func b(host: String) { _ = URLRequest(url: URL(string: base + "https://" + "admin:" + "s3cret" + "@" + host + "/x")!) }
                func c() { _ = URLRequest(url: URL(string: base + "/hooks/" + "a1b2c3d4" + "e5f6a7b8c9" + "/run")!) }
                func d() { _ = URLRequest(url: URL(string: base + "/q" + "#frag" + "ment")!) }
                func e() { _ = URLRequest(url: URL(string: base + "?token=" + "A1b2C3d4E5f6")!) }
            }
            """
        let found = facts(body, wrappers: [])
        #expect(found.count == 5)
        let texts = found.compactMap(\.channel)
        #expect(texts.count == 5)
        #expect(found.map(\.isDynamic) == [false, true, false, false, true])
        for secret in ["A1b2C3d4E5f6", "token", "admin", "s3cret", "a1b2c3d4", "e5f6a7b8c9", "frag", "ment"] {
            #expect(!texts.contains { $0.contains(secret) }, "\(secret) leaked: \(texts)")
        }
        #expect(texts[2].contains("run"))
    }

    @Test("요청을 다른 이름에 복사하거나 넘기면 동사를 확정하지 않는다")
    func requestAliasesEscape() {
        let body = """
            func a() {
                var request = URLRequest(url: URL(string: "https://api.example.com/a")!)
                var copy = request
                copy.httpMethod = "POST"
            }
            func b(session: URLSession) async throws {
                let request = URLRequest(url: URL(string: "https://api.example.com/b")!)
                _ = try await session.data(for: request)
            }
            func c() {
                let request = URLRequest(url: URL(string: "https://api.example.com/c")!)
                execute(request)
            }
            func d() {
                var request = URLRequest(url: URL(string: "https://api.example.com/d")!)
                var other = URLRequest(url: URL(string: "https://api.example.com/e")!)
                other = request
            }
            """
        #expect(routes(body, wrappers: []) == ["? /a", "GET /b", "? /c", "? /d", "GET /e"])
    }

    // MARK: 문서 성질

    @Test("테스트 소스의 호출에는 표식을 단다")
    func testSourceFlag() {
        let result = scan("func a() { _ = Endpoint(method: .get, path: \"/t\") }", isTestSource: true)
        #expect(result.calls.map(\.fact.isTestSource) == [true])
    }

    @Test("감싸는 선언과 래퍼별 호출 수를 함께 돌려준다")
    func declarationsAndCounts() throws {
        let result = scan("extension Client {\n    func load() { send(path: \"/x\") }\n}")
        let declaration = try #require(result.calls.first?.declaration)
        #expect(declaration.qualifiedName == "Client.load")
        #expect(declaration.indexName == "load()")
        #expect(result.callsByWrapper == [1: 1])
    }

    @Test("같은 입력을 두 번 훑으면 같은 결과다")
    func deterministic() {
        let body = "func a(id: String) { _ = Endpoint(method: .get, path: \"/x/\\(id)\") }"
        #expect(scan(body) == scan(body))
    }

    @Test("선언 표면이 래퍼 선언의 소유 타입과 함수를 확인한다")
    func surfaceDeclares() {
        let surface = HTTPRouteCallScanner.declarations(source: Self.prelude + "func request(_ path: String) {}")
        #expect(surface.declares(Self.endpoint))
        #expect(surface.declares(Self.send))
        let module = HTTPWrapperDeclaration(language: "swift", kind: .function, owner: "Net", name: "request",
            methodArg: nil, pathArg: .init(index: 0), defaultMethod: "GET", pathAnchor: .base)
        #expect(surface.declares(module))
        let wrongName = HTTPWrapperDeclaration(language: "swift", kind: .function, owner: "Client", name: "post",
            methodArg: nil, pathArg: .init(index: 0), defaultMethod: "POST", pathAnchor: .root)
        #expect(!surface.declares(wrongName))
        let wrongInit = HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "Endpoint", name: "make",
            methodArg: nil, pathArg: .init(index: 0), defaultMethod: "GET", pathAnchor: .root)
        #expect(!surface.declares(wrongInit))
        var merged = HTTPDeclarationSurface()
        merged.merge(surface)
        #expect(merged == surface)
    }
}
