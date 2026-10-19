import Foundation

/// JSONDecoder가 token 신원과 중복 키를 지우기 전에 출처 범위만 검사한다.
public enum RetentionProvenanceAdmission {
    public static func parseEnvelope(_ data: Data) throws -> ExternalRetentionProvenance {
        guard String(data: data, encoding: .utf8) != nil else { throw ExternalRetentionProvenance.invalid() }
        var parser = Parser(data: data)
        let value = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.offset == data.count else { throw ExternalRetentionProvenance.invalid() }
        return try ExternalRetentionProvenance(value: value)
    }

    /// 외부 문서와 snapshot은 경로 밖 숫자의 기존 도메인을 바꾸지 않는다.
    public static func read(from data: Data, snapshot: Bool = false) throws -> ExternalRetentionProvenance? {
        guard String(data: data, encoding: .utf8) != nil else { throw ExternalRetentionProvenance.invalid() }
        var parser = Parser(data: data)
        guard snapshot else {
            return try parser.find(path: ["provenance"]).map { try parseEnvelope(data.subdata(in: $0)) }
        }
        // 새 compact 저장 필드도 키ed decoder보다 먼저 찾는다. escaped alias 중복도 거부한다.
        // 큰 snapshot을 두 번 훑지 않도록 두 표현을 한 번에 찾는다.
        let spans = try parser.findSnapshotProvenance()
        let inline = try spans.inline.map { try parseEnvelope(data.subdata(in: $0)) }
        // compact 키는 예전 두 번째 순회처럼 inline 출처 검사 뒤에 판정해 오류 문구를 바꾸지 않는다.
        // 따옴표·여는 괄호를 품은 잘못된 스칼라가 있었으면 그 순회가 token을 달리 나눴으므로 그대로 다시 한다.
        var storedSpan = spans.stored
        if parser.hasAmbiguousScalar {
            var rawParser = Parser(data: data)
            storedSpan = try rawParser.find(path: ["externalRetentionProvenanceJSON"])
        } else if spans.isStoredRepeated { throw ExternalRetentionProvenance.invalid() }
        guard let rawSpan = storedSpan else { return inline }
        let raw = try JSONDecoder().decode(String.self, from: data.subdata(in: rawSpan))
        guard raw.utf8.count <= ExternalRetentionProvenance.maximumBytes else { throw ExternalRetentionProvenance.invalid() }
        let stored = try parseEnvelope(Data(raw.utf8))
        if let inline, inline != stored { throw ExternalRetentionProvenance.invalid() }
        return inline ?? stored
    }

    private struct Parser {
        let data: Data
        var offset = 0
        var canonicalBytes = 0
        /// 디코드가 필요한 token마다 decoder를 새로 만들지 않는다. 기본 설정이라 판정과 오류 문구는 같다.
        let decoder = JSONDecoder()
        /// 건너뛴 스칼라가 따옴표나 여는 괄호를 품었다. 유효한 JSON에는 없고, 느슨한 건너뛰기와 엄격한
        /// 멤버 순회가 같은 바이트를 다른 token으로 나눌 수 있다는 표시다.
        var hasAmbiguousScalar = false
        mutating func count(_ amount: Int) throws {
            canonicalBytes += amount
            guard canonicalBytes <= ExternalRetentionProvenance.maximumBytes else { throw ExternalRetentionProvenance.invalid() }
        }
        mutating func whitespace() { while offset < data.count && [9, 10, 13, 32].contains(data[offset]) { offset += 1 } }
        mutating func consume(_ byte: UInt8) throws {
            whitespace()
            guard offset < data.count, data[offset] == byte else { throw ExternalRetentionProvenance.invalid() }
            offset += 1
        }
        mutating func string() throws -> String {
            let token = try stringToken()
            // Foundation 문자열 decoder는 잘못된 surrogate escape를 명시적으로 거부한다.
            return try decoder.decode(String.self, from: data.subdata(in: token.span))
        }

        /// 문자열 token의 범위와 escape 정보. 값이 필요 없는 자리에서 decoder를 건너뛰려고 쓴다.
        struct StringToken {
            let span: Range<Int>
            /// escape가 하나도 없어 따옴표 안 바이트가 곧 디코드한 값이다.
            let isVerbatim: Bool
            /// 바이트로 확인하지 못한 escape가 있어 JSONDecoder가 판정해야 한다.
            let needsDecoder: Bool
        }

        /// 닫는 따옴표까지 원시 제어 문자를 거부하며 이동한다. 원본 전체가 UTF-8임은 호출자가 먼저 확인한다.
        mutating func stringToken() throws -> StringToken {
            whitespace()
            let start = offset
            try consume(34)
            var isVerbatim = true
            var needsDecoder = false
            while offset < data.count {
                let byte = data[offset]
                offset += 1
                if byte == 92 {
                    guard offset < data.count else { throw ExternalRetentionProvenance.invalid() }
                    let length = escapeLength(at: offset)
                    isVerbatim = false
                    needsDecoder = needsDecoder || length == nil
                    offset += length ?? 1
                } else if byte == 34 {
                    return StringToken(span: start..<offset, isVerbatim: isVerbatim, needsDecoder: needsDecoder)
                } else if byte < 32 { throw ExternalRetentionProvenance.invalid() }
            }
            throw ExternalRetentionProvenance.invalid()
        }

        /// 백슬래시 뒤가 JSONDecoder가 받아들이는 escape면 그 길이를 돌려준다. 모르는 escape와 짝 없는
        /// surrogate는 nil이다. 그때는 decoder가 판정과 오류 문구를 맡는다.
        func escapeLength(at index: Int) -> Int? {
            switch data[index] {
            case 34, 47, 92, 98, 102, 110, 114, 116: return 1
            case 117:
                guard let unit = hexUnit(at: index + 1) else { return nil }
                guard (0xD800...0xDFFF).contains(unit) else { return 5 }
                guard unit < 0xDC00, index + 6 < data.count, data[index + 5] == 92, data[index + 6] == 117,
                      let low = hexUnit(at: index + 7), (0xDC00...0xDFFF).contains(low) else { return nil }
                return 11
            default: return nil
            }
        }

        /// `index`부터 16진수 네 자리를 읽는다. 하나라도 16진수가 아니거나 끝을 넘으면 nil이다.
        func hexUnit(at index: Int) -> Int? {
            guard index + 4 <= data.count else { return nil }
            var unit = 0
            for position in index..<index + 4 {
                let byte = data[position]
                switch byte {
                case 48...57: unit = unit << 4 | Int(byte - 48)
                case 65...70: unit = unit << 4 | Int(byte - 55)
                case 97...102: unit = unit << 4 | Int(byte - 87)
                default: return nil
                }
            }
            return unit
        }

        /// 건너뛰는 문자열은 값이 필요 없다. 바이트로 확인하지 못한 escape가 있을 때만 decoder에 맡겨
        /// 예전과 같은 판정과 오류 문구를 낸다.
        mutating func skipString() throws {
            let token = try stringToken()
            if token.needsDecoder { _ = try decoder.decode(String.self, from: data.subdata(in: token.span)) }
        }
        mutating func value(depth: Int) throws -> RetentionProvenanceValue {
            whitespace()
            guard offset < data.count else { throw ExternalRetentionProvenance.invalid() }
            switch data[offset] {
            case 123:
                guard depth < ExternalRetentionProvenance.maximumDepth else { throw ExternalRetentionProvenance.invalid() }
                try count(2)
                offset += 1
                whitespace()
                var members: [RetentionProvenanceObject<RetentionProvenanceValue>.Member] = []
                var keys: Set<Data> = []
                if offset < data.count, data[offset] == 125 { offset += 1; return .object(.init([])) }
                while true {
                    let key = try string()
                    guard keys.insert(Data(key.utf8)).inserted else { throw ExternalRetentionProvenance.invalid() }
                    try count(RetentionProvenanceValue.quote(key).utf8.count + 1 + (members.isEmpty ? 0 : 1))
                    try consume(58)
                    members.append(.init(key: key, value: try value(depth: depth + 1)))
                    whitespace()
                    guard offset < data.count else { throw ExternalRetentionProvenance.invalid() }
                    if data[offset] == 125 { offset += 1; return .object(.init(members)) }
                    try consume(44)
                }
            case 91:
                guard depth < ExternalRetentionProvenance.maximumDepth else { throw ExternalRetentionProvenance.invalid() }
                try count(2)
                offset += 1
                whitespace()
                var values: [RetentionProvenanceValue] = []
                if offset < data.count, data[offset] == 93 { offset += 1; return .array([]) }
                while true {
                    if !values.isEmpty { try count(1) }
                    values.append(try value(depth: depth + 1))
                    whitespace()
                    guard offset < data.count else { throw ExternalRetentionProvenance.invalid() }
                    if data[offset] == 93 { offset += 1; return .array(values) }
                    try consume(44)
                }
            case 34:
                let text = try string()
                try count(RetentionProvenanceValue.quote(text).utf8.count)
                return .string(text)
            case 116: try count(4); try literal("true"); return .boolean(true)
            case 102: try count(5); try literal("false"); return .boolean(false)
            case 110: try count(4); try literal("null"); return .null
            default:
                let start = offset
                while offset < data.count && ![9, 10, 13, 32, 44, 93, 125].contains(data[offset]) { offset += 1 }
                let token = String(decoding: data[start..<offset], as: UTF8.self)
                guard token.range(of: #"^-?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil,
                      token != "-0", let number = Int64(token),
                      (-9_007_199_254_740_991...9_007_199_254_740_991).contains(number) else { throw ExternalRetentionProvenance.invalid() }
                try count(token.utf8.count)
                return .integer(number)
            }
        }
        mutating func literal(_ text: String) throws {
            for byte in text.utf8 {
                guard offset < data.count, data[offset] == byte else { throw ExternalRetentionProvenance.invalid() }
                offset += 1
            }
        }

        /// 대상 경로만 찾아 검증한다. 관련 없는 snapshot 값은 JSONDecoder의 기존 계약이 검사한다.
        mutating func find(path: [String]) throws -> Range<Int>? {
            whitespace()
            if path.isEmpty {
                let start = offset
                try skip()
                return start..<offset
            }
            var found: Range<Int>?
            var seen = false
            try members { parser, key in
                guard key.utf8.elementsEqual(path[0].utf8) else { try parser.skip(); return }
                guard !seen else { throw ExternalRetentionProvenance.invalid() }
                seen = true
                found = try parser.find(path: Array(path.dropFirst()))
            }
            return found
        }

        /// snapshot의 inline 출처와 compact 저장 출처의 범위. 저장 키 중복은 순회 뒤에 거부한다.
        struct SnapshotSpans {
            var inline: Range<Int>?
            var stored: Range<Int>?
            var isStoredRepeated = false
        }

        /// 두 출처 표현을 한 번의 순회로 찾는다. inline 쪽 검사는 예전 첫 순회와 같은 자리에서 오류를 낸다.
        mutating func findSnapshotProvenance() throws -> SnapshotSpans {
            var spans = SnapshotSpans()
            var seenInline = false
            try members { parser, key in
                if key.utf8.elementsEqual("externalRetentions".utf8) {
                    guard !seenInline else { throw ExternalRetentionProvenance.invalid() }
                    seenInline = true
                    spans.inline = try parser.find(path: ["provenance"])
                } else if key.utf8.elementsEqual("externalRetentionProvenanceJSON".utf8) {
                    spans.isStoredRepeated = spans.isStoredRepeated || spans.stored != nil
                    spans.stored = try parser.find(path: [])
                } else { try parser.skip() }
            }
            return spans
        }

        /// 객체면 멤버마다 키를 넘겨 값을 소비하게 한다. 객체가 아니면 값을 건너뛴다.
        mutating func members(_ visit: (inout Parser, String) throws -> Void) throws {
            whitespace()
            guard offset < data.count, data[offset] == 123 else { try skip(); return }
            offset += 1
            whitespace()
            if offset < data.count, data[offset] == 125 { offset += 1; return }
            while true {
                let name = try key()
                try consume(58)
                try visit(&self, name)
                whitespace()
                guard offset < data.count else { throw ExternalRetentionProvenance.invalid() }
                if data[offset] == 125 { offset += 1; return }
                try consume(44)
            }
        }

        /// escape가 없는 키는 원본 바이트가 곧 값이다. escape가 있을 때만 디코드해 별칭도 같은 키로 본다.
        mutating func key() throws -> String {
            let token = try stringToken()
            guard token.isVerbatim else { return try decoder.decode(String.self, from: data.subdata(in: token.span)) }
            return String(decoding: data[token.span.lowerBound + 1..<token.span.upperBound - 1], as: UTF8.self)
        }

        /// 무관한 큰 배열·객체를 재귀 할당하지 않고 넘어간다. 문자열 안 구분자는 세지 않는다.
        mutating func skip() throws {
            whitespace()
            guard offset < data.count else { throw ExternalRetentionProvenance.invalid() }
            if data[offset] == 34 { try skipString(); return }
            if data[offset] == 123 || data[offset] == 91 {
                var stack: [UInt8] = []
                repeat {
                    guard offset < data.count else { throw ExternalRetentionProvenance.invalid() }
                    let byte = data[offset]
                    if byte == 34 { try skipString(); continue }
                    offset += 1
                    if byte == 123 { stack.append(125) }
                    else if byte == 91 { stack.append(93) }
                    else if byte == 125 || byte == 93 {
                        guard stack.popLast() == byte else { throw ExternalRetentionProvenance.invalid() }
                    }
                } while !stack.isEmpty
            } else {
                let start = offset
                while offset < data.count && ![9, 10, 13, 32, 44, 93, 125].contains(data[offset]) {
                    if data[offset] == 34 || data[offset] == 91 || data[offset] == 123 { hasAmbiguousScalar = true }
                    offset += 1
                }
                guard offset > start else { throw ExternalRetentionProvenance.invalid() }
            }
        }
    }
}
