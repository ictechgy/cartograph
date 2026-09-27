import Foundation

/// `impact --format language-traversal --roots-from <file|->` 가 읽는 root 목록.
///
/// isthmus capture 는 route-call·relation-use 를 감싼 선언을 수천 개씩 root 로 넘긴다. 인자로 넘기면 argv 상한에
/// 걸려 실행을 나눠야 하고, 나눈 만큼 문서가 늘어 trace 입력 상한에 가까워진다. 그래서 자매 저장소 kartograph 의
/// `--roots-from` 과 같은 입력을 받는다 — JSON 문자열 배열이거나 bridge-facts 문서(사실의 `symbol.usr` 를 문서
/// 순서대로 쓴다). 거기에 손으로 쓰기 쉬운 줄 형식을 더했다: 한 줄에 root 하나, 빈 줄과 `#` 으로 시작하는 줄은 건너뛴다.
/// USR 은 `[`·`{` 로 시작하지 않으므로 첫 글자로 형식을 가를 때 모호함이 없다.
///
/// 이 타입은 형식만 푼다. 제어 문자·빈 root·개수 상한은 위치 인자 root 와 합친 뒤 한 번에 검사한다 — 같은 root 가
/// 어느 쪽으로 들어왔든 같은 규칙을 받게 하기 위해서다.
public enum TraversalRootList {
    /// 입력 크기 상한. kartograph 와 같은 16 MiB 다. USR 1만 개(root 상한)는 이 크기의 작은 일부다.
    public static let maximumByteCount = 16 * 1024 * 1024

    /// 푼 root 목록과, bridge-facts 에서 `symbol.usr` 가 없어 root 로 쓰지 못한 사실 수.
    public struct Parsed: Equatable, Sendable {
        /// 입력 순서를 지키고 같은 문자열을 한 번만 담은 root 목록.
        public let roots: [String]
        /// `symbol.usr` 가 없어 건너뛴 사실 수. 한정 이름만 있는 사실은 인덱스 USR 과 바이트가 같다고 보장할 수 없다.
        public let factsWithoutUSR: Int
    }

    /// 입력을 root 목록으로 푼다. 형식이 어긋나면 원인을 담아 던진다.
    ///
    /// - Parameter data: 파일 또는 표준 입력의 바이트. UTF-8 이어야 한다.
    /// - Returns: 중복을 뺀 root 와 건너뛴 사실 수.
    /// - Throws: 크기 초과, UTF-8 아님, JSON 형식 위반이면 ``TraversalRootListError``.
    public static func parse(_ data: Data) throws -> Parsed {
        guard data.count <= maximumByteCount else { throw TraversalRootListError.tooLarge }
        guard var text = String(data: data, encoding: .utf8) else { throw TraversalRootListError.notUTF8 }
        // BOM 은 JSON 파서가 받지 않으므로 떼고 나서 형식을 가르고 푼다.
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        switch text.unicodeScalars.first(where: { !isJSONWhitespace($0) }) {
        case "[": return Parsed(roots: unique(try jsonArray(Data(text.utf8))), factsWithoutUSR: 0)
        case "{": return try bridgeFacts(Data(text.utf8))
        default: return Parsed(roots: unique(lines(text)), factsWithoutUSR: 0)
        }
    }

    /// 줄 형식: LF 또는 CRLF 로 줄을 나누고 앞뒤 공백을 떼고, 빈 줄과 `#` 주석 줄을 건너뛴다.
    ///
    /// Swift 는 CRLF 를 문자 하나(`"\r\n"`)로 보므로 LF 와 CRLF 를 둘 다 구분자로 준다. 공백(U+0020)만 뗀다.
    /// 탭·홀로 선 CR 같은 제어 문자는 떼지 않고 남겨 두어 뒤의 제어 문자 검사가 거부하게 한다 — isthmus 는
    /// 제어 문자가 든 id 를 통째로 거부하므로 조용히 고쳐 쓰면 입력과 다른 root 를 분석하게 된다.
    static func lines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).compactMap { raw in
            var line = raw
            while line.first == " " { line.removeFirst() }
            while line.last == " " { line.removeLast() }
            let value = String(line)
            return value.isEmpty || value.hasPrefix("#") ? nil : value
        }
    }

    /// JSON 문자열 배열. 문자열이 아닌 원소가 하나라도 있으면 거부한다.
    private static func jsonArray(_ data: Data) throws -> [String] {
        guard let values = try json(data) as? [Any] else {
            throw TraversalRootListError.invalidJSON("it is not a JSON array")
        }
        return try values.map { value in
            guard let text = value as? String else {
                throw TraversalRootListError.invalidJSON("a JSON root list must hold only strings")
            }
            return text
        }
    }

    /// bridge-facts 문서. 사실의 `symbol.usr` 를 문서 순서대로 모은다. usr 가 없는 사실은 세기만 한다.
    private static func bridgeFacts(_ data: Data) throws -> Parsed {
        guard let document = try json(data) as? [String: Any],
              document["format"] as? String == "bridge-facts" else {
            throw TraversalRootListError.invalidJSON("a JSON object must be a bridge-facts document")
        }
        guard let facts = document["facts"] as? [Any] else {
            throw TraversalRootListError.invalidJSON("the bridge-facts document has no facts array")
        }
        let usrs = facts.map { (($0 as? [String: Any])?["symbol"] as? [String: Any])?["usr"] as? String }
        return Parsed(roots: unique(usrs.compactMap { $0 }), factsWithoutUSR: usrs.filter { $0 == nil }.count)
    }

    /// JSON 을 푼다. 문법 오류는 모양 오류와 다른 문구로 알린다 — `[` 로 시작했는데 "배열이 아니다" 라고 하면
    /// 잘린 파일을 고치려던 사용자가 형식을 바꿔야 한다고 오해한다.
    private static func json(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TraversalRootListError.invalidJSON("it starts like JSON but is not valid JSON (truncated or malformed)")
        }
    }

    /// 입력 순서를 지키며 같은 문자열을 한 번만 남긴다.
    public static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// JSON 이 허용하는 공백(RFC 8259: 공백·탭·LF·CR)인지.
    private static func isJSONWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }
}

/// `--roots-from` 입력이 형식을 어겼다. 인자의 문제이므로 CLI 는 사용 오류(64)로 바꾼다.
public enum TraversalRootListError: Error, Equatable, CustomStringConvertible {
    /// 16 MiB 를 넘는다.
    case tooLarge
    /// UTF-8 이 아니다.
    case notUTF8
    /// `[`·`{` 로 시작했지만 약속한 JSON 모양이 아니다.
    case invalidJSON(String)

    /// 원인과 받는 형식을 함께 말한다. 입력 원문은 싣지 않는다.
    public var description: String {
        let accepted = "use one root per line (# comments), a JSON string array, or a bridge-facts document"
        switch self {
        case .tooLarge: return "the root list exceeds 16 MiB; split the roots across runs"
        case .notUTF8: return "the root list is not UTF-8 text; \(accepted)"
        case let .invalidJSON(reason): return "\(reason); \(accepted)"
        }
    }
}
