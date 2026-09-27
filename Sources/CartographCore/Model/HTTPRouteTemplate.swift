/// http 교환 계약(`../isthmus/docs/GRAPH-EXCHANGE.md`의 HTTP 경계 절)의 정규 경로 템플릿 규칙.
///
/// 정규화는 생산자 책임이고 isthmus 는 문법만 검증한다. 소비자는 위반한 템플릿을 다시
/// 정규화하지 않고 문서를 거부하므로, `%2f` 와 `%2F` 처럼 생산자마다 다르게 쓰면 조용히
/// 조인되지 않는 대신 문서 전체가 입력 오류가 된다. 그래서 이 타입은 공유 적합성 벡터
/// (`conformance/http-template.json`)의 참조 구현을 글자 그대로 옮긴다.
public enum HTTPRouteTemplate {
    /// 템플릿과 dynamic 원문의 최대 UTF-16 길이. 소비자 파서와 같은 상한이다.
    public static let maxLength = 2_048

    /// 계약의 HTTP 동사. `ANY` 는 route-decl 전용이라 호출 측에는 없다.
    public static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "TRACE"]

    /// 템플릿을 거부한 이유. 소비자 오류 문구와 벡터의 `expect.reason` 이 같은 어휘다.
    public enum Rejection: String, Sendable, CaseIterable {
        case notRooted = "not-rooted"
        case tooLong = "too-long"
        case invalidCharacter = "invalid-character"
        case malformedPercent = "malformed-percent"
        case lowercasePercentHex = "lowercase-percent-hex"
        case encodedUnreserved = "encoded-unreserved"
        case strayBrace = "stray-brace"
        case multipleParameters = "multiple-parameters"
        case catchAllPartial = "catch-all-partial"
        case catchAllNotLast = "catch-all-not-last"
    }

    /// 템플릿이 정규 문법을 따르면 nil, 아니면 거부 사유.
    ///
    /// 생산자가 스스로 검증하는 이유는 하나다. 소비자가 거부하면 문서의 다른 사실까지
    /// 모두 버려지므로, 내보내기 전에 한 사실의 결함을 찾는 편이 싸다.
    public static func validate(_ template: String) -> Rejection? {
        if template.utf16.count > maxLength { return .tooLong }
        guard template.hasPrefix("/") else { return .notRooted }
        let segments = template.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        for (index, segment) in segments.enumerated() {
            if segment == "{**}" {
                if index != segments.count - 1 { return .catchAllNotLast }
                continue
            }
            if let problem = segmentProblem(Array(segment.unicodeScalars)) { return problem }
        }
        return nil
    }

    /// 경로 리터럴을 정규 템플릿 표기로 바꾼다.
    ///
    /// 대문자 hex, unreserved 디코드, 그 밖의 문자는 UTF-8 퍼센트 인코딩이다. 리터럴 중괄호도
    /// 인코딩된다(`%7B`). `holes` 면 NUL 을 `{}` 로 되돌린다 — 조립 중 보간 자리 표시다.
    public static func normalize(_ text: String, holes: Bool = false) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = ""
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if holes, scalar == "\0" {
                output += "{}"
            } else if scalar == "%", let byte = hexByte(scalars, at: index + 1) {
                output += decodedOrEncoded(byte)
                index += 2
            } else if isLiteral(scalar) || scalar == "/" {
                output.unicodeScalars.append(scalar)
            } else {
                output += percentEncoded(scalar)
            }
            index += 1
        }
        return output
    }

    /// 고엔트로피 세그먼트와 알려진 웹훅 host 의 경로 세그먼트를 `{}` 로 가린다.
    ///
    /// 디코드한 리터럴 세그먼트가 16자(UTF-16) 이상이고 ASCII 글자와 숫자를 모두 담으면 가린다.
    /// `hooks.slack.com` 은 모든 세그먼트, `discord.com`·`discordapp.com` 은 `/api/webhooks` 뒤를
    /// 가린다. 토큰이 문서·로그로 새지 않게 하려는 것이며, 가린 호출은 isthmus 에서 error 근거가
    /// 되지 않으므로 더 가리는 쪽이 안전하다.
    public static func mask(_ template: String, authority: String?) -> (template: String, maskedSegments: Int) {
        let segments = template.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let webhookStart = webhookMaskStart(authority: authority, segments: segments)
        var masked = 0
        let result = segments.enumerated().map { index, segment -> String in
            guard !segment.contains("{") else { return segment }
            guard index >= webhookStart || isHighEntropy(segment) else { return segment }
            masked += 1
            return "{}"
        }
        return ("/" + result.joined(separator: "/"), masked)
    }

    /// `scheme://` 의 UTF-8 길이. scheme 이 없으면 nil. scheme 은 ASCII 라 글자 수와 같다.
    static func schemeLength(_ text: String) -> Int? {
        let scalars = Array(text.unicodeScalars.prefix(64))
        guard let first = scalars.first, isASCIILetter(first) else { return nil }
        var index = 1
        while index < scalars.count, isSchemeScalar(scalars[index]) { index += 1 }
        guard index + 2 < scalars.count, scalars[index] == ":", scalars[index + 1] == "/", scalars[index + 2] == "/" else { return nil }
        return index + 3
    }

    private static func isSchemeScalar(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || ("0"..."9").contains(scalar) || "+.-".unicodeScalars.contains(scalar)
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
    }

    // MARK: - 세부 규칙

    /// RFC 3986 unreserved 문자. 템플릿에서는 인코딩하지 않는다.
    static func isUnreserved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "-", ".", "_", "~": true
        default: false
        }
    }

    /// 인코딩 없이 쓸 수 있는 pchar 리터럴 문자(unreserved·sub-delims·`:`·`@`).
    static func isLiteral(_ scalar: Unicode.Scalar) -> Bool {
        isUnreserved(scalar) || "!$&'()*+,;=:@".unicodeScalars.contains(scalar)
    }

    /// 세그먼트 하나의 문법 문제. `{}` 는 세그먼트당 하나, 그 밖의 중괄호는 인코딩해야 한다.
    private static func segmentProblem(_ scalars: [Unicode.Scalar]) -> Rejection? {
        var sawParameter = false
        var index = 0
        while index < scalars.count {
            switch scalars[index] {
            case "{":
                if scalars[index...].starts(with: "{**}".unicodeScalars) { return .catchAllPartial }
                guard index + 1 < scalars.count, scalars[index + 1] == "}" else { return .strayBrace }
                if sawParameter { return .multipleParameters }
                sawParameter = true
                index += 1
            case "}": return .strayBrace
            case "%":
                if let problem = percentProblem(scalars, at: index) { return problem }
                index += 2
            case let scalar where !isLiteral(scalar): return .invalidCharacter
            default: break
            }
            index += 1
        }
        return nil
    }

    /// `%XX` 하나가 정규형인지. 대문자 hex 이고 unreserved 문자를 인코딩하지 않아야 한다.
    private static func percentProblem(_ scalars: [Unicode.Scalar], at index: Int) -> Rejection? {
        guard let byte = hexByte(scalars, at: index + 1) else { return .malformedPercent }
        let digits = String(String.UnicodeScalarView(scalars[(index + 1)...(index + 2)]))
        if digits != digits.uppercased() { return .lowercasePercentHex }
        return isUnreserved(Unicode.Scalar(byte)) ? .encodedUnreserved : nil
    }

    /// `index` 부터 두 글자가 hex 면 그 바이트.
    private static func hexByte(_ scalars: [Unicode.Scalar], at index: Int) -> UInt8? {
        guard index + 1 < scalars.count,
              let high = hexValue(scalars[index]), let low = hexValue(scalars[index + 1]) else { return nil }
        return high << 4 | low
    }

    private static func hexValue(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "0"..."9": UInt8(scalar.value - 48)
        case "A"..."F": UInt8(scalar.value - 55)
        case "a"..."f": UInt8(scalar.value - 87)
        default: nil
        }
    }

    /// 이미 인코딩된 바이트는 unreserved 면 디코드하고, 아니면 대문자 hex 로 다시 쓴다.
    private static func decodedOrEncoded(_ byte: UInt8) -> String {
        let scalar = Unicode.Scalar(byte)
        return isUnreserved(scalar) ? String(Character(scalar)) : "%" + hex(byte)
    }

    private static func percentEncoded(_ scalar: Unicode.Scalar) -> String {
        String(Character(scalar)).utf8.map { "%" + hex($0) }.joined()
    }

    private static func hex(_ byte: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }

    /// 웹훅 host 의 경로 세그먼트를 가리기 시작하는 위치. 해당하지 않으면 `Int.max`.
    private static func webhookMaskStart(authority: String?, segments: [String]) -> Int {
        if authority == "hooks.slack.com" { return 0 }
        let isDiscord = authority == "discord.com" || authority == "discordapp.com"
        guard isDiscord, segments.count >= 2, segments[0] == "api", segments[1] == "webhooks" else { return .max }
        return 2
    }

    /// 퍼센트 디코드한 세그먼트가 16자 이상이고 ASCII 글자와 숫자를 모두 담는지.
    static func isHighEntropy(_ segment: String) -> Bool {
        let decoded = percentDecoded(segment)
        guard decoded.utf16.count >= 16 else { return false }
        let scalars = decoded.unicodeScalars
        return scalars.contains { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }
            && scalars.contains { ("0"..."9").contains($0) }
    }

    /// `%XX` 를 UTF-8 로 디코드한다. 잘못된 UTF-8 이면 원문을 그대로 쓴다.
    private static func percentDecoded(_ segment: String) -> String {
        let scalars = Array(segment.unicodeScalars)
        var bytes: [UInt8] = []
        var index = 0
        while index < scalars.count {
            if scalars[index] == "%", let byte = hexByte(scalars, at: index + 1) {
                bytes.append(byte)
                index += 3
            } else {
                bytes.append(contentsOf: String(Character(scalars[index])).utf8)
                index += 1
            }
        }
        return strictUTF8(bytes) ?? segment
    }

    /// 바이트가 올바른 UTF-8 일 때만 문자열로 만든다. 대체 문자로 조용히 바꾸면 길이가 달라진다.
    private static func strictUTF8(_ bytes: [UInt8]) -> String? {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        var scalars = String.UnicodeScalarView()
        while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar): scalars.append(scalar)
            case .emptyInput: return String(scalars)
            case .error: return nil
            }
        }
    }
}
