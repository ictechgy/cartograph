import CartographCore

/// Predicate 문자열의 제한된 비교 문법에서 실제 KVC 키 경로만 분리한다.
/// 지원하지 않는 문법을 Foundation에 실행시키지 않고 미결로 남긴다.
enum RuntimePredicateFormatParser {
    static func keyPaths(in format: String, arguments: [String?] = []) -> [String]? {
        guard format.utf8.count <= 4_096, let tokens = tokenize(format), tokens.count <= 256 else { return nil }
        var parser = Parser(tokens: tokens, arguments: arguments)
        guard parser.expression(depth: 0), parser.offset == tokens.count else { return nil }
        return parser.paths.sorted()
    }

    private enum Token: Equatable {
        case word(String), literal, placeholder(Character), comparison(String), modifier, left, right
    }

    private static let comparisons: Set<String> = [
        "=", "==", "!=", "<>", "<", "<=", ">", ">=",
        "BEGINSWITH", "ENDSWITH", "CONTAINS", "LIKE", "MATCHES", "IN", "BETWEEN",
    ]

    private static func tokenize(_ format: String) -> [Token]? {
        let input = Array(format)
        var offset = 0
        var tokens: [Token] = []
        while offset < input.count {
            let character = input[offset]
            if character.isWhitespace { offset += 1; continue }
            if character == "(" { tokens.append(.left); offset += 1; continue }
            if character == ")" { tokens.append(.right); offset += 1; continue }
            if character == "'" || character == "\"" {
                guard skipString(input, offset: &offset) else { return nil }
                tokens.append(.literal)
                continue
            }
            if character == "%" {
                guard offset + 1 < input.count, ["@", "K"].contains(input[offset + 1]) else { return nil }
                tokens.append(.placeholder(input[offset + 1])); offset += 2
                continue
            }
            if character == "[" {
                offset += 1
                let start = offset
                while offset < input.count, input[offset] != "]" { offset += 1 }
                guard offset < input.count, ["c", "d", "cd", "dc"].contains(String(input[start..<offset])) else {
                    return nil
                }
                tokens.append(.modifier); offset += 1
                continue
            }
            if "=!<>".contains(character) {
                let start = offset
                while offset < input.count, "=!<>".contains(input[offset]) { offset += 1 }
                let value = String(input[start..<offset])
                guard comparisons.contains(value) else { return nil }
                tokens.append(.comparison(value))
                continue
            }
            if character.isASCII && (character.isNumber || character == "-" || character == "+") {
                let start = offset
                while offset < input.count, "0123456789.eE+-".contains(input[offset]) { offset += 1 }
                guard let number = Double(String(input[start..<offset])), number.isFinite else { return nil }
                tokens.append(.literal)
                continue
            }
            guard isIdentifierStart(character) else { return nil }
            let start = offset
            while offset < input.count, isIdentifierContinuation(input[offset]) || input[offset] == "." {
                offset += 1
            }
            let value = String(input[start..<offset])
            tokens.append(comparisons.contains(value.uppercased()) ? .comparison(value.uppercased()) : .word(value))
        }
        return tokens
    }

    private static func skipString(_ input: [Character], offset: inout Int) -> Bool {
        let quote = input[offset]
        offset += 1
        while offset < input.count {
            if input[offset] == quote { offset += 1; return true }
            if input[offset] == "\\" { offset += 1 }
            offset += 1
        }
        return false
    }

    private static func isIdentifierStart(_ value: Character) -> Bool {
        value.isASCII && (value.isLetter || value == "_")
    }

    private static func isIdentifierContinuation(_ value: Character) -> Bool {
        isIdentifierStart(value) || (value.isASCII && value.isNumber)
    }

    private struct Parser {
        private static let reserved: Set<String> = [
            "AND", "OR", "NOT", "ANY", "ALL", "NONE", "SOME", "SUBQUERY", "FUNCTION", "CAST",
            "TRUEPREDICATE", "FALSEPREDICATE", "NAN", "INF",
        ]
        let tokens: [Token]
        let arguments: [String?]
        var offset = 0
        var argumentOffset = 0
        var paths: Set<String> = []

        mutating func expression(depth: Int) -> Bool {
            guard conjunction(depth: depth) else { return false }
            while consumeWord("OR") {
                guard conjunction(depth: depth) else { return false }
            }
            return true
        }

        mutating func conjunction(depth: Int) -> Bool {
            guard primary(depth: depth) else { return false }
            while consumeWord("AND") {
                guard primary(depth: depth) else { return false }
            }
            return true
        }

        mutating func primary(depth: Int) -> Bool {
            guard depth <= 16 else { return false }
            if consumeWord("NOT") { return primary(depth: depth + 1) }
            if consume(.left) {
                return expression(depth: depth + 1) && consume(.right)
            }
            if consumeWord("TRUEPREDICATE") || consumeWord("FALSEPREDICATE") { return true }
            guard operand(), offset < tokens.count, case .comparison = tokens[offset] else { return false }
            offset += 1
            _ = consume(.modifier)
            return operand()
        }

        mutating func operand() -> Bool {
            guard offset < tokens.count else { return false }
            let token = tokens[offset]
            offset += 1
            switch token {
            case .literal: return true
            case let .placeholder(kind):
                guard argumentOffset < arguments.count else { return false }
                defer { argumentOffset += 1 }
                guard kind == "K" else { return true }
                guard let value = arguments[argumentOffset] else { return false }
                return recordPath(value)
            case let .word(value):
                if ["TRUE", "FALSE", "YES", "NO", "NIL", "NULL", "SELF"].contains(value.uppercased()) { return true }
                guard !Self.reserved.contains(value.uppercased()) else { return false }
                return recordPath(value)
            default: return false
            }
        }

        mutating func recordPath(_ value: String) -> Bool {
            guard let components = RuntimeKeyPath.components(of: value) else { return false }
            paths.insert(components.joined(separator: "."))
            return true
        }

        mutating func consumeWord(_ value: String) -> Bool {
            guard offset < tokens.count, case let .word(word) = tokens[offset], word.uppercased() == value else {
                return false
            }
            offset += 1
            return true
        }

        mutating func consume(_ value: Token) -> Bool {
            guard offset < tokens.count, tokens[offset] == value else { return false }
            offset += 1
            return true
        }
    }
}
