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
        let path = snapshot ? ["externalRetentions", "provenance"] : ["provenance"]
        let inline = try parser.find(path: path).map { try parseEnvelope(data.subdata(in: $0)) }
        guard snapshot else { return inline }
        // 새 compact 저장 필드도 키ed decoder보다 먼저 찾는다. escaped alias 중복도 거부한다.
        var rawParser = Parser(data: data)
        guard let rawSpan = try rawParser.find(path: ["externalRetentionProvenanceJSON"]) else { return inline }
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
            whitespace()
            let start = offset
            try consume(34)
            while offset < data.count {
                let byte = data[offset]
                offset += 1
                if byte == 92 {
                    guard offset < data.count else { throw ExternalRetentionProvenance.invalid() }
                    offset += 1
                } else if byte == 34 {
                    // Foundation 문자열 decoder는 잘못된 surrogate escape를 명시적으로 거부한다.
                    return try JSONDecoder().decode(String.self, from: data.subdata(in: start..<offset))
                } else if byte < 32 { throw ExternalRetentionProvenance.invalid() }
            }
            throw ExternalRetentionProvenance.invalid()
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
            guard offset < data.count, data[offset] == 123 else { try skip(); return nil }
            offset += 1
            whitespace()
            var found: Range<Int>?
            var seen = false
            if offset < data.count, data[offset] == 125 { offset += 1; return nil }
            while true {
                let key = try string()
                try consume(58)
                if key.utf8.elementsEqual(path[0].utf8) {
                    guard !seen else { throw ExternalRetentionProvenance.invalid() }
                    seen = true
                    found = try find(path: Array(path.dropFirst()))
                } else { try skip() }
                whitespace()
                guard offset < data.count else { throw ExternalRetentionProvenance.invalid() }
                if data[offset] == 125 { offset += 1; return found }
                try consume(44)
            }
        }

        /// 무관한 큰 배열·객체를 재귀 할당하지 않고 넘어간다. 문자열 안 구분자는 세지 않는다.
        mutating func skip() throws {
            whitespace()
            guard offset < data.count else { throw ExternalRetentionProvenance.invalid() }
            if data[offset] == 34 { _ = try string(); return }
            if data[offset] == 123 || data[offset] == 91 {
                var stack: [UInt8] = []
                repeat {
                    guard offset < data.count else { throw ExternalRetentionProvenance.invalid() }
                    let byte = data[offset]
                    if byte == 34 { _ = try string(); continue }
                    offset += 1
                    if byte == 123 { stack.append(125) }
                    else if byte == 91 { stack.append(93) }
                    else if byte == 125 || byte == 93 {
                        guard stack.popLast() == byte else { throw ExternalRetentionProvenance.invalid() }
                    }
                } while !stack.isEmpty
            } else {
                let start = offset
                while offset < data.count && ![9, 10, 13, 32, 44, 93, 125].contains(data[offset]) { offset += 1 }
                guard offset > start else { throw ExternalRetentionProvenance.invalid() }
            }
        }
    }
}
