import Foundation

/// JSON 바이트를 `JSONDecoder().decode(MCPJSONValue.self, from:)`와 같은 값으로 읽되, 중첩 깊이와 무관하게
/// 입력 크기에 비례하는 시간에 끝내는 판독기.
///
/// `MCPJSONValue`의 익스텐션으로 두지 않는다. 값 타입이 판독기를 참조하면, 판독기가 값을 만드는 방향과 합쳐져
/// 타입 수준 순환이 된다.
enum MCPJSONReader {
    /// 기존 Codable 디코더와 같은 값을 돌려주고, 같은 문서를 거절한다.
    ///
    /// Codable 경로는 값마다 Bool→Int64→Double→String→배열→객체를 `try?`로 차례로 시도하고, 실패할 때마다 그
    /// 깊이만큼의 codingPath를 만든다. 그래서 깊게 중첩된 요청 하나가 구조 검증에 닿기도 전에 서버를 수십 초
    /// 묶었다(릴리스 빌드에서 깊이 500 × 폭 500인 500 KB에 59초). `JSONSerialization`은 빠르지만 문자열 맨 앞의
    /// U+FEFF를 지우고, 일부 실수를 1 ulp 다르게 읽고, 중복 키를 다르게 고른다. 요청과 도구 결과의 값이 바뀐다.
    ///
    /// 그래서 문서 구조는 이 판독기가 한 번 걷고, 문자열과 숫자는 종류별로 평평한 배열 하나에 모아 같은
    /// `JSONDecoder`로 읽는다. 깊이 1에서는 실패한 시도의 비용이 상수다. 이스케이프·UTF-8 검증·정수와 실수의
    /// 구분·인코딩 감지·중첩 상한(512단)은 기존 디코더의 규칙을 그대로 쓴다. 중복 키도 기존처럼 앞의 것만 남기고,
    /// 버려지는 값은 읽지 않으므로 그 안의 형식 오류는 문제 삼지 않는다.
    static func parse(_ data: Data) throws -> MCPJSONValue {
        // 구조·중첩·리터럴 검증은 기존 디코더의 스캐너에 맡긴다. 스칼라의 내용은 배치를 읽을 때 검증된다.
        _ = try JSONDecoder().decode(MCPJSONStructureCheck.self, from: data)
        var tokenizer = MCPJSONTokenizer(bytes: try MCPJSONTextEncoding.utf8Bytes(of: data))
        try tokenizer.run()
        var assembler = MCPJSONAssembler(
            tokens: tokenizer.tokens,
            strings: try tokenizer.strings.decode(MCPJSONStringSlot.self).map(\.value),
            numbers: try tokenizer.numbers.decode(MCPJSONNumberSlot.self).map(\.value)
        )
        return try assembler.assemble()
    }
}

/// 판독기가 문서를 기존 디코더와 같게 읽을 수 없을 때 내는 개발자용 오류.
///
/// MCP 요청에서는 기존 디코더 오류와 똑같이 parse error(`malformed JSON`)로 바뀌므로 사용자에게 보이지 않는다.
private struct MCPJSONReadError: Error, LocalizedError {
    let reason: String

    var errorDescription: String? {
        "Could not read the JSON text (\(reason)); send UTF-8 JSON that Foundation's JSONDecoder accepts"
    }
}

/// 아무것도 읽지 않는 Decodable. `JSONDecoder`가 해독 전에 문서 전체를 훑으며 하는 구조 검증만 얻으려고 둔다.
private struct MCPJSONStructureCheck: Decodable {
    init(from _: any Decoder) throws {}
}

/// 문자열 토큰 하나를 기존 디코더의 `decode(String.self)`로 읽는다.
///
/// 실패는 곧바로 던지지 않고 nil로 남긴다. 버려지는 중복 키 값이면 기존 디코더도 읽지 않으므로, 조립 단계가 실제로
/// 쓰는 칸에서만 오류로 바꾼다.
private struct MCPJSONStringSlot: Decodable {
    let value: String?

    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(String.self)
    }
}

/// 숫자 토큰 하나를 `MCPJSONValue.init(from:)`과 같은 순서(Int64 다음 Double)로 읽는다.
///
/// 그 앞의 Bool 시도는 숫자에서 늘 실패하므로 뺐다. 실패를 nil로 남기는 까닭은 `MCPJSONStringSlot`과 같다.
private struct MCPJSONNumberSlot: Decodable {
    let value: MCPJSONValue?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int64.self) {
            value = .integer(integer)
        } else {
            value = (try? container.decode(Double.self)).map(MCPJSONValue.number)
        }
    }
}

/// 같은 종류의 스칼라 토큰을 원문 그대로 평평한 JSON 배열 하나로 모은다.
///
/// 깊이 1의 배열로 읽어야 실패한 시도의 codingPath가 한 칸으로 유지된다.
private struct MCPJSONScalarBatch {
    private var json: [UInt8] = [UInt8(ascii: "[")]
    private var count = 0

    /// 토큰을 덧붙이고 그 토큰의 칸 번호를 돌려준다.
    mutating func append(_ token: ArraySlice<UInt8>) -> Int {
        if count > 0 { json.append(UInt8(ascii: ",")) }
        json.append(contentsOf: token)
        count += 1
        return count - 1
    }

    func decode<Slot: Decodable>(_: Slot.Type) throws -> [Slot] {
        try JSONDecoder().decode([Slot].self, from: Data(json + [UInt8(ascii: "]")]))
    }
}

/// 판독기가 문서 순서대로 남기는 구조 토큰. 문자열과 숫자는 배치 안의 칸 번호만 가진다.
private enum MCPJSONToken {
    case arrayStart, arrayEnd, objectStart, objectEnd
    case string(Int)
    case number(Int)
    case literal(MCPJSONValue)
}

/// 구조 검증을 통과한 UTF-8 문서를 한 번 훑어 토큰과 스칼라 배치를 만든다.
///
/// 검증된 문서만 받으므로 문법을 다시 판정하지 않는다. 대신 예상 밖의 바이트를 만나면 추측하지 않고 오류를 낸다.
private struct MCPJSONTokenizer {
    private let bytes: [UInt8]
    private var index = 0
    private(set) var tokens: [MCPJSONToken] = []
    private(set) var strings = MCPJSONScalarBatch()
    private(set) var numbers = MCPJSONScalarBatch()

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func run() throws {
        while index < bytes.count {
            try step(bytes[index])
        }
    }

    private mutating func step(_ byte: UInt8) throws {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","), UInt8(ascii: ":"): index += 1
        case UInt8(ascii: "["): emit(.arrayStart)
        case UInt8(ascii: "]"): emit(.arrayEnd)
        case UInt8(ascii: "{"): emit(.objectStart)
        case UInt8(ascii: "}"): emit(.objectEnd)
        case UInt8(ascii: "\""): try scanString()
        case UInt8(ascii: "t"): try scanLiteral("true", .boolean(true))
        case UInt8(ascii: "f"): try scanLiteral("false", .boolean(false))
        case UInt8(ascii: "n"): try scanLiteral("null", .null)
        default: try scanNumber()
        }
    }

    private mutating func emit(_ token: MCPJSONToken) {
        tokens.append(token)
        index += 1
    }

    /// 닫는 따옴표까지를 원문 그대로 문자열 배치에 넣는다. 역슬래시 다음 바이트는 이스케이프의 일부라 건너뛴다.
    private mutating func scanString() throws {
        var end = index + 1
        while end < bytes.count, bytes[end] != UInt8(ascii: "\"") {
            end += bytes[end] == UInt8(ascii: "\\") ? 2 : 1
        }
        guard end < bytes.count else { throw MCPJSONReadError(reason: "unterminated string") }
        tokens.append(.string(strings.append(bytes[index...end])))
        index = end + 1
    }

    /// 구분자 전까지를 숫자 토큰 하나로 넣는다. 형식 판정은 배치를 읽는 기존 디코더가 한다.
    private mutating func scanNumber() throws {
        var end = index
        while end < bytes.count, !Self.isDelimiter(bytes[end]) { end += 1 }
        guard end > index else { throw MCPJSONReadError(reason: "unexpected byte \(bytes[index])") }
        tokens.append(.number(numbers.append(bytes[index..<end])))
        index = end
    }

    private mutating func scanLiteral(_ text: String, _ value: MCPJSONValue) throws {
        let end = index + text.utf8.count
        guard end <= bytes.count, bytes[index..<end].elementsEqual(text.utf8) else {
            throw MCPJSONReadError(reason: "unexpected literal")
        }
        tokens.append(.literal(value))
        index = end
    }

    private static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: "["), UInt8(ascii: "]"),
             UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "\""):
            return true
        default:
            return false
        }
    }
}

/// 토큰 열을 값 나무로 조립한다.
///
/// 열린 컨테이너는 직접 든 스택에 쌓아 호출 스택을 쓰지 않는다. 틀은 배열 첨자로 제자리에서 고쳐, 넓은 배열에
/// 원소를 붙일 때마다 저장소를 복사하지 않는다.
private struct MCPJSONAssembler {
    private struct Frame {
        let isObject: Bool
        var items: [MCPJSONValue] = []
        var members: [String: MCPJSONValue] = [:]
        var key: String?
    }

    private let tokens: [MCPJSONToken]
    private let strings: [String?]
    private let numbers: [MCPJSONValue?]
    private var stack: [Frame] = []
    private var index = 0

    init(tokens: [MCPJSONToken], strings: [String?], numbers: [MCPJSONValue?]) {
        self.tokens = tokens
        self.strings = strings
        self.numbers = numbers
    }

    mutating func assemble() throws -> MCPJSONValue {
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if let value = try value(for: token), let root = try attach(value) {
                return root
            }
        }
        throw MCPJSONReadError(reason: "unbalanced containers")
    }

    /// 완성된 값을 돌려준다. 컨테이너를 열거나 객체 키를 읽은 토큰은 상태만 바꾸고 nil을 돌려준다.
    private mutating func value(for token: MCPJSONToken) throws -> MCPJSONValue? {
        switch token {
        case .arrayStart: stack.append(Frame(isObject: false))
        case .objectStart: stack.append(Frame(isObject: true))
        case .arrayEnd: return try close(isObject: false)
        case .objectEnd: return try close(isObject: true)
        case let .string(slot): return try string(try scalar(strings[slot]))
        case let .number(slot): return try scalar(numbers[slot])
        case let .literal(value): return value
        }
        return nil
    }

    /// 객체가 키를 기다리면 키로 쓴다. 이미 있는 키면 기존 디코더처럼 앞의 값을 남기고 뒤의 값은 읽지 않는다.
    private mutating func string(_ text: String) throws -> MCPJSONValue? {
        guard let top = stack.indices.last, stack[top].isObject, stack[top].key == nil else { return .string(text) }
        if stack[top].members[text] == nil {
            stack[top].key = text
        } else {
            try skipValue()
        }
        return nil
    }

    private func scalar<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw MCPJSONReadError(reason: "invalid string or number") }
        return value
    }

    private mutating func close(isObject: Bool) throws -> MCPJSONValue {
        guard let frame = stack.popLast(), frame.isObject == isObject, frame.key == nil else {
            throw MCPJSONReadError(reason: "unbalanced containers")
        }
        return isObject ? .object(frame.members) : .array(frame.items)
    }

    /// 완성된 값을 바깥 컨테이너에 붙인다. 바깥이 없으면 그 값이 문서 전체다.
    private mutating func attach(_ value: MCPJSONValue) throws -> MCPJSONValue? {
        guard let top = stack.indices.last else {
            guard index == tokens.count else { throw MCPJSONReadError(reason: "text after the top-level value") }
            return value
        }
        guard stack[top].isObject else {
            stack[top].items.append(value)
            return nil
        }
        guard let key = stack[top].key else { throw MCPJSONReadError(reason: "object member without a key") }
        stack[top].members[key] = value
        stack[top].key = nil
        return nil
    }

    /// 버려지는 값 하나(스칼라 또는 컨테이너 전체)를 건너뛴다. 그 안의 스칼라는 읽지 않는다.
    private mutating func skipValue() throws {
        var depth = 0
        repeat {
            guard index < tokens.count else { throw MCPJSONReadError(reason: "unbalanced containers") }
            switch tokens[index] {
            case .arrayStart, .objectStart: depth += 1
            case .arrayEnd, .objectEnd: depth -= 1
            case .string, .number, .literal: break
            }
            index += 1
        } while depth > 0
    }
}

/// 기존 디코더(swift-foundation `JSONDecoder`)가 고르는 문서 인코딩을 같은 규칙으로 골라 UTF-8 바이트로 바꾼다.
///
/// 규칙은 RFC 4627 3절의 BOM·NUL 위치 판정이다. 기존 디코더는 `FE FF 00 00`을 UTF-32LE BOM으로, `FF FE 00 00`을
/// UTF-16LE BOM으로 보는데, 이 판정까지 그대로 따른다. 다르게 고르면 구조 검증을 통과한 문서를 다른 글자로 읽게 된다.
private enum MCPJSONTextEncoding {
    static func utf8Bytes(of data: Data) throws -> [UInt8] {
        let bytes = [UInt8](data)
        let (encoding, bomLength) = detect(bytes)
        let body = bytes.dropFirst(bomLength)
        guard encoding != .utf8 else { return Array(body) }
        guard let text = String(bytes: body, encoding: encoding) else {
            throw MCPJSONReadError(reason: "text is not valid in the detected encoding")
        }
        return Array(text.utf8)
    }

    /// 앞 네 바이트로 인코딩과 BOM 길이를 고른다. 판정 순서가 결과를 바꾸므로 기존 디코더의 순서를 지킨다.
    private static func detect(_ bytes: [UInt8]) -> (String.Encoding, Int) {
        let prefix = (0..<4).map { $0 < bytes.count ? bytes[$0] : nil }
        switch (prefix[0], prefix[1], prefix[2], prefix[3]) {
        case (0, 0, 0xFE, 0xFF): return (.utf32BigEndian, 4)
        case (0xFE, 0xFF, 0, 0): return (.utf32LittleEndian, 4)
        case (0xFE, 0xFF, _, _): return (.utf16BigEndian, 2)
        case (0xFF, 0xFE, _, _): return (.utf16LittleEndian, 2)
        case (0xEF, 0xBB, 0xBF, _): return (.utf8, 3)
        case let (0, 0, 0, last?) where last != 0: return (.utf32BigEndian, 0)
        case let (0, first?, 0, second?) where first != 0 && second != 0: return (.utf16BigEndian, 0)
        case let (first?, 0, 0, 0) where first != 0: return (.utf32LittleEndian, 0)
        case let (first?, 0, second?, 0) where first != 0 && second != 0: return (.utf16LittleEndian, 0)
        case let (0, last?, nil, nil) where last != 0: return (.utf16BigEndian, 0)
        case let (first?, 0, nil, nil) where first != 0: return (.utf16LittleEndian, 0)
        default: return (.utf8, 0)
        }
    }
}
