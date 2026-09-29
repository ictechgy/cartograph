@testable import CartographCore
import Testing

/// Foundation·Alamofire·Moya 의 경로·동사 규칙. 기대값은 macOS 26.7 Foundation 실측과 라이브러리 소스에서 왔다.
@Suite("HTTP 라이브러리 규칙")
struct HTTPClientLibraryRulesTests {
    @Test("디코드된 경로 텍스트는 pchar 밖 문자와 퍼센트를 인코딩하고, component 는 슬래시도 인코딩한다")
    func encodesDecodedText() {
        #expect(HTTPFoundationPath.encodeDecoded("users?x=1#f", keepsSlash: true) == "users%3Fx=1%23f")
        #expect(HTTPFoundationPath.encodeDecoded("a%20b", keepsSlash: true) == "a%2520b")
        #expect(HTTPFoundationPath.encodeDecoded("a b/é;+:@~", keepsSlash: true) == "a%20b/%C3%A9;+:@~")
        #expect(HTTPFoundationPath.encodeDecoded("a/b{x}", keepsSlash: false) == "a%2Fb%7Bx%7D")
        // 결과는 정규 템플릿 문법을 따라 정규화해도 바뀌지 않는다.
        let encoded = HTTPFoundationPath.encodeDecoded("/v1/é?%", keepsSlash: true)
        #expect(HTTPRouteTemplate.normalize(encoded) == encoded)
        #expect(HTTPRouteTemplate.validate(encoded) == nil)
    }

    @Test("appendingPathComponent 결합은 base 끝 슬래시 하나와 조각 앞 슬래시 하나만 뗀다")
    func trimsOneSlash() {
        #expect(HTTPFoundationPath.joinTrimmingOneSlash(base: "/api/", component: "/users") == ("/api", "users"))
        #expect(HTTPFoundationPath.joinTrimmingOneSlash(base: "/api", component: "//users") == ("/api", "/users"))
        #expect(HTTPFoundationPath.joinTrimmingOneSlash(base: "/api//", component: "x") == ("/api/", "x"))
    }

    @Test("라이브러리 동사 멤버는 소문자 계약 동사만 받고 CONNECT·QUERY 는 동사가 아니다")
    func libraryVerbs() {
        #expect(HTTPLibraryMethod.verb(forMemberName: "patch") == "PATCH")
        #expect(HTTPLibraryMethod.verb(forMemberName: "connect") == nil)
        #expect(HTTPLibraryMethod.verb(forMemberName: "query") == nil)
        #expect(HTTPLibraryMethod.verb(forMemberName: "GET") == nil)
        #expect(HTTPLibraryMethod.verb(forRawValue: "DELETE") == "DELETE")
        #expect(HTTPLibraryMethod.verb(forRawValue: "delete") == nil)
        #expect(HTTPLibraryMethod.alamofireDefaultVerb(forRequestMethod: "upload") == "POST")
        #expect(HTTPLibraryMethod.alamofireDefaultVerb(forRequestMethod: "download") == "GET")
        #expect(HTTPLibraryMethod.alamofireDefaultVerb(forRequestMethod: "session") == nil)
    }

    private static let base = HTTPTargetURL(parts: [.literal("https://api.example.com/v1")], join: .absoluteURL)

    @Test("Moya 는 빈 경로면 baseURL 자체이고 아니면 appendingPathComponent 이며 물음표를 인코딩한다")
    func moyaSemantics() {
        #expect(HTTPTargetRouteRules.moya(base: Self.base, path: [.literal("")]).template == "/v1")
        #expect(HTTPTargetRouteRules.moya(base: nil, path: [.literal("")]).template == "/")
        let query = HTTPTargetRouteRules.moya(base: Self.base, path: [.literal("users?x=1")])
        #expect(query.template == "/v1/users%3Fx=1" && query.pathAnchor == .root && query.authority == "api.example.com")
        let unknown = HTTPTargetRouteRules.moya(base: nil, path: [.value, .literal("/items")])
        #expect(unknown.template == "/{}/items" && unknown.pathAnchor == .base)
        let whole = HTTPTargetRouteRules.moya(base: Self.base, path: [.value])
        #expect(whole.isDynamic && whole.channelPrefix == "/v1/")
    }

    @Test("라우터 레시피는 결합 방식마다 Foundation 의미를 따른다")
    func routerRecipes() {
        func resolve(_ join: HTTPRouterRecipe.Join, base: HTTPTargetURL?, _ path: String) -> String {
            let recipe = HTTPRouterRecipe(owner: "R", join: join, base: base, method: .member)
            let resolution = HTTPTargetRouteRules.router(recipe, path: [.literal(path)])
            return "\(resolution.template ?? "dynamic") \(resolution.pathAnchor.rawValue)"
        }
        #expect(resolve(.appendingPathComponent, base: Self.base, "") == "/v1/ root")
        #expect(resolve(.appendingComponent, base: Self.base, "/a/b") == "/v1/%2Fa%2Fb root")
        #expect(resolve(.relativeTo, base: Self.base, "items") == "/items root")
        let directory = HTTPTargetURL(parts: [.literal("https://api.example.com/v1/")], join: .absoluteURL)
        #expect(resolve(.relativeTo, base: directory, "items?x=1") == "/v1/items root")
        #expect(resolve(.relativeTo, base: directory, "/items") == "/items root")
        #expect(resolve(.relativeTo, base: nil, "items") == "/items base")
        let stringBase = HTTPTargetURL(parts: [.literal("https://api.example.com/v2")], join: .absoluteURL)
        #expect(resolve(.concatenation, base: stringBase, "/items") == "/v2/items root")
        #expect(resolve(.concatenation, base: nil, "/items") == "/items base")
    }

    @Test("분기 표는 위에서부터 처음 맞는 행을 고르고 default 행은 모든 case 에 맞는다")
    func armLookup() {
        let location = SourceLocation(path: "/p/A.swift", line: 1, column: 1)
        let table = HTTPTargetMemberTable(owner: "A", member: .method, arms: [
            .init(cases: ["a"], value: .verb("GET"), location: location),
            .init(cases: nil, value: .verb("POST"), location: location),
            .init(cases: ["b"], value: .verb("PUT"), location: location),
        ])
        #expect(table.arm(for: "a")?.value == .verb("GET"))
        #expect(table.arm(for: "b")?.value == .verb("POST"))
        #expect(table.arm(for: nil)?.value == .verb("POST"))
        let noDefault = HTTPTargetMemberTable(owner: "A", member: .path, arms: [.init(cases: ["a"], value: nil, location: location)])
        #expect(noDefault.arm(for: "z") == nil)
    }
}
