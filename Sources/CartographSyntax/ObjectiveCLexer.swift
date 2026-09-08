import Foundation

/// 문자열 내용을 보존하면서 주석과 토큰 경계를 구분한다. RN의 blanking 결과로는 채널 이름을 복원할 수 없다.
struct ObjectiveCToken: Sendable {
    let text: String
    let literal: String?
    let line: Int
    let column: Int
}

/// UTF-8 바이트를 세어 교환 계약의 열 번호를 지킨다. 전체 C 문법을 해석하는 파서가 아니다.
struct ObjectiveCLexer {
    private let bytes: [UInt8]
    private var offset = 0
    private var line = 1
    private var column = 1
    private(set) var isComplete = true

    init(_ source: String) { bytes = Array(source.utf8) }

    mutating func tokenize() -> [ObjectiveCToken] {
        var result: [ObjectiveCToken] = []
        while offset < bytes.count {
            if [9, 10, 13, 32].contains(bytes[offset]) { advance(); continue }
            if starts([47, 47]) { while offset < bytes.count && ![10, 13].contains(bytes[offset]) { advance() }; continue }
            if starts([47, 42]) { skipComment(); continue }
            let start = offset
            let site = (line, column)
            if starts([64, 34]) { advance() }
            if bytes[offset] == 34 || bytes[offset] == 39 {
                let quote = bytes[offset]
                let value = readString(quote: quote)
                result.append(ObjectiveCToken(
                    text: text(start..<offset), literal: quote == 34 ? value : nil,
                    line: site.0, column: site.1
                ))
            } else {
                if Self.isIdentifierByte(bytes[offset]) {
                    while offset < bytes.count && Self.isIdentifierByte(bytes[offset]) { advance() }
                } else {
                    advance()
                    if offset < bytes.count && Self.pairedOperators.contains(text(start..<(offset + 1))) { advance() }
                }
                result.append(ObjectiveCToken(
                    text: text(start..<offset), literal: nil, line: site.0, column: site.1
                ))
            }
        }
        return result
    }

    private mutating func skipComment() {
        advance(); advance()
        while offset < bytes.count && !starts([42, 47]) { advance() }
        guard offset < bytes.count else { isComplete = false; return }
        advance(); advance()
    }

    /// 확인한 C 이스케이프만 푼다. 해석하지 못한 이스케이프를 다른 정적 이름으로 만들지 않는다.
    private mutating func readString(quote: UInt8) -> String? {
        advance()
        var decoded: [UInt8] = []
        var understood = true
        while offset < bytes.count {
            let byte = bytes[offset]
            advance()
            if byte == quote {
                let value = String(decoding: decoded, as: UTF8.self)
                return understood && Self.isSafeName(value) ? value : nil
            }
            if byte != 92 { decoded.append(byte); continue }
            guard offset < bytes.count else { break }
            let escaped = bytes[offset]
            advance()
            switch escaped {
            case 34, 39, 92: decoded.append(escaped)
            case 10: break
            case 13: if offset < bytes.count && bytes[offset] == 10 { advance() }
            case 110: decoded.append(10)
            case 114: decoded.append(13)
            case 116: decoded.append(9)
            default: understood = false
            }
        }
        isComplete = false
        return nil
    }

    private static func isSafeName(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains {
            $0.value < 32 || (127...159).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029
        }
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte >= 128
    }

    private static let pairedOperators: Set<String> = ["==", "!=", "->", "&&", "||", "<=", ">=", "+=", "-=", "*=", "/=", "++", "--"]

    private func starts(_ prefix: [UInt8]) -> Bool {
        offset + prefix.count <= bytes.count && Array(bytes[offset..<(offset + prefix.count)]) == prefix
    }

    private func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }

    private mutating func advance() {
        if bytes[offset] == 13 {
            line += 1; column = 1
        } else if bytes[offset] == 10 {
            if offset == 0 || bytes[offset - 1] != 13 { line += 1 }
            column = 1
        } else { column += 1 }
        offset += 1
    }
}

/// 괄호 짝을 한 번만 계산해 중첩 깊이가 커져도 재귀하지 않는다.
struct ObjectiveCTokenStream {
    let tokens: [ObjectiveCToken]
    let pairs: [Int: Int]
    let braceDepths: [Int]
    let isBalanced: Bool

    init(_ tokens: [ObjectiveCToken]) {
        self.tokens = tokens
        var pairs: [Int: Int] = [:]
        var stack: [(String, Int)] = []
        var depths: [Int] = []
        var depth = 0
        var balanced = true
        let closing = [")": "(", "]": "[", "}": "{"]
        for index in tokens.indices {
            let text = tokens[index].text
            depths.append(depth)
            if ["(", "[", "{"].contains(text) { stack.append((text, index)) }
            else if let expected = closing[text] {
                if let last = stack.popLast(), last.0 == expected { pairs[last.1] = index }
                else { balanced = false }
            }
            if text == "{" { depth += 1 }
            if text == "}" { depth -= 1 }
        }
        self.pairs = pairs
        braceDepths = depths
        isBalanced = balanced && stack.isEmpty
    }

    func texts(_ range: Range<Int>) -> [String] { tokens[range].map(\.text) }

    /// 메시지의 수신자와 선택자 인자를 분리한다. 인자 안의 괄호·블록은 통째로 건너뛴다.
    func message(at start: Int) -> ObjectiveCMessage? {
        guard tokens[start].text == "[", let end = pairs[start], start + 2 < end else { return nil }
        let receiverStart = start + 1
        var cursor = receiverStart
        if let close = pairs[cursor] { cursor = close + 1 } else { cursor += 1 }
        while cursor + 1 < end && [".", "->"].contains(tokens[cursor].text) { cursor += 2 }
        guard cursor < end else { return nil }
        let receiver = receiverStart..<cursor
        if cursor + 1 == end {
            return ObjectiveCMessage(receiver: receiver, selector: tokens[cursor].text, arguments: [:])
        }
        var arguments: [String: Range<Int>] = [:]
        var names: [String] = []
        while cursor + 1 < end {
            let name = tokens[cursor].text
            guard tokens[cursor + 1].text == ":", arguments[name] == nil else { return nil }
            cursor += 2
            let argumentStart = cursor
            while cursor < end {
                if cursor + 1 < end && tokens[cursor + 1].text == ":" { break }
                cursor = pairs[cursor].map { $0 + 1 } ?? (cursor + 1)
            }
            guard cursor > argumentStart else { return nil }
            names.append(name)
            arguments[name] = argumentStart..<cursor
        }
        guard cursor == end else { return nil }
        return ObjectiveCMessage(receiver: receiver, selector: names.joined(separator: ":") + ":", arguments: arguments)
    }
}

struct ObjectiveCMessage {
    let receiver: Range<Int>
    let selector: String
    let arguments: [String: Range<Int>]
}
