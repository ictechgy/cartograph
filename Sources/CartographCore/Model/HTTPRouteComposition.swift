/// 호출 측 URL 식을 이루는 조각 하나. 구문 스캐너가 문자열 리터럴·보간·연결을 이 조각으로 펼친다.
///
/// 언어마다 식의 모양은 다르지만 조립 규칙(`../isthmus/docs/HTTP-WRAPPERS.md`)은 같아야
/// 같은 API 를 부르는 iOS·Android 호출이 같은 키로 조인된다. 그래서 규칙은 구문이 아니라
/// 이 조각 목록 위에서 정의한다.
public enum HTTPURLPart: Hashable, Sendable {
    /// 실행 시에도 그대로인 문자열. 퍼센트 인코딩 전의 원문이다.
    case literal(String)
    /// 정적으로 알 수 없는 값(보간·변수·호출 결과).
    case value
    /// 값은 모르지만 query 꼬리임을 증명한 지역 변수(`compose.suffix`).
    case queryTail
}

/// base URL 과 경로를 결합하는 방식. 결합 방식마다 경로가 root 에서 확정되는지가 다르다.
public enum HTTPPathJoin: Hashable, Sendable {
    /// RFC 3986 상대 해석(`URL(string:relativeTo:)`). `/x` 는 root, `x` 는 base 뒤다.
    case rfc3986
    /// 슬래시 결합(`appendingPathComponent`). 경로는 언제나 base 뒤다.
    case slashJoin
    /// base 없는 전체 URL(`URL(string:)`). host 가 없는 문자열은 요청 URL 이 아니다.
    case absoluteURL
    /// 사용자가 선언한 래퍼. 앵커는 선언(`http-wrappers` v1 의 `pathAnchor`)을 따른다.
    case wrapper(HTTPPathAnchor)
}

/// 경로가 서버 루트부터 확정됐는지(`root`), 알 수 없는 base 뒤에 붙는지(`base`).
public enum HTTPPathAnchor: String, Hashable, Sendable, Codable {
    case root
    case base
}

/// 조각 목록을 조립한 결과. 정적 템플릿이거나, 증명된 접두사만 아는 dynamic 이다.
public struct HTTPRouteResolution: Hashable, Sendable {
    /// dynamic 이 아니면 정규 템플릿.
    public let template: String?
    /// dynamic 이면 문제 되는 첫 보간 앞까지의 정규 템플릿. `/` 로 시작할 때만 있다.
    public let channelPrefix: String?
    public let pathAnchor: HTTPPathAnchor
    /// 리터럴 host. userinfo 를 떼고 소문자로 쓴다.
    public let authority: String?
    public let queryTailStripped: Bool
    /// 가린 세그먼트 수. 없으면 0.
    public let maskedSegments: Int
    /// 호출 측 한계 접두사(`ambiguous-base-join:`)를 내야 하는 결합이면 그 접두사.
    public let limitation: String?

    public var isDynamic: Bool { template == nil }

    public init(
        template: String?, channelPrefix: String? = nil, pathAnchor: HTTPPathAnchor,
        authority: String? = nil, queryTailStripped: Bool = false, maskedSegments: Int = 0,
        limitation: String? = nil
    ) {
        self.template = template
        self.channelPrefix = channelPrefix
        self.pathAnchor = pathAnchor
        self.authority = authority
        self.queryTailStripped = queryTailStripped
        self.maskedSegments = maskedSegments
        self.limitation = limitation
    }
}

/// 공통 해석 규칙(`compose.*`)의 구현. 공유 적합성 벡터(`conformance/url-compose.json`)가 정본이다.
public enum HTTPRouteComposer {
    /// 경로 조립 결과. 앵커·host 는 호출자가 정한다.
    public enum PathOutcome: Hashable, Sendable {
        case template(String, queryTailStripped: Bool)
        case dynamic(channelPrefix: String?)
    }

    /// 조각 목록을 경로 템플릿으로 조립한다(`compose.query-tail`·`suffix`·`interpolation`·`normalize`).
    ///
    /// 1) 리터럴의 첫 `?`·`#` 에서 끊고 뒤(보간 포함)를 버린다. 2) 끝의 증명된 query 꼬리를 뗀다.
    /// 3) 값은 앞이 `/` 로 끝나고 뒤가 `/` 로 시작하거나 끝일 때만 `{}` 다. 그 밖은 dynamic 이며,
    /// 앞선 조립 결과가 `/` 로 시작하면 그것이 `channelPrefix` 다. 호출 쪽 부분 보간은 값 경계를
    /// 증명할 수 없어 서버 템플릿의 부분 세그먼트와 달리 dynamic 이다.
    public static func compose(_ parts: [HTTPURLPart]) -> PathOutcome {
        var (kept, stripped) = cutQueryTail(parts)
        while kept.last == .queryTail {
            kept.removeLast()
            stripped = true
        }
        var text = ""
        for (index, part) in kept.enumerated() {
            if case let .literal(literal) = part {
                // NUL 은 조립 중 보간 자리 표시다. 리터럴의 NUL 은 인코딩해 구멍과 섞이지 않게 한다.
                text += literal.replacingNUL()
                continue
            }
            guard part == .value, text.hasSuffix("/"), startsSegmentOrEnds(kept, after: index) else {
                return .dynamic(channelPrefix: text.hasPrefix("/") ? HTTPRouteTemplate.normalize(text, holes: true) : nil)
            }
            text += "\0"
        }
        guard text.hasPrefix("/") else { return .dynamic(channelPrefix: nil) }
        return .template(HTTPRouteTemplate.normalize(text, holes: true), queryTailStripped: stripped)
    }

    /// 전체 URL 에서 scheme·userinfo·query·fragment 를 떼고 소문자 host 와 경로를 얻는다(`compose.strip`).
    public static func strip(url: String) -> (template: String, authority: String, queryTailStripped: Bool)? {
        guard let schemeEnd = HTTPRouteTemplate.schemeLength(url) else { return nil }
        let rest = url.dropFirst(schemeEnd)
        let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        let authority = normalizedAuthority(String(rest[..<authorityEnd]))
        let tail = rest[authorityEnd...]
        let pathEnd = tail.firstIndex { "?#".contains($0) } ?? tail.endIndex
        let path = tail[..<pathEnd].isEmpty ? "/" : String(tail[..<pathEnd])
        return (HTTPRouteTemplate.normalize(path), authority, pathEnd != tail.endIndex)
    }

    /// base + path 결합의 네 갈래(`compose.base-join`). Swift 에는 dio 가 없지만 규칙은 공유한다.
    ///
    /// - `rfc3986`: `/x` 는 root, `x` 는 base. - `slashJoin`: 둘 다 base.
    /// - 단순 문자열 연결: base 가 리터럴이면 연결 결과의 경로(root), 미상이면 `/x` 만 base 이고
    ///   `x` 는 dynamic + `ambiguous-base-join:` 이다.
    public static func baseJoin(_ join: BaseJoinKind, base: String?, path: String) -> HTTPRouteResolution {
        let relative = HTTPRouteTemplate.normalize("/" + path.drop { $0 == "/" })
        let rooted = path.hasPrefix("/")
        switch join {
        case .rfc3986:
            return rooted ? .init(template: HTTPRouteTemplate.normalize(path), pathAnchor: .root)
                : .init(template: relative, pathAnchor: .base)
        case .slashJoin:
            return .init(template: relative, pathAnchor: .base)
        case .concatenation:
            if let base, let stripped = strip(url: base + path) {
                return .init(template: stripped.template, pathAnchor: .root)
            }
            return rooted ? .init(template: HTTPRouteTemplate.normalize(path), pathAnchor: .base)
                : .init(template: nil, pathAnchor: .base, limitation: ambiguousBaseJoin)
        }
    }

    /// `baseJoin` 이 다루는 결합 방식.
    public enum BaseJoinKind: String, Sendable {
        case rfc3986
        case slashJoin = "slash-join"
        case concatenation = "dio-concat"
    }

    /// 앞에 알 수 없는 base 가 붙은 상대 경로의 한계 접두사.
    public static let ambiguousBaseJoin = "ambiguous-base-join:"

    // MARK: - 세부 규칙

    /// 첫 `?`·`#` 을 담은 리터럴에서 끊는다. 끊었으면 그 뒤의 조각을 모두 버린다.
    private static func cutQueryTail(_ parts: [HTTPURLPart]) -> ([HTTPURLPart], Bool) {
        var kept: [HTTPURLPart] = []
        for part in parts {
            guard case let .literal(literal) = part, let cut = literal.firstIndex(where: { "?#".contains($0) }) else {
                kept.append(part)
                continue
            }
            if cut > literal.startIndex { kept.append(.literal(String(literal[..<cut]))) }
            return (kept, true)
        }
        return (kept, false)
    }

    /// 값 뒤가 경로 끝이거나 `/` 로 시작하는 리터럴인지.
    private static func startsSegmentOrEnds(_ parts: [HTTPURLPart], after index: Int) -> Bool {
        guard index + 1 < parts.count else { return true }
        if case let .literal(next) = parts[index + 1] { return next.hasPrefix("/") }
        return false
    }

    /// userinfo 를 마지막 `@` 까지 떼고 소문자로 바꾼다. 비밀이 담길 수 있는 앞쪽을 남기지 않는다.
    static func normalizedAuthority(_ raw: String) -> String {
        let host = raw.lastIndex(of: "@").map { raw[raw.index(after: $0)...] } ?? raw[...]
        return host.lowercased()
    }
}

/// 결합 방식과 조각 목록에서 route-call 의 템플릿·앵커·host 를 정한다.
///
/// 전체 URL 이면 host 뒤 경로가 root 이고, host 에 값이 섞이면 base 다. 맨 앞이 값이면 그것은
/// 알 수 없는 base 식이므로 단순 문자열 연결 규칙을 쓴다(`interpolation/leading-value-is-base`).
/// 그 밖은 결합 방식이 앵커를 정한다. 결과 템플릿과 접두사에는 마스킹을 적용한다.
public enum HTTPRouteURLResolver {
    /// 요청 URL 로 읽을 수 없으면(예: host 없는 문자열을 base 없이 씀) nil.
    public static func resolve(_ parts: [HTTPURLPart], join: HTTPPathJoin) -> HTTPRouteResolution? {
        let merged = mergedLiterals(parts)
        guard let first = merged.first else { return nil }
        guard case let .literal(head) = first else { return masked(leadingValue(merged)) }
        if let schemeEnd = HTTPRouteTemplate.schemeLength(head) {
            return masked(absolute(merged, head: head, schemeEnd: schemeEnd))
        }
        return relative(merged, head: head, join: join).map(masked)
    }

    /// 이웃한 리터럴을 하나로 합친다. `"https://" + host` 처럼 나뉜 리터럴도 같은 규칙을 받는다.
    static func mergedLiterals(_ parts: [HTTPURLPart]) -> [HTTPURLPart] {
        parts.reduce(into: []) { result, part in
            if case let .literal(next) = part, case let .literal(previous)? = result.last {
                result[result.count - 1] = .literal(previous + next)
            } else {
                result.append(part)
            }
        }
    }

    /// `scheme://host/path` — host 가 리터럴이면 root 와 authority, 값이 섞이면 base 다.
    private static func absolute(_ parts: [HTTPURLPart], head: String, schemeEnd: Int) -> HTTPRouteResolution {
        let afterScheme = String(head.dropFirst(schemeEnd))
        guard let cut = afterScheme.firstIndex(where: { "/?#".contains($0) }) else {
            guard parts.count == 1 else { return dynamicHost(Array(parts.dropFirst())) }
            return .init(template: "/", pathAnchor: .root, authority: validAuthority(afterScheme))
        }
        let authority = validAuthority(String(afterScheme[..<cut]))
        let rest = [HTTPURLPart.literal(String(afterScheme[cut...]))] + parts.dropFirst()
        return rooted(rest, anchor: .root, authority: authority)
    }

    /// host 자리에 값이 있는 URL. host 뒤 첫 `/` 부터가 base 뒤 경로다.
    private static func dynamicHost(_ parts: [HTTPURLPart]) -> HTTPRouteResolution {
        let rest = Array(parts.drop { !isLiteral($0) })
        guard case let .literal(text)? = rest.first,
              let cut = text.firstIndex(where: { "/?#".contains($0) }) else {
            return .init(template: nil, pathAnchor: .base)
        }
        return rooted([.literal(String(text[cut...]))] + rest.dropFirst(), anchor: .base, authority: nil)
    }

    /// 맨 앞이 값인 식. 단순 문자열 연결로 보고 `/` 로 시작하는 나머지만 base 뒤 경로로 쓴다.
    private static func leadingValue(_ parts: [HTTPURLPart]) -> HTTPRouteResolution {
        let rest = Array(parts.drop { !isLiteral($0) })
        guard case let .literal(text)? = rest.first else { return .init(template: nil, pathAnchor: .base) }
        if text.hasPrefix("/") { return rooted(rest, anchor: .base, authority: nil) }
        if text.hasPrefix("?") || text.hasPrefix("#") { return .init(template: nil, pathAnchor: .base) }
        return .init(template: nil, pathAnchor: .base, limitation: HTTPRouteComposer.ambiguousBaseJoin)
    }

    /// host 없이 리터럴로 시작하는 경로. 결합 방식이 앵커를 정한다.
    private static func relative(_ parts: [HTTPURLPart], head: String, join: HTTPPathJoin) -> HTTPRouteResolution? {
        let isRooted = head.hasPrefix("/")
        let anchor: HTTPPathAnchor
        switch join {
        case .absoluteURL: return nil
        case .rfc3986: anchor = isRooted ? .root : .base
        case .slashJoin: anchor = .base
        case let .wrapper(declared): anchor = declared
        }
        // 슬래시 결합은 앞의 슬래시를 모두 떼고 하나만 붙인다. 나머지는 없을 때만 하나 붙인다.
        let path = join == .slashJoin ? "/" + head.drop { $0 == "/" } : (isRooted ? head : "/" + head)
        return rooted([.literal(path)] + parts.dropFirst(), anchor: anchor, authority: nil)
    }

    /// `/` 로 시작하는 조각 목록을 조립한다. query·fragment 로 바로 시작하면 루트 경로다.
    private static func rooted(_ parts: [HTTPURLPart], anchor: HTTPPathAnchor, authority: String?) -> HTTPRouteResolution {
        if case let .literal(text)? = parts.first, text.hasPrefix("?") || text.hasPrefix("#") {
            return .init(template: "/", pathAnchor: anchor, authority: authority, queryTailStripped: true)
        }
        switch HTTPRouteComposer.compose(parts) {
        case let .template(template, stripped):
            return .init(template: template, pathAnchor: anchor, authority: authority, queryTailStripped: stripped)
        case let .dynamic(prefix):
            return .init(template: nil, channelPrefix: prefix, pathAnchor: anchor, authority: authority)
        }
    }

    /// 템플릿이나 접두사의 리터럴 세그먼트를 가린다. 가린 수는 어느 쪽이든 같은 필드에 싣는다.
    private static func masked(_ resolution: HTTPRouteResolution) -> HTTPRouteResolution {
        guard let text = resolution.template ?? resolution.channelPrefix else { return resolution }
        let (maskedText, count) = HTTPRouteTemplate.mask(text, authority: resolution.authority)
        return .init(
            template: resolution.template == nil ? nil : maskedText,
            channelPrefix: resolution.template == nil ? maskedText : nil,
            pathAnchor: resolution.pathAnchor, authority: resolution.authority,
            queryTailStripped: resolution.queryTailStripped, maskedSegments: count,
            limitation: resolution.limitation
        )
    }

    /// 소비자가 받는 `host[:port]` 형식일 때만 host 를 싣는다. 형식을 벗어나면 문서 전체가 거부된다.
    static func validAuthority(_ raw: String) -> String? {
        let authority = HTTPRouteComposer.normalizedAuthority(raw)
        var host = Substring(authority)
        if let colon = authority.lastIndex(of: ":"), !authority.hasSuffix("]") {
            let port = authority[authority.index(after: colon)...]
            guard (1...5).contains(port.count), port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber) else { return nil }
            host = authority[..<colon]
        }
        return isValidHost(host) ? authority : nil
    }

    /// DNS 이름(라벨이 영숫자로 시작하고 끝남) 또는 `[IPv6]`.
    private static func isValidHost(_ host: Substring) -> Bool {
        if host.hasPrefix("[") {
            return host.hasSuffix("]") && host.count > 2
                && host.dropFirst().dropLast().allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return !host.isEmpty && labels.allSatisfy { label in
            guard let first = label.first, let last = label.last else { return false }
            let allowed = label.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
            return allowed && first != "-" && last != "-"
        }
    }

    private static func isLiteral(_ part: HTTPURLPart) -> Bool {
        if case .literal = part { return true }
        return false
    }
}

private extension String {
    /// NUL 을 `%00` 으로 바꾼다. 정규화는 이미 인코딩된 비 unreserved 바이트를 그대로 둔다.
    func replacingNUL() -> String {
        guard unicodeScalars.contains("\0") else { return self }
        return unicodeScalars.map { $0 == "\0" ? "%00" : String(Character($0)) }.joined()
    }
}
