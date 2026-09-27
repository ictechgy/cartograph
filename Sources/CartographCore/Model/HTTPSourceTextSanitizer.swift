/// dynamic route-call 의 원문 식을 싣기 전에 문자열 리터럴에 든 비밀이 될 수 있는 부분을 지운다.
///
/// 계약은 제거·마스킹을 `channel` 만이 아니라 리터럴 경로를 싣는 모든 필드에 요구한다. dynamic 원문은
/// 식 전체라 URL 리터럴이 그대로 들어 있을 수 있다. 리터럴 하나씩 따로 보면 `p + "?token=" + "…"` 처럼
/// 나뉜 query 나 `"admin:" + "…" + "@"` 처럼 나뉜 userinfo 가 샌다. 그래서 식의 문자열 조각을 실행 시
/// 이어지는 하나의 흐름으로 읽는다: 첫 `?`·`#` 부터 뒤는 코드까지 모두 버리고, `://` 뒤 authority 에서
/// `@` 를 만나면 거기까지(사이의 코드 포함)를 지우며, 여러 조각에 걸친 경로 세그먼트도 이어 붙인 값으로
/// 고엔트로피·웹훅 여부를 판정한다. 더 가리는 쪽은 계약이 허용하므로 host 세그먼트도 같은 기준을 받는다.
public enum HTTPSourceTextSanitizer {
    /// 원문 식의 조각. 문자열 리터럴 조각과 그 밖의 코드를 가른다.
    public enum Piece: Hashable, Sendable {
        case code(String)
        case literal(String)
    }

    /// 흐름 상태로 조각을 읽어 가린 원문을 만든다.
    public static func sanitize(_ pieces: [Piece]) -> String {
        var stream = Stream()
        for piece in pieces {
            switch piece {
            case let .code(text): stream.appendCode(text)
            case let .literal(text): text.forEach { stream.appendLiteral($0) }
            }
        }
        return stream.rendered()
    }

    /// 출력 조각 하나. 리터럴 문자면 속한 경로 세그먼트 번호가 있다.
    private struct Output {
        var text: String
        let segment: Int?
    }

    /// 문자열 흐름을 따라가는 상태.
    private struct Stream {
        var output: [Output] = []
        /// 세그먼트 번호 → 이어 붙인 리터럴 값.
        var segments: [String] = [""]
        /// `://` 를 판정하려고 남기는 최근 리터럴 문자.
        var tail = ""
        /// authority 가 시작된 출력 위치. authority 밖이면 nil.
        var authorityStart: Int?
        /// query·fragment 를 만난 뒤인지. 그 뒤는 아무것도 싣지 않는다.
        var isDropped = false

        mutating func appendCode(_ text: String) {
            guard !isDropped else { return }
            output.append(Output(text: text, segment: nil))
        }

        mutating func appendLiteral(_ character: Character) {
            guard !isDropped else { return }
            switch character {
            case "?", "#":
                isDropped = true
            case "@" where authorityStart != nil:
                // userinfo 는 사이에 낀 코드(변수 이름)까지 지운다. host 는 그 뒤에서 다시 시작한다.
                output.removeSubrange(authorityStart!...)
                segments[segments.count - 1] = ""
                authorityStart = output.count
            case "/":
                authorityStart = nil
                segments.append("")
                output.append(Output(text: "/", segment: nil))
                noteSchemeSeparator(character)
            default:
                segments[segments.count - 1].append(character)
                appendSegmentCharacter(character)
                noteSchemeSeparator(character)
            }
        }

        private mutating func appendSegmentCharacter(_ character: Character) {
            let segment = segments.count - 1
            if let last = output.last, last.segment == segment {
                output[output.count - 1].text.append(character)
            } else {
                output.append(Output(text: String(character), segment: segment))
            }
        }

        /// 리터럴 흐름이 `://` 로 끝나면 그 뒤가 authority 다.
        private mutating func noteSchemeSeparator(_ character: Character) {
            tail = String((tail + String(character)).suffix(3))
            if tail == "://" { authorityStart = output.count }
        }

        /// 가릴 세그먼트는 첫 조각만 `{}` 로, 나머지 조각은 비워 한 세그먼트가 하나의 구멍이 되게 한다.
        func rendered() -> String {
            let masked = maskedSegments()
            var seen: Set<Int> = []
            return output.map { piece -> String in
                guard let segment = piece.segment, masked.contains(segment) else { return piece.text }
                return seen.insert(segment).inserted ? "{}" : ""
            }.joined()
        }

        private func maskedSegments() -> Set<Int> {
            let webhookStart = webhookStart()
            return Set(segments.indices.filter { index in
                (index >= webhookStart && !segments[index].isEmpty) || HTTPRouteTemplate.isHighEntropy(segments[index])
            })
        }

        /// 웹훅 host 뒤 경로가 시작하는 세그먼트. 없으면 `Int.max`.
        private func webhookStart() -> Int {
            for (index, segment) in segments.enumerated() {
                let host = segment.lowercased()
                if host == "hooks.slack.com" { return index + 1 }
                if host == "discord.com" || host == "discordapp.com", segments.count > index + 2,
                   segments[index + 1] == "api", segments[index + 2] == "webhooks" {
                    return index + 3
                }
            }
            return .max
        }
    }
}
