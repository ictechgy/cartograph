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

    @Test("생성자 오버로드는 구성된 경로 레이블이 있는 시그니처만 선택한다")
    func constructorOverloadsSelectConfiguredPathLabel() {
        let wrappers = [
            HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "ParcelEndpoint", name: "init",
                methodArg: nil, pathArg: .init(label: "route"), defaultMethod: "GET", pathAnchor: .root),
            HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "ParcelEndpoint", name: "init",
                methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root),
        ]
        let source = """
            enum Verb { case get, post }
            struct ParcelEndpoint {
                init(verb: Verb, route: String) {}
                init(method: Verb, path: String) {}
                static func a() -> ParcelEndpoint { ParcelEndpoint(verb: .get, route: "/a") }
                static func b() -> ParcelEndpoint { ParcelEndpoint(method: .post, path: "/b") }
                static func c() -> ParcelEndpoint { .init(verb: .get, route: "/c") }
                static func d() -> ParcelEndpoint { .init(method: .post, path: "/d") }
            }
            """
        let result = HTTPRouteCallScanner(wrappers: wrappers).scan(source: source, path: "/p/Parcel.swift")
        #expect(result.calls.map { "\($0.fact.method ?? "?") \($0.fact.channel ?? "nil")" } == ["GET /a", "GET /b", "GET /c", "GET /d"])
        #expect(result.counts.unprovenReceiverCalls == 0)
    }

    @Test("다른 파일의 타입이 지정한 암시적 enum 경로만 원시값으로 푼다")
    func crossFileTypedImplicitEnumPath() {
        let wrapper = HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "ParcelEndpoint", name: "init",
            methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root)
        var surface = HTTPDeclarationSurface()
        surface.merge(HTTPRouteCallScanner.declarations(
            source: "enum ResourceCatalog: String { case item = \"/items\" }", path: "/p/Catalog.swift"))
        surface.merge(HTTPRouteCallScanner.declarations(
            source: "struct ParcelEndpoint { init(path: ResourceCatalog) {} }", path: "/p/Endpoint.swift"))
        let scanner = HTTPRouteCallScanner(wrappers: [wrapper], surface: surface)
        let result = scanner.scan(source: "func load() { _ = ParcelEndpoint(path: .item) }", path: "/p/Call.swift")
        #expect(result.calls.map(\.fact.channel) == ["/items"])
    }

    @Test("생략한 기본 인자 뒤의 typed enum 경로는 실제 선언 위치를 사용한다")
    func typedImplicitEnumAfterDefaultParameter() {
        let wrapper = HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "ParcelEndpoint", name: "init",
            methodArg: nil, pathArg: .init(label: "resource"), defaultMethod: "GET", pathAnchor: .root)
        var surface = HTTPDeclarationSurface()
        surface.merge(HTTPRouteCallScanner.declarations(
            source: "enum ResourceCatalog: String { case item = \"/items\" }", path: "/p/Catalog.swift"))
        surface.merge(HTTPRouteCallScanner.declarations(
            source: "struct ParcelEndpoint { init(context: String = \"default\", resource: ResourceCatalog) {} }",
            path: "/p/Endpoint.swift"))
        let result = HTTPRouteCallScanner(wrappers: [wrapper], surface: surface).scan(
            source: "func load() { _ = ParcelEndpoint(resource: .item) }", path: "/p/Call.swift"
        )
        #expect(result.calls.map(\.fact.channel) == ["/items"])
    }

    @Test("암시적 enum 경로는 다른 레이블·충돌 타입·조건부·별칭 순환이면 dynamic 이다")
    func implicitEnumPathRejectsAmbiguity() {
        let wrapper = HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "ParcelEndpoint", name: "init",
            methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root)
        var surface = HTTPDeclarationSurface()
        surface.merge(HTTPRouteCallScanner.declarations(source: """
            enum ResourceCatalog: String { case item = "/items" }
            enum OtherCatalog: String { case item = "/other" }
            enum ConditionalCatalog: String {
                #if DEBUG
                case item = "/debug"
                #endif
            }
            typealias AliasA = AliasB
            typealias AliasB = AliasA
            """, path: "/p/Catalog.swift"))
        surface.merge(HTTPRouteCallScanner.declarations(source: """
            struct ParcelEndpoint {
                init(path: ResourceCatalog) {}
                init(path: OtherCatalog) {}
                init(route: ResourceCatalog) {}
                init(path: ConditionalCatalog) {}
                init(path: AliasA) {}
                static func a() -> ParcelEndpoint { .init(path: .item) }
            }
            """, path: "/p/Endpoint.swift"))
        let result = HTTPRouteCallScanner(wrappers: [wrapper], surface: surface)
            .scan(source: "func load() { _ = ParcelEndpoint(path: .item) }", path: "/p/Call.swift")
        #expect(result.calls.count == 1)
        #expect(result.calls[0].fact.isDynamic)
    }

    @Test("암시적 enum 경로의 각 불확실성은 독립적으로 dynamic 이다")
    func implicitEnumPathRejectsIndependentUncertainty() {
        let wrapper = HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "ParcelEndpoint", name: "init",
            methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root)
        let cases: [(String, String)] = [
            ("enum ResourceCatalog: String { #if DEBUG\ncase item = \"/debug\"\n#endif }", "init(path: ResourceCatalog) {}"),
            ("typealias AliasA = AliasB\ntypealias AliasB = AliasA", "init(path: AliasA) {}"),
            ("", "init(path: MissingCatalog) {}"),
            ("enum ResourceCatalog: String { case item = \"/items\" }\nenum OtherCatalog: String { case item = \"/other\" }", "init(path: ResourceCatalog) {}\ninit(path: OtherCatalog) {}"),
        ]
        for (declarations, initializer) in cases {
            var surface = HTTPDeclarationSurface()
            surface.merge(HTTPRouteCallScanner.declarations(source: declarations, path: "/p/Types.swift"))
            surface.merge(HTTPRouteCallScanner.declarations(source: "struct ParcelEndpoint { \(initializer) }", path: "/p/Endpoint.swift"))
            let result = HTTPRouteCallScanner(wrappers: [wrapper], surface: surface)
                .scan(source: "func load() { _ = ParcelEndpoint(path: .item) }", path: "/p/Call.swift")
            #expect(result.calls.count == 1)
            #expect(result.calls[0].fact.isDynamic)
        }
    }

    @Test("qualified nested enum type와 owner-local shadow는 basename으로 섞지 않는다")
    func implicitEnumPathKeepsQualifiedAndLexicalOwners() {
        let wrapper = HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "ParcelEndpoint", name: "init",
            methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root)
        var surface = HTTPDeclarationSurface()
        surface.merge(HTTPRouteCallScanner.declarations(source: """
            enum Outer { enum Catalog: String { case item = "/outer" } }
            enum Catalog: String { case item = "/global" }
            struct ParcelEndpoint { init(path: Outer.Catalog) {} }
            """, path: "/p/Types.swift"))
        let qualified = HTTPRouteCallScanner(wrappers: [wrapper], surface: surface)
            .scan(source: "func load() { _ = ParcelEndpoint(path: .item) }", path: "/p/Call.swift")
        #expect(qualified.calls[0].fact.channel == "/outer")

        var local = HTTPDeclarationSurface()
        local.merge(HTTPRouteCallScanner.declarations(source: """
            enum Catalog: String { case item = "/global" }
            struct ParcelEndpoint {
                enum Catalog: String { case item = "/local" }
                init(path: Catalog) {}
            }
            """, path: "/p/Types.swift"))
        let shadowed = HTTPRouteCallScanner(wrappers: [wrapper], surface: local)
            .scan(source: "func load() { _ = ParcelEndpoint(path: .item) }", path: "/p/Call.swift")
        #expect(shadowed.calls[0].fact.channel == "/local")
    }

    @Test("소유자와 무관한 중첩 타입의 같은 basename은 암시적 경로를 만들지 않는다")
    func implicitEnumPathRejectsUnrelatedNestedType() {
        let wrapper = HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "ParcelEndpoint", name: "init",
            methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root)
        var surface = HTTPDeclarationSurface()
        surface.merge(HTTPRouteCallScanner.declarations(source: """
            enum Other { enum Catalog: String { case item = "/other" } }
            struct ParcelEndpoint { init(path: Catalog) {} }
            """, path: "/p/Types.swift"))
        let result = HTTPRouteCallScanner(wrappers: [wrapper], surface: surface)
            .scan(source: "func load() { _ = ParcelEndpoint(path: .item) }", path: "/p/Call.swift")
        #expect(result.calls.count == 1)
        #expect(result.calls[0].fact.isDynamic)
    }

    @Test("후행 클로저가 빠진 인자 목록으로 생성자 오버로드를 추측하지 않는다")
    func trailingClosureKeepsImplicitEnumPathDynamic() throws {
        let wrapper = HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "ClosureEndpoint", name: "init",
            methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root)
        let source = """
            enum CatalogA: String { case item = "/a" }
            enum CatalogB: String { case item = "/b" }
            struct ClosureEndpoint {
                init(path: CatalogA, build: () -> Void) {}
                init(path: CatalogB) {}
            }
            func load() { _ = ClosureEndpoint(path: .item) {} }
            """
        let fact = try #require(HTTPRouteCallScanner(wrappers: [wrapper])
            .scan(source: source, path: "/p/Trailing.swift").calls.first?.fact)
        #expect(fact.isDynamic)
        #expect(fact.channel != "/b")
    }

    @Test("소유 타입의 별칭은 같은 이름의 전역 enum보다 먼저 경로 타입을 정한다")
    func ownerTypeAliasShadowsGlobalEnumForImplicitPath() throws {
        let wrapper = HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "AliasEndpoint", name: "init",
            methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root)
        let source = """
            enum Catalog: String { case item = "/global" }
            enum OtherCatalog: String { case item = "/other" }
            struct AliasEndpoint {
                typealias Catalog = OtherCatalog
                init(path: Catalog) {}
            }
            func load() { _ = AliasEndpoint(path: .item) }
            """
        let fact = try #require(HTTPRouteCallScanner(wrappers: [wrapper])
            .scan(source: source, path: "/p/Alias.swift").calls.first?.fact)
        #expect(fact.channel == "/other")
        #expect(!fact.isDynamic)
    }

    @Test("소유 타입의 제네릭 매개변수는 같은 이름의 전역 enum을 가린다")
    func ownerGenericShadowsGlobalEnumForImplicitPath() throws {
        let wrapper = HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "GenericEndpoint", name: "init",
            methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root)
        var surface = HTTPDeclarationSurface()
        surface.merge(HTTPRouteCallScanner.declarations(source: """
            enum Catalog: String { case item = "/global" }
            enum RuntimeCatalog: String { case item = "/runtime" }
            struct GenericEndpoint<Catalog> {}
            """, path: "/p/Owner.swift"))
        surface.merge(HTTPRouteCallScanner.declarations(
            source: "extension GenericEndpoint { init(path: Catalog) {} }", path: "/p/Extension.swift"))
        let fact = try #require(HTTPRouteCallScanner(wrappers: [wrapper], surface: surface)
            .scan(source: "func load() { _ = GenericEndpoint<RuntimeCatalog>(path: .item) }",
                  path: "/p/Call.swift").calls.first?.fact)
        #expect(fact.isDynamic)
        #expect(fact.channel != "/global")
    }

    @Test("생성자의 제네릭 매개변수는 같은 이름의 전역 enum을 가린다")
    func initializerGenericShadowsGlobalEnumForImplicitPath() throws {
        let wrapper = HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "GenericInitializer", name: "init",
            methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root)
        let source = """
            protocol PathCatalog { static var item: Self { get } }
            enum Catalog: String { case item = "/global" }
            enum RuntimeCatalog: String, PathCatalog { case item = "/runtime" }
            struct GenericInitializer {
                init<Catalog: PathCatalog>(path: Catalog) {}
            }
            func load() { _ = GenericInitializer(path: .item) }
            """
        let fact = try #require(HTTPRouteCallScanner(wrappers: [wrapper])
            .scan(source: source, path: "/p/InitializerGeneric.swift").calls.first?.fact)
        #expect(fact.isDynamic)
        #expect(fact.channel != "/global")
    }

    @Test("기본 경로 인자를 생략한 생성자 호출도 dynamic 사실로 남긴다")
    func omittedDefaultPathRemainsDynamic() throws {
        let wrapper = HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "DefaultEndpoint", name: "init",
            methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root)
        let source = """
            enum Catalog: String { case item = "/items" }
            struct DefaultEndpoint { init(path: Catalog = .item) {} }
            func load() { _ = DefaultEndpoint() }
            """
        let result = HTTPRouteCallScanner(wrappers: [wrapper]).scan(source: source, path: "/p/Default.swift")
        let fact = try #require(result.calls.first?.fact)
        #expect(result.calls.count == 1)
        #expect(fact.isDynamic)
        #expect(fact.channel == nil)
    }

    @Test("명시한 다른 경로 래퍼는 기본 경로를 생략할 수 있는 래퍼보다 우선한다")
    func explicitPathWrapperWinsOverOmittedDefaultPath() throws {
        let wrappers = [
            HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "DefaultEndpoint", name: "init",
                methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root),
            HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "DefaultEndpoint", name: "init",
                methodArg: nil, pathArg: .init(label: "route"), defaultMethod: "POST", pathAnchor: .root),
        ]
        let source = """
            enum Catalog: String { case item = "/items" }
            struct DefaultEndpoint {
                init(path: Catalog = .item, route: String) {}
            }
            func load() { _ = DefaultEndpoint(route: "/chosen") }
            """
        let fact = try #require(HTTPRouteCallScanner(wrappers: wrappers)
            .scan(source: source, path: "/p/Explicit.swift").calls.first?.fact)
        #expect(fact.method == "POST")
        #expect(fact.channel == "/chosen")
        #expect(!fact.isDynamic)
    }

    @Test("타입을 확정할 수 없는 실행 가능 오버로드도 enum 경로의 모호성에 포함한다")
    func unknownViableParameterTypeKeepsImplicitPathDynamic() throws {
        let wrapper = HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "AmbiguousEndpoint", name: "init",
            methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root)
        let source = """
            protocol PathCatalog { static var item: Self { get } }
            enum Catalog: String, PathCatalog { case item = "/catalog" }
            struct AmbiguousEndpoint {
                init(path: Catalog) {}
                init<Other: PathCatalog>(path: Other) {}
            }
            func load() { _ = AmbiguousEndpoint(path: .item) }
            """
        let fact = try #require(HTTPRouteCallScanner(wrappers: [wrapper])
            .scan(source: source, path: "/p/Ambiguous.swift").calls.first?.fact)
        #expect(fact.isDynamic)
        #expect(fact.channel != "/catalog")
    }

    @Test("완전하지 않은 생성자 집합에서는 암시적 enum 경로를 확정하지 않는다")
    func incompleteInitializerSetsKeepImplicitPathDynamic() throws {
        let cases: [(owner: String, declarations: [String])] = [
            ("InheritedEndpoint", [
                """
                enum OtherCatalog: String { case item = "/other" }
                enum Catalog: String { case item = "/catalog" }
                class BaseEndpoint {
                    init() {}
                    convenience init(path: OtherCatalog) { self.init() }
                }
                """,
                """
                class InheritedEndpoint: BaseEndpoint {
                    override init() { super.init() }
                    convenience init(path: Catalog) { self.init() }
                }
                """,
            ]),
            ("ExternalEndpoint", [
                """
                enum Catalog: String { case item = "/catalog" }
                class ExternalEndpoint: FrameworkEndpoint {
                    init(path: Catalog) {}
                }
                """,
            ]),
            ("ExtensionEndpoint", [
                "enum Catalog: String { case item = \"/catalog\" }",
                "extension ExtensionEndpoint { init(path: Catalog) {} }",
            ]),
            ("MemberwiseEndpoint", [
                """
                enum OtherCatalog: String { case item = "/other" }
                enum Catalog: String { case item = "/catalog" }
                struct MemberwiseEndpoint { let path: OtherCatalog }
                """,
                "extension MemberwiseEndpoint { init(path: Catalog) { self.path = .item } }",
            ]),
        ]
        for item in cases {
            let wrapper = HTTPWrapperDeclaration(
                language: "swift", kind: .constructor, owner: item.owner, name: "init",
                methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root
            )
            var surface = HTTPDeclarationSurface()
            for (index, source) in item.declarations.enumerated() {
                surface.merge(HTTPRouteCallScanner.declarations(
                    source: source, path: "/p/\(item.owner)-\(index).swift"
                ))
            }
            let result = HTTPRouteCallScanner(wrappers: [wrapper], surface: surface).scan(
                source: "func load() { _ = \(item.owner)(path: .item) }",
                path: "/p/\(item.owner)-Call.swift"
            )
            let fact = try #require(result.calls.first?.fact)
            #expect(result.calls.count == 1)
            #expect(fact.isDynamic)
            #expect(fact.channel != "/catalog")
        }
    }

    @Test("일반 struct와 프로젝트에서 확인한 protocol-only class는 암시적 enum 경로를 유지한다")
    func completeInitializerSetsResolveImplicitPath() throws {
        let cases: [(owner: String, channel: String, source: String)] = [
            ("StructEndpoint", "/struct", """
                enum Catalog: String { case item = "/struct" }
                struct StructEndpoint {
                    init(path: Catalog) {}
                }
                func load() { _ = StructEndpoint(path: .item) }
                """),
            ("PrimaryInitEndpoint", "/extension", """
                enum OtherCatalog: String { case item = "/other" }
                enum Catalog: String { case item = "/extension" }
                struct PrimaryInitEndpoint {
                    let stored: OtherCatalog
                    init() { stored = .item }
                }
                extension PrimaryInitEndpoint {
                    init(path: Catalog) { stored = .item }
                }
                func load() { _ = PrimaryInitEndpoint(path: .item) }
                """),
            ("ProtocolEndpoint", "/protocol", """
                enum Catalog: String { case item = "/protocol" }
                enum Namespace { protocol Marker {} }
                final class ProtocolEndpoint: Namespace.Marker {
                    init(path: Catalog) {}
                }
                func load() { _ = ProtocolEndpoint(path: .item) }
                """),
            ("KnownSubclass", "/known", """
                enum Catalog: String { case item = "/known" }
                class KnownBase { init(value: Int) {} }
                final class KnownSubclass: KnownBase {
                    init(path: Catalog) { super.init(value: 0) }
                }
                func load() { _ = KnownSubclass(path: .item) }
                """),
        ]
        for item in cases {
            let wrapper = HTTPWrapperDeclaration(
                language: "swift", kind: .constructor, owner: item.owner, name: "init",
                methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET", pathAnchor: .root
            )
            let fact = try #require(HTTPRouteCallScanner(wrappers: [wrapper])
                .scan(source: item.source, path: "/p/\(item.owner).swift").calls.first?.fact)
            #expect(fact.channel == item.channel)
            #expect(!fact.isDynamic)
        }
    }

    @Test("wrapper suffix는 scalar와 array segment만 경로에 붙이고 불확실하면 base prefix를 보존한다")
    func wrapperPathSuffixSegments() throws {
        let wrapper = HTTPWrapperDeclaration(
            language: "swift", kind: .function, owner: "Client", name: "request",
            methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET",
            pathAnchor: .root,
            pathSuffix: [
                .literal("fixed/segment"),
                .argument(.init(label: "id"), shape: .scalar),
                .argument(.init(label: "tags"), shape: .array),
            ]
        )
        let scan: (String) throws -> RouteCallFact = { body in
            let source = """
                final class Client {
                    func request(path: String, id: Any? = nil, tags: [Any] = []) {}
                    \(body)
                }
                """
            return try #require(HTTPRouteCallScanner(wrappers: [wrapper])
                .scan(source: source, path: "/p/Suffix.swift").calls.first?.fact)
        }

        let resolved = try scan("""
            func load(id: String) {
                let parts = ["red", id]
                request(path: "/v1/items?token=secret", id: "a/b", tags: parts)
            }
            """)
        #expect(resolved.channel == "/v1/items/fixed%2Fsegment/a%2Fb/red/{}")
        #expect(resolved.queryTailStripped)
        #expect(!resolved.isDynamic)

        let opaqueScalar = try scan("""
            func makeID() -> String { "runtime" }
            func load() { request(path: "/v1/items", id: makeID(), tags: ["x"]) }
            """)
        #expect(opaqueScalar.channel == "/v1/items/fixed%2Fsegment/{}/x")
        #expect(!opaqueScalar.isDynamic)

        let scalarBits = try scan(
            "func load() { request(path: \"/v1/items\", id: true, tags: [1, false]) }"
        )
        #expect(scalarBits.channel == "/v1/items/fixed%2Fsegment/{}/{}/{}")
        #expect(!scalarBits.isDynamic)

        for body in [
            "func load(tags: [String]) { request(path: \"/v1/items\", id: \"x\", tags: tags) }",
            "func load() { request(path: \"/v1/items\") }",
            "func load() { request(path: \"/v1/items\", id: nil, tags: []) }",
            "func load() { request(path: \"/v1/items\", id: [\"x\"], tags: []) }",
            "func load() { request(path: \"/v1/items\", id: \".\", tags: []) }",
            "func load() { request(path: \"/v1/items\", id: \"x\", tags: [\"\"]) }",
            "func load() { request(path: \"/v1/items\", id: \"x\", tags: [\"..\"]) }",
        ] {
            let fact = try scan(body)
            #expect(fact.isDynamic)
            #expect(fact.channel != "/v1/items/fixed%2Fsegment/x")
            #expect(fact.channelPrefix == "/v1/items")
        }

        let emptyArray = try scan(
            "func load() { request(path: \"/v1/items\", id: \"x\", tags: []) }"
        )
        #expect(emptyArray.channel == "/v1/items/fixed%2Fsegment/x")
        #expect(!emptyArray.isDynamic)

        let measuredSource = """
            final class Client {
                func request(path: String, id: String, tags: [String]) {}
                func load(tags: [String]) {
                    request(path: "/v1/items", id: "x", tags: tags)
                }
            }
            """
        let measured = HTTPRouteCallScanner(wrappers: [wrapper]).scan(
            source: measuredSource,
            path: "/p/SuffixCount.swift"
        )
        #expect(measured.calls.count == 1)
        #expect(measured.counts.wrapperSuffixUnresolved == 1)

        let oversizedWrapper = HTTPWrapperDeclaration(
            language: "swift", kind: .function, owner: "Client", name: "request",
            methodArg: nil, pathArg: .init(label: "path"), defaultMethod: "GET",
            pathAnchor: .root,
            pathSuffix: [.literal(String(repeating: "a", count: HTTPRouteTemplate.maxLength))]
        )
        let oversized = HTTPRouteCallScanner(wrappers: [oversizedWrapper]).scan(
            source: """
                final class Client {
                    func request(path: String) {}
                    func load() { request(path: "/v1") }
                }
                """,
            path: "/p/SuffixLength.swift"
        )
        #expect(oversized.calls.first?.fact.channelPrefix == "/v1")
        #expect(oversized.counts.wrapperSuffixUnresolved == 1)

        let uncertainMain = try scan(
            #"func load(id: String) { request(path: "/v1/\(id).json", id: "x", tags: []) }"#
        )
        #expect(uncertainMain.isDynamic)
        #expect(uncertainMain.channel != "/v1/fixed%2Fsegment/x")
        #expect(uncertainMain.channelPrefix == "/v1/")
    }

    @Test("백틱 식별자의 레이블과 enum case도 선언 표면과 같은 이름으로 대조한다")
    func backtickedIdentifiersPreserveImplicitEnumBinding() throws {
        let wrapper = HTTPWrapperDeclaration(language: "swift", kind: .constructor, owner: "KeywordEndpoint", name: "init",
            methodArg: nil, pathArg: .init(label: "default"), defaultMethod: "GET", pathAnchor: .root)
        let source = """
            enum `Type`: String { case `default` = "/default" }
            struct KeywordEndpoint { init(`default`: `Type`) {} }
            func load() { _ = KeywordEndpoint(`default`: .`default`) }
            """
        let fact = try #require(HTTPRouteCallScanner(wrappers: [wrapper])
            .scan(source: source, path: "/p/Backticks.swift").calls.first?.fact)
        #expect(fact.channel == "/default")
        #expect(!fact.isDynamic)
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

    @Test("매개변수와 지역 이름이 같은 정적 타입 이름을 가리면 경로를 추측하지 않는다")
    func boundRouteNamesShadowStaticTypes() throws {
        let body = """
            enum routes { static let users = "/wrong" }
            struct RuntimePaths { let users: String }
            func foundation(routes: RuntimePaths) {
                _ = URLRequest(url: URL(string: "https://api.example.com" + routes.users)!)
            }
            func alamofire(routes: RuntimePaths) {
                _ = AF.request("https://api.example.com" + routes.users)
            }
            func local() {
                let routes: RuntimePaths = fatalError()
                _ = URLRequest(url: URL(string: "https://api.example.com" + routes.users)!)
            }
            """
        let found = facts(body, wrappers: [])
        #expect(found.count == 3)
        #expect(found.allSatisfy { $0.isDynamic })
        #expect(found.allSatisfy { $0.channel != "/wrong" })
    }

    @Test("제네릭 타입·지역 타입·지역 별칭·associatedtype 이름은 전역 경로 타입을 가린다")
    func lexicalTypeNamesShadowStaticTypes() throws {
        let body = """
            enum RoutePaths: String { case users = "/wrong" }
            struct RuntimePaths { let users: String }
            protocol RouteProvider { associatedtype RoutePaths }
            func generic<RoutePaths>(_ value: RoutePaths) {
                _ = URLRequest(url: URL(string: "https://api.example.com" + RoutePaths.users.rawValue)!)
            }
            func localType() {
                struct RoutePaths { static let users = "/runtime" }
                _ = URLRequest(url: URL(string: "https://api.example.com" + RoutePaths.users)!)
            }
            func localAlias() {
                typealias RoutePaths = RuntimePaths
                _ = URLRequest(url: URL(string: "https://api.example.com" + RoutePaths.users.rawValue)!)
            }
            extension RouteProvider {
                static func request() -> URLRequest {
                    URLRequest(url: URL(string: "https://api.example.com" + RoutePaths.users.rawValue)!)
                }
            }
            """
        let found = facts(body, wrappers: [])
        #expect(found.count == 4)
        #expect(found.allSatisfy { $0.isDynamic })
        #expect(found.allSatisfy { $0.channel != "/wrong" })
    }

    @Test("파일 수준에서 모호하지 않은 타입 별칭은 정적 경로로 해석한다")
    func unambiguousFileTypeAliasStillResolvesStaticType() throws {
        let body = """
            enum RoutePaths: String { case users = "/users" }
            typealias APIPaths = RoutePaths
            func request() {
                _ = URLRequest(url: URL(string: "https://api.example.com" + APIPaths.users.rawValue)!)
            }
            """
        let found = facts(body, wrappers: [])
        #expect(found.count == 1)
        #expect(found.first?.channel == "/users")
        #expect(found.first?.isDynamic == false)
    }

    @Test("여러 단계 상속한 프로토콜의 associatedtype도 전역 경로 타입을 가린다")
    func transitiveAssociatedTypeShadow() throws {
        let body = """
            enum RoutePaths { static let users = "/wrong" }
            protocol RuntimeRouteValues { static var users: String { get } }
            protocol Root { associatedtype RoutePaths: RuntimeRouteValues }
            protocol Mid: Root {}
            protocol Leaf: Mid {}
            extension Leaf {
                func request() {
                    _ = URLRequest(url: URL(string: "https://api.example.com" + RoutePaths.users)!)
                }
            }
            """
        let fact = try #require(facts(body, wrappers: []).first)
        #expect(fact.isDynamic)
        #expect(fact.channel != "/wrong")
    }

    @Test("조건부 지역 타입 별칭이 전역 경로 타입을 가릴 수 있으면 경로를 단정하지 않는다")
    func conditionalLocalTypeShadow() throws {
        let body = """
            enum RoutePaths { static let users = "/wrong" }
            struct RuntimePaths { static var users: String { runtimePath() } }
            func runtimePath() -> String { "/runtime" }
            func request() {
                #if RUNTIME
                typealias RoutePaths = RuntimePaths
                #endif
                _ = URLRequest(url: URL(string: "https://api.example.com" + RoutePaths.users)!)
            }
            """
        let fact = try #require(facts(body, wrappers: []).first)
        #expect(fact.isDynamic)
        #expect(fact.channel != "/wrong")
    }

    @Test("호출 뒤에 선언한 지역 타입 별칭도 같은 블록 전체의 전역 타입 이름을 가린다")
    func forwardLocalTypeShadow() throws {
        for conditional in [false, true] {
            let declaration = conditional
                ? "#if RUNTIME\ntypealias RoutePaths = RuntimePaths\n#endif"
                : "typealias RoutePaths = RuntimePaths"
            let body = """
                enum RoutePaths { static let users = "/wrong" }
                struct RuntimePaths { static var users: String { runtimePath() } }
                func runtimePath() -> String { "/runtime" }
                func request() {
                    _ = URLRequest(url: URL(string: "https://api.example.com" + RoutePaths.users)!)
                    \(declaration)
                }
                """
            let fact = try #require(facts(body, wrappers: []).first)
            #expect(fact.isDynamic)
            #expect(fact.channel != "/wrong")
        }
    }

    @Test("같은 파일의 조건부·비문자열 정적 멤버도 상수 바인딩 우회로로 치환하지 않는다")
    func sameFileUnsafeStaticMembersStayDynamic() throws {
        for declaration in [
            "enum RoutePaths { static let users: StaticString = \"/wrong\" }",
            "enum RoutePaths { #if STAGING\nstatic let users = \"/wrong\"\n#endif\n}",
        ] {
            let body = """
                \(declaration)
                func request() {
                    _ = URLRequest(url: URL(string: "https://api.example.com" + RoutePaths.users)!)
                }
                """
            let fact = try #require(facts(body, wrappers: []).first)
            #expect(fact.isDynamic)
            #expect(fact.channel != "/wrong")
        }
    }

    @Test("첨자의 제네릭 타입 이름도 전역 경로 타입을 가린다")
    func genericSubscriptTypeShadow() throws {
        let body = """
            protocol RouteValues { static var users: String { get } }
            enum RoutePaths { static let users = "/wrong" }
            struct Client {
                subscript<RoutePaths: RouteValues>(_: RoutePaths.Type) -> URLRequest {
                    URLRequest(url: URL(string: "https://api.example.com" + RoutePaths.users)!)
                }
            }
            """
        let fact = try #require(facts(body, wrappers: []).first)
        #expect(fact.isDynamic)
        #expect(fact.channel != "/wrong")
    }

    @Test("첨자 매개변수의 값 이름도 전역 경로 타입을 가린다")
    func subscriptValueShadow() throws {
        let body = """
            struct RuntimePaths { let users: String }
            enum RoutePaths { static let users = "/wrong" }
            struct Client {
                subscript(RoutePaths: RuntimePaths) -> URLRequest {
                    URLRequest(url: URL(string: "https://api.example.com" + RoutePaths.users)!)
                }
            }
            """
        let fact = try #require(facts(body, wrappers: []).first)
        #expect(fact.isDynamic)
        #expect(fact.channel != "/wrong")
    }

    @Test("타입 본문과 익스텐션에 나뉜 정적 멤버와 파일 별칭은 모두 정적으로 해석한다")
    func extensionMemberAndSameFileAliasResolveStaticTypes() throws {
        let body = """
            enum RoutePaths: String { case users = "/users" }
            typealias APIPaths = RoutePaths
            extension RoutePaths { static let root = "/root" }
            func request() {
                _ = URLRequest(url: URL(string: "https://api.example.com" + APIPaths.users.rawValue)!)
                _ = URLRequest(url: URL(string: "https://api.example.com" + RoutePaths.root)!)
            }
            """
        let found = facts(body, wrappers: [])
        #expect(found.map(\.channel) == ["/users", "/root"])
        #expect(found.allSatisfy { !$0.isDynamic })
    }

    @Test("컨테이너의 제네릭 타입 이름은 전역 경로 타입을 가린다")
    func genericContainerTypeShadowsStaticType() throws {
        let body = """
            enum RoutePaths: String { case users = "/wrong" }
            struct GenericContainer<RoutePaths> {
                func request() {
                    _ = URLRequest(url: URL(string: "https://api.example.com" + RoutePaths.users.rawValue)!)
                }
            }
            """
        let found = facts(body, wrappers: [])
        #expect(found.count == 1)
        #expect(found.first?.isDynamic == true)
        #expect(found.first?.channel != "/wrong")
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

    @Test("모듈로 한정하거나 init 으로 부른 URLRequest·URL 도 요청이다")
    func qualifiedFoundationTypes() {
        let body = """
            func a() {
                _ = Foundation.URLRequest(url: URL(string: "https://api.example.com/a")!)
                _ = URLRequest.init(url: URL(string: "https://api.example.com/b")!)
                _ = URLRequest(url: Foundation.URL(string: "https://api.example.com/c")!)
                _ = URLRequest(url: URL.init(string: "https://api.example.com/d")!)
                _ = Other.URLRequest(url: URL(string: "https://api.example.com/e")!)
            }
            """
        #expect(routes(body, wrappers: []) == ["GET /a", "GET /b", "GET /c", "GET /d"])
    }

    @Test("경로 리터럴의 NUL 은 보간 자리가 아니라 인코딩된 문자다")
    func literalNULIsNotAHole() {
        #expect(routes("func a() { _ = Endpoint(method: .get, path: \"/items\\u{0}tail\") }") == ["GET /items%00tail"])
        #expect(HTTPRouteComposer.compose([.literal("/a\u{0}"), .literal("/"), .value]) == .template("/a%00/{}", queryTailStripped: false))
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
