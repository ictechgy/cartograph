/// 라우터 타입(Moya `TargetType`, Alamofire `URLRequestConvertible`)의 멤버 하나를 case 별로 읽은 값.
///
/// 라우터는 URL 문자열을 호출 지점이 아니라 타입의 멤버(`path`·`method`·`baseURL`)에 case 별 분기로
/// 적는다. 호출 지점(`provider.request(.users)`)에는 경로가 없으므로, 구문 스캐너가 멤버를 이 값으로
/// 옮기고 구문을 모르는 규칙(`HTTPTargetRouteRules`)이 case 하나의 경로를 조립한다. 멤버가 여러 파일의
/// 익스텐션에 흩어져 있어도 파일별로 모은 표를 문서 단위로 합칠 수 있게 구문 노드를 담지 않는다.
public enum HTTPTargetValue: Hashable, Sendable {
    /// 경로 조각. 원시값을 경로로 쓰는 enum(`var path: String { rawValue }`)은 case 마다 다르다.
    case path([HTTPTargetPathPart])
    /// 동사. nil 이면 계약 동사가 아니다(`methodDynamic`).
    case verb(String?)
    /// base URL 식을 펼친 조각과 결합 방식.
    case url(HTTPTargetURL)
}

/// 라우터 경로 조각. `selfRawValue` 는 case 의 문자열 원시값 자리다.
public enum HTTPTargetPathPart: Hashable, Sendable {
    case part(HTTPURLPart)
    case selfRawValue
}

/// URL 식을 펼친 결과. 조각 목록과, 그 조각을 경로로 읽는 결합 방식이다.
public struct HTTPTargetURL: Hashable, Sendable {
    public let parts: [HTTPURLPart]
    public let join: HTTPPathJoin

    public init(parts: [HTTPURLPart], join: HTTPPathJoin) {
        self.parts = parts
        self.join = join
    }
}

/// 라우터 타입 멤버 하나(`path`·`method`·`baseURL`)의 분기 표.
///
/// `switch self` 의 각 분기가 행 하나다. `cases` 가 nil 인 행은 모든 case 에 맞는다(`default` 나 분기 없는
/// 단일 식). Swift 의 `switch` 처럼 위에서부터 처음 맞는 행이 답이다. `where` 가 붙은 분기는 조건에 따라
/// 다음 행으로 넘어갈 수 있으므로 값을 모르는 행(`value == nil`)으로 적는다 — 추측한 경로는 조인을 오염시킨다.
public struct HTTPTargetMemberTable: Hashable, Sendable {
    /// 표가 적는 멤버.
    public enum Member: String, Hashable, Sendable, CaseIterable {
        case path
        case method
        case baseURL
    }

    /// 분기 하나.
    public struct Arm: Hashable, Sendable {
        /// 이 분기가 맞는 case 이름들. nil 이면 모든 case.
        public let cases: Set<String>?
        /// 분기의 값. nil 이면 읽지 못했다.
        public let value: HTTPTargetValue?
        /// dynamic 원문(가린 뒤). 경로를 확정하지 못했을 때 사실의 `channel` 이 된다.
        public let dynamicText: String?
        /// 분기 식이 시작하는 위치. 경로 분기면 route-call 의 `location` 이 된다.
        public let location: SourceLocation

        public init(cases: Set<String>?, value: HTTPTargetValue?, dynamicText: String? = nil, location: SourceLocation) {
            self.cases = cases
            self.value = value
            self.dynamicText = dynamicText
            self.location = location
        }
    }

    /// 멤버를 선언한 타입 사슬(`API`, `Network.UserAPI`). 프로토콜 익스텐션의 기본 구현이면 프로토콜 이름이다.
    public let owner: String
    public let member: Member
    public let arms: [Arm]
    /// 초기식 없는 저장 프로퍼티(`let path: String`)인지. 값은 생성 지점이 넣으므로 기술자 타입이다.
    public let isStoredWithoutValue: Bool
    public let isTestSource: Bool

    public init(owner: String, member: Member, arms: [Arm], isStoredWithoutValue: Bool = false, isTestSource: Bool = false) {
        self.owner = owner
        self.member = member
        self.arms = arms
        self.isStoredWithoutValue = isStoredWithoutValue
        self.isTestSource = isTestSource
    }

    /// case 하나에 맞는 첫 분기. 맞는 분기가 없으면 nil. 비열거 타입은 `caseName` 이 nil 이다.
    public func arm(for caseName: String?) -> Arm? {
        arms.first { arm in
            guard let cases = arm.cases else { return true }
            return caseName.map(cases.contains) ?? false
        }
    }
}

/// Alamofire 라우터의 `asURLRequest()` 가 요청 URL 을 만드는 방식.
///
/// 라우터 본문은 자유 형식이라 전부 읽을 수 없다. 본문의 `URLRequest(url:)` 이 하나이고 그 URL 이
/// `path` 멤버를 아래 네 방식 중 하나로 base 에 붙일 때만 레시피가 된다. 그 밖의 라우터는 사실을 내지 않고
/// 호출 측 한계로 센다.
public struct HTTPRouterRecipe: Hashable, Sendable {
    /// `path` 멤버를 base 에 붙이는 방식.
    public enum Join: String, Hashable, Sendable {
        /// `base.appendingPathComponent(path)` · `base.appending(path: path)`.
        case appendingPathComponent
        /// `base.appending(component: path)` — `/` 까지 인코딩한다.
        case appendingComponent
        /// `URL(string: path, relativeTo: base)` — RFC 3986 상대 해석.
        case relativeTo
        /// `URL(string: base + path)` — 문자열 연결 뒤 전체 URL 로 읽는다.
        case concatenation
    }

    /// 요청 동사를 어디서 얻는지.
    public enum MethodSource: Hashable, Sendable {
        /// `method` 멤버의 case 별 값(`request.method = method`, `httpMethod = method.rawValue`).
        case member
        /// 본문이 정한 값. nil 이면 계약 동사가 아니거나 여러 값이다.
        case fixed(String?)
    }

    public let owner: String
    public let join: Join
    /// base URL. nil 이면 base 식을 읽지 못했다(경로는 base 앵커).
    public let base: HTTPTargetURL?
    public let method: MethodSource

    public init(owner: String, join: Join, base: HTTPTargetURL?, method: MethodSource) {
        self.owner = owner
        self.join = join
        self.base = base
        self.method = method
    }
}

/// 라우터 case 하나의 경로를 라이브러리 의미대로 조립한다.
public enum HTTPTargetRouteRules {
    /// Moya 15.0.3 `URL(target:)`: 경로가 비면 `baseURL`, 아니면 `baseURL.appendingPathComponent(path)`.
    ///
    /// `Endpoint.urlRequest()` 는 그 URL 의 `absoluteString` 을 `URL(string:)` 으로 다시 읽으므로 인코딩이
    /// 그대로 전송된다. 그래서 `path` 의 `?` 는 query 가 아니라 `%3F` 다(오라클에서 서버가 받은 요청 줄로 확인).
    public static func moya(base: HTTPTargetURL?, path: [HTTPURLPart]) -> HTTPRouteResolution {
        if path.allSatisfy({ $0 == .literal("") }) {
            guard let base else { return .init(template: "/", pathAnchor: .base) }
            return HTTPRouteURLResolver.resolve(base.parts, join: base.join) ?? .init(template: nil, pathAnchor: .base)
        }
        return appending(pathMember(path), to: base, keepsSlash: true)
    }

    /// Alamofire 라우터 레시피로 조립한다.
    public static func router(_ recipe: HTTPRouterRecipe, path: [HTTPURLPart]) -> HTTPRouteResolution {
        switch recipe.join {
        case .appendingPathComponent: appending(pathMember(path), to: recipe.base, keepsSlash: true)
        case .appendingComponent: appending(path, to: recipe.base, keepsSlash: false)
        case .relativeTo: relative(path, to: recipe.base)
        case .concatenation:
            HTTPRouteURLResolver.resolve((recipe.base?.parts ?? [.value]) + path, join: .absoluteURL)
                ?? .init(template: nil, pathAnchor: .base)
        }
    }

    /// `base.appendingPathComponent(component)` 의 조각. 리터럴은 디코드된 텍스트로 보고 인코딩한다.
    ///
    /// base 를 모르면 경로는 base 앵커다. base 가 전체 URL 리터럴이면 host 뒤 경로가 root 다.
    public static func appending(_ component: [HTTPURLPart], to base: HTTPTargetURL?, keepsSlash: Bool) -> HTTPRouteResolution {
        let encoded = component.map { part -> HTTPURLPart in
            guard case let .literal(text) = part else { return part }
            return .literal(HTTPFoundationPath.encodeDecoded(text, keepsSlash: keepsSlash))
        }
        // base 를 모르면 빈 base 에 붙인 것과 같은 경로를 base 앵커로 쓴다. 조각 맨 앞의 값은 base 식이
        // 아니라 첫 세그먼트다 — 문자열 연결 규칙(`leading-value-is-base`)을 쓰면 안 된다.
        let joined = slashJoined(base?.parts ?? [], encoded, trimsComponentSlash: keepsSlash)
        let join = base?.join ?? .wrapper(.base)
        return HTTPRouteURLResolver.resolve(joined, join: join) ?? .init(template: nil, pathAnchor: .base)
    }

    /// `appendingPathComponent` 결합. base 끝 슬래시 하나와 조각 앞 슬래시 하나만 뗀다(Foundation 실측).
    ///
    /// `appending(component:)` 는 조각의 `/` 를 `%2F` 로 인코딩하므로 앞 슬래시를 떼지 않는다.
    public static func slashJoined(_ base: [HTTPURLPart], _ component: [HTTPURLPart], trimsComponentSlash: Bool = true) -> [HTTPURLPart] {
        var head = base
        if case let .literal(text)? = head.last {
            head[head.count - 1] = .literal(HTTPFoundationPath.joinTrimmingOneSlash(base: text, component: "").base)
        }
        var tail = component
        if trimsComponentSlash, case let .literal(text)? = tail.first {
            tail[0] = .literal(HTTPFoundationPath.joinTrimmingOneSlash(base: "", component: text).component)
        }
        return head + [.literal("/")] + tail
    }

    /// `path` 멤버 하나가 값 하나뿐이면 그 값은 `/` 를 담을 수 있는 경로 전체다.
    private static func pathMember(_ path: [HTTPURLPart]) -> [HTTPURLPart] {
        path.count == 1 && path[0] == .value ? [.pathValue] : path
    }

    /// `URL(string: path, relativeTo: base)`. base 가 전체 URL 리터럴이면 RFC 3986 병합으로 root 를 확정한다.
    private static func relative(_ path: [HTTPURLPart], to base: HTTPTargetURL?) -> HTTPRouteResolution {
        let merged = HTTPRouteURLResolver.mergedLiterals(path)
        if let base, case let .literal(head)? = merged.first, let prefix = rfc3986Prefix(base: base, path: head) {
            return HTTPRouteURLResolver.resolve([.literal(prefix)] + merged, join: .absoluteURL) ?? .init(template: nil, pathAnchor: .base)
        }
        return HTTPRouteURLResolver.resolve(merged, join: .rfc3986) ?? .init(template: nil, pathAnchor: .base)
    }

    /// RFC 3986 병합(5.2.2·5.2.3)에서 상대 경로 앞에 붙는 문자열. base 가 리터럴 전체 URL 일 때만 있다.
    ///
    /// `/x` 는 origin 뒤에, `x` 는 base 경로의 마지막 `/` 까지 뒤에 붙는다. `URL(string: "items",
    /// relativeTo: URL(string: "https://h/v1/"))` → `/v1/items`, base 가 `https://h/v1` 이면 `/items` 다
    /// (macOS 26.7 실측). query·fragment 로 시작하는 참조는 base 경로를 그대로 쓰는 다른 규칙이라 nil 이다.
    public static func rfc3986Prefix(base: HTTPTargetURL, path: String) -> String? {
        guard !path.hasPrefix("?"), !path.hasPrefix("#"), let absolute = literalAbsolute(base) else { return nil }
        if path.hasPrefix("/") { return absolute.origin }
        let directory = absolute.path.lastIndex(of: "/").map { String(absolute.path[...$0]) } ?? "/"
        return absolute.origin + directory
    }

    /// 조각이 리터럴 하나뿐인 전체 URL 이면 (scheme://host, 경로). 경로의 query·fragment 는 뗀다.
    private static func literalAbsolute(_ url: HTTPTargetURL) -> (origin: String, path: String)? {
        guard url.join == .absoluteURL, case let .literal(text)? = HTTPRouteURLResolver.mergedLiterals(url.parts).first,
              url.parts.allSatisfy({ if case .literal = $0 { true } else { false } }),
              let schemeEnd = HTTPRouteTemplate.schemeLength(text) else { return nil }
        let rest = text.dropFirst(schemeEnd)
        let pathStart = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        let tail = rest[pathStart...]
        let pathEnd = tail.firstIndex { "?#".contains($0) } ?? tail.endIndex
        return (String(text.prefix(schemeEnd)) + String(rest[..<pathStart]), String(tail[..<pathEnd]))
    }
}
