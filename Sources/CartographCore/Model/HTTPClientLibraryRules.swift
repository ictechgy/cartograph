/// Swift HTTP 라이브러리(Foundation·Alamofire·Moya)가 경로와 동사를 만드는 방식.
///
/// 규칙은 추측이 아니라 라이브러리 소스와 실제 요청으로 확인한 것이다. `appendingPathComponent` 가
/// `?`·`#`·`%` 를 인코딩한다는 사실은 macOS 26.7 Foundation 에서 로컬 HTTP 서버가 받은 요청 줄로 확인했고
/// (`experiments/http-client-oracle`), Moya 15.0.3 의 `URL(target:)` 은 빈 경로가 아니면
/// `baseURL.appendingPathComponent(path)` 를 쓴다(`Sources/Moya/URL+Moya.swift`). 규칙이 구문 스캐너에
/// 섞이면 공유 벡터·오라클이 제품 규칙을 검사할 수 없으므로 구문을 모르는 이곳에 둔다.
public enum HTTPFoundationPath {
    /// 디코드된 경로 문자열을 Foundation 이 URL 에 넣는 모양으로 인코딩한다.
    ///
    /// `appendingPathComponent`·`appending(path:)`·`URLComponents.path` 는 인자를 **디코드된** 텍스트로
    /// 받아, 경로에 쓸 수 없는 문자를 UTF-8 퍼센트 인코딩한다. 그래서 `?` 는 query 가 아니라 `%3F` 이고,
    /// 이미 인코딩된 `%20` 은 `%2520` 이 된다. `appending(component:)` 는 `/` 까지 인코딩한다(`keepsSlash`
    /// 가 거짓). 결과는 정규 템플릿 문법의 pchar 만 담으므로 `HTTPRouteTemplate.normalize` 를 거쳐도 같다.
    public static func encodeDecoded(_ text: String, keepsSlash: Bool) -> String {
        var output = ""
        for scalar in text.unicodeScalars {
            if HTTPRouteTemplate.isLiteral(scalar) || (keepsSlash && scalar == "/") {
                output.unicodeScalars.append(scalar)
            } else {
                output += String(Character(scalar)).utf8.map { "%" + hexByte($0) }.joined()
            }
        }
        return output
    }

    /// `appendingPathComponent` 의 결합 지점. base 끝 슬래시 하나와 조각 앞 슬래시 하나만 떼고 `/` 하나로 잇는다.
    ///
    /// 실측: `api` + `/users` → `api/users`, `api` + `//users` → `api//users`, `api/` + `/users` →
    /// `api/users`, `api//` + `x` → `api//x`. 슬래시를 모두 떼면 `//users` 호출이 `/users` 로 잘못 조인된다.
    public static func joinTrimmingOneSlash(base: String, component: String) -> (base: String, component: String) {
        let head = base.hasSuffix("/") ? String(base.dropLast()) : base
        let tail = component.hasPrefix("/") ? String(component.dropFirst()) : component
        return (head, tail)
    }

    private static func hexByte(_ byte: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}

/// Alamofire `HTTPMethod` 와 Moya `Method`(Alamofire `HTTPMethod` 의 별칭)의 정적 멤버를 계약 동사로 바꾼다.
///
/// Alamofire 5.12.2 `Source/Core/HTTPMethod.swift` 의 정적 멤버는 `connect`·`delete`·`get`·`head`·
/// `options`·`patch`·`post`·`put`·`query`·`trace` 이고 원시값은 대문자 이름이다. `CONNECT`·`QUERY` 는
/// 계약 동사가 아니므로 nil(`methodDynamic`)이다 — 없는 동사로 조인하면 거짓 method 불일치가 된다.
public enum HTTPLibraryMethod {
    /// 멤버 이름(`get`) → 계약 동사(`GET`). 계약 밖이거나 소문자 멤버 이름이 아니면 nil.
    ///
    /// 라이브러리 멤버는 소문자다. `GET` 같은 이름은 라이브러리 멤버가 아니라 다른 타입의 상수다.
    public static func verb(forMemberName name: String) -> String? {
        guard name == name.lowercased() else { return nil }
        let upper = name.uppercased()
        return HTTPRouteTemplate.methods.contains(upper) ? upper : nil
    }

    /// `HTTPMethod(rawValue: "POST")` 처럼 원시값 문자열로 만든 동사. 계약 동사와 정확히 같을 때만.
    public static func verb(forRawValue value: String) -> String? {
        HTTPRouteTemplate.methods.contains(value) ? value : nil
    }

    /// Alamofire `Session` 요청 메서드의 기본 동사. `upload` 만 POST 이고 나머지는 GET 이다
    /// (Alamofire 5.12.2 `Source/Core/Session.swift` 의 `method: HTTPMethod = .get` / `.post`).
    public static func alamofireDefaultVerb(forRequestMethod name: String) -> String? {
        switch name {
        case "request", "streamRequest", "download": "GET"
        case "upload": "POST"
        default: nil
        }
    }
}
