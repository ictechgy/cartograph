@testable import CartographCore
import Testing

/// 공유 벡터가 다루지 않는 경계를 고정한다. 벡터 자체는 `HTTPConformanceTests` 가 실행한다.
@Suite("HTTP 경로 규칙")
struct HTTPRouteRulesTests {
    @Test("정규 문법의 거부 사유를 소비자와 같은 어휘로 돌려준다")
    func grammarReasons() {
        #expect(HTTPRouteTemplate.validate("/" + String(repeating: "a", count: 2_048)) == .tooLong)
        #expect(HTTPRouteTemplate.validate("/a}") == .strayBrace)
        #expect(HTTPRouteTemplate.validate("/a/{}/{**}") == nil)
        #expect(HTTPRouteTemplate.validate("/%GG") == .malformedPercent)
        #expect(Set(HTTPRouteTemplate.Rejection.allCases.map(\.rawValue)).count == 10)
    }

    @Test("잘못된 퍼센트 표기와 NUL 은 보간 자리가 아니면 인코딩한다")
    func normalizeEdges() {
        #expect(HTTPRouteTemplate.normalize("/a%zz") == "/a%25zz")
        #expect(HTTPRouteTemplate.normalize("/a\0") == "/a%00")
        #expect(HTTPRouteTemplate.normalize("/a/\0", holes: true) == "/a/{}")
        #expect(HTTPRouteTemplate.normalize("/%e2%82%ac") == "/%E2%82%AC")
    }

    @Test("잘못된 UTF-8 퍼센트 세그먼트도 길이 기준으로 판정한다")
    func maskInvalidUTF8() {
        #expect(HTTPRouteTemplate.mask("/%FFabcdefgh12345678", authority: nil).maskedSegments == 1)
        #expect(HTTPRouteTemplate.mask("/api/webhooks/1", authority: "discordapp.com").template == "/api/webhooks/{}")
        #expect(HTTPRouteTemplate.mask("/other/webhooks/1", authority: "discord.com").maskedSegments == 0)
    }

    @Test("dynamic 원문의 문자열 조각을 하나의 흐름으로 읽어 비밀이 될 수 있는 부분을 지운다")
    func sanitizeSourceText() {
        let text = { (pieces: [HTTPSourceTextSanitizer.Piece]) in HTTPSourceTextSanitizer.sanitize(pieces) }
        #expect(text([.literal("https://user:pw@api.example.com/v1/items?token=abc")]) == "https://api.example.com/v1/items")
        #expect(text([.code("p + \""), .literal("?token="), .code("\" + \""), .literal("A1b2C3d4E5f6"), .code("\"")]) == "p + \"")
        #expect(text([.literal("https://"), .code(" + \""), .literal("admin:"), .code("\" + user + \""),
                      .literal("@host/x"), .code("\"")]) == "https://host/x\"")
        #expect(text([.literal("/v1/a1b2c3d4"), .code("\" + \""), .literal("e5f6a7b8c9/x")]) == "/v1/{}\" + \"/x")
        #expect(text([.literal("https://hooks.slack.com/services/T0/B0/")]) == "https://hooks.slack.com/{}/{}/{}/")
        #expect(text([.literal("https://discord.com/api/webhooks/1/abc")]) == "https://discord.com/api/webhooks/{}/{}")
        #expect(text([.code("send("), .literal("plain"), .code(")")]) == "send(plain)")
    }

    // MARK: 결합

    @Test("host 없는 문자열을 base 없이 쓰면 요청 URL 이 아니다")
    func absoluteURLNeedsHost() {
        #expect(HTTPRouteURLResolver.resolve([.literal("items")], join: .absoluteURL) == nil)
        #expect(HTTPRouteURLResolver.resolve([.literal("/items")], join: .absoluteURL) == nil)
        #expect(HTTPRouteURLResolver.resolve([], join: .rfc3986) == nil)
    }

    @Test("전체 URL 의 host 형식이 소비자 계약을 벗어나면 authority 를 싣지 않는다")
    func authorityValidation() {
        let host = { (url: String) in HTTPRouteURLResolver.resolve([.literal(url)], join: .absoluteURL)?.authority }
        #expect(host("https://API.example.com") == "api.example.com")
        #expect(host("http://[::1]:8080/x") == "[::1]:8080")
        #expect(host("http://exa_mple.com/x") == nil)
        #expect(host("http://example.com:123456/x") == nil)
        #expect(host("http://-bad.com/x") == nil)
        #expect(host("file:///x") == nil)
    }

    @Test("host 바로 뒤의 query 는 루트 경로이고, host 뒤에 경로가 없으면 dynamic 이다")
    func hostEdges() {
        let query = HTTPRouteURLResolver.resolve([.literal("https://api.example.com?x=1")], join: .absoluteURL)
        #expect(query?.template == "/" && query?.queryTailStripped == true && query?.pathAnchor == .root)
        let noPath = HTTPRouteURLResolver.resolve([.literal("https://"), .value, .literal(".example.com")], join: .absoluteURL)
        #expect(noPath?.isDynamic == true && noPath?.channelPrefix == nil && noPath?.pathAnchor == .base)
        let concatenated = HTTPRouteURLResolver.resolve([.literal("https://"), .value, .literal("/v1/items")], join: .absoluteURL)
        #expect(concatenated?.template == "/v1/items" && concatenated?.pathAnchor == .base && concatenated?.authority == nil)
        let dynamicQuery = HTTPRouteURLResolver.resolve([.literal("https://"), .value, .literal("?a=1")], join: .absoluteURL)
        #expect(dynamicQuery?.template == "/" && dynamicQuery?.pathAnchor == .base)
    }

    @Test("값 뒤에 query 만 오면 경로를 모르고, 값만 있으면 접두사 없는 dynamic 이다")
    func leadingValueEdges() {
        #expect(HTTPRouteURLResolver.resolve([.value, .literal("?a=1")], join: .rfc3986)?.isDynamic == true)
        let bare = HTTPRouteURLResolver.resolve([.value], join: .wrapper(.root))
        #expect(bare?.isDynamic == true && bare?.channelPrefix == nil && bare?.limitation == nil)
    }

    @Test("래퍼는 선언한 앵커를 쓰고, 슬래시 결합은 Foundation 처럼 앞 슬래시 하나만 뗀다")
    func declaredAnchorAndSlashJoin() {
        let wrapper = HTTPRouteURLResolver.resolve([.literal("items")], join: .wrapper(.root))
        #expect(wrapper?.template == "/items" && wrapper?.pathAnchor == .root)
        let joined = HTTPRouteURLResolver.resolve([.literal("/items")], join: .slashJoin)
        #expect(joined?.template == "/items" && joined?.pathAnchor == .base)
        // macOS 26.7 실측: `URL(string: "http://h/api")!.appendingPathComponent("//items")` → `/api//items`.
        let doubled = HTTPRouteURLResolver.resolve([.literal("//items")], join: .slashJoin)
        #expect(doubled?.template == "//items" && doubled?.pathAnchor == .base)
        let rootQuery = HTTPRouteURLResolver.resolve([.literal("?q=1")], join: .wrapper(.base))
        #expect(rootQuery?.template == "/" && rootQuery?.queryTailStripped == true)
    }

    // MARK: 래퍼 선언과 사실

    @Test("소유 타입은 구성 요소 단위 접미사로 대조한다")
    func ownerMatching() {
        let wrapper = HTTPWrapperDeclaration(
            language: "swift", kind: .constructor, owner: "Network.Endpoint", name: "init",
            methodArg: nil, pathArg: .init(index: 0), defaultMethod: "GET", pathAnchor: .root
        )
        #expect(wrapper.ownerMatches(["Endpoint"]))
        #expect(wrapper.ownerMatches(["App", "Network", "Endpoint"]))
        #expect(!wrapper.ownerMatches(["Other", "Endpoint"]))
        #expect(!wrapper.ownerMatches([]))
        #expect(!wrapper.ownerMatches(["MyEndpoint"]))
        #expect(wrapper.displayName == "Network.Endpoint.init")
        #expect(HTTPWrapperBinding.argumentIndex(for: .init(index: 0, label: "path"), labels: ["other"]) == nil)
    }

    @Test("wrapper suffix는 decoded segment를 인코딩하고 불확실성에서 기존 경로를 접두사로 보존한다")
    func wrapperPathSuffixComposition() {
        let base = HTTPRouteResolution(
            template: "/v1/items",
            pathAnchor: .root,
            queryTailStripped: true
        )
        let resolved = HTTPWrapperSuffixComposer.append(
            .segments([.literal("a/b%:@!#{}é"), .value, .literal("?tail")]),
            to: base
        )
        #expect(resolved.template == "/v1/items/a%2Fb%25%3A%40%21%23%7B%7D%C3%A9/{}/%3Ftail")
        #expect(resolved.queryTailStripped)
        #expect(!resolved.isDynamic)

        let uncertain = HTTPWrapperSuffixComposer.append(.dynamic, to: base)
        #expect(uncertain.template == nil)
        #expect(uncertain.channelPrefix == "/v1/items")
        #expect(uncertain.queryTailStripped)

        let dynamicBase = HTTPRouteResolution(
            template: nil,
            channelPrefix: "/v1",
            pathAnchor: .base
        )
        #expect(HTTPWrapperSuffixComposer.append(.segments([.literal("fixed")]), to: dynamicBase) == dynamicBase)
        #expect(HTTPWrapperSuffixComposer.append(.segments([]), to: base) == base)
        for invalid in ["", ".", "..", "\u{001F}"] {
            let result = HTTPWrapperSuffixComposer.append(.segments([.literal(invalid)]), to: base)
            #expect(result.template == nil)
            #expect(result.channelPrefix == "/v1/items")
        }
    }

    @Test("wrapper suffix 확장은 64 segment를 넘으면 기존 정적 경로 뒤를 dynamic으로 둔다")
    func wrapperPathSuffixExpansionLimit() {
        let base = HTTPRouteResolution(template: "/v1", pathAnchor: .base)
        let exact = Array(
            repeating: HTTPWrapperSuffixComposer.Segment.literal("x"),
            count: HTTPWrapperSuffixComposer.maximumExpandedSegments
        )
        #expect(!HTTPWrapperSuffixComposer.append(.segments(exact), to: base).isDynamic)
        let over = exact + [.literal("x")]
        let result = HTTPWrapperSuffixComposer.append(.segments(over), to: base)
        #expect(result.template == nil)
        #expect(result.channelPrefix == "/v1")
        #expect(result.pathAnchor == .base)

        let tooLong = HTTPWrapperSuffixComposer.append(
            .segments([.literal(String(repeating: "a", count: HTTPRouteTemplate.maxLength))]),
            to: base
        )
        #expect(tooLong.template == nil)
        #expect(tooLong.channelPrefix == "/v1")
    }

    @Test("사실은 위치·채널·동사 순으로 정렬하고 선언을 붙인 사본은 나머지를 보존한다")
    func factOrderingAndAttaching() {
        let location = SourceLocation(path: "/p/A.swift", line: 1, column: 1)
        let get = RouteCallFact(method: "GET", channel: "/a", isDynamic: false, pathAnchor: .root, location: location)
        let post = RouteCallFact(method: "POST", channel: "/a", isDynamic: false, pathAnchor: .root, location: location)
        let base = RouteCallFact(method: "GET", channel: "/a", isDynamic: false, pathAnchor: .base, location: location)
        let later = RouteCallFact(method: "GET", channel: "/a", isDynamic: false, pathAnchor: .root,
                                  location: SourceLocation(path: "/p/A.swift", line: 2, column: 1))
        #expect([later, post, base, get].sorted() == [base, get, post, later])
        let attached = get.attaching(.init(qualifiedName: "A.load", usr: "s:load"))
        #expect(attached.symbol?.usr == "s:load" && attached.channel == "/a" && attached.method == "GET")
        let named = get.attaching(.init(qualifiedName: "B", usr: nil))
        #expect(!(named < get.attaching(.init(qualifiedName: "B", usr: nil))))
    }
}
