import Foundation

/// 모르는 출처 버전도 snapshot에 잃지 않고 보관하는 제한된 JSON 값이다.
public indirect enum RetentionProvenanceValue: Sendable, Equatable, Encodable {
    case object(RetentionProvenanceObject<RetentionProvenanceValue>)
    case array([RetentionProvenanceValue])
    case string(String)
    case integer(Int64)
    case boolean(Bool)
    case null

    public static func == (left: Self, right: Self) -> Bool {
        switch (left, right) {
        case let (.object(a), .object(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.string(a), .string(b)): return a.utf8.elementsEqual(b.utf8)
        case let (.integer(a), .integer(b)): return a == b
        case let (.boolean(a), .boolean(b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .object(items):
            var container = encoder.container(keyedBy: Key.self)
            // Foundation keyed encoder가 정규화 동등 키를 합칠 때에는 원본을 조용히 잃지 않는다.
            guard Set(items.keys).count == items.members.count else {
                throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                    debugDescription: "Keyed encoding cannot preserve distinct Unicode provenance keys."))
            }
            for member in items.members { try container.encode(member.value, forKey: Key(member.key)) }
        case let .array(items):
            var container = encoder.unkeyedContainer()
            for value in items { try container.encode(value) }
        default:
            var container = encoder.singleValueContainer()
            switch self {
            case let .string(value): try container.encode(value)
            case let .integer(value): try container.encode(value)
            case let .boolean(value): try container.encode(value)
            case .null: try container.encodeNil()
            default: break
            }
        }
    }

    public var object: RetentionProvenanceObject<RetentionProvenanceValue>? { if case let .object(value) = self { value } else { nil } }
    public var array: [Self]? { if case let .array(value) = self { value } else { nil } }
    public var string: String? { if case let .string(value) = self { value } else { nil } }
    public var integer: Int64? { if case let .integer(value) = self { value } else { nil } }

    /// JSON.stringify와 같은 필수 escape만 쓰는 compact 표현이다. 임의 키 순서는 바이트 수에 영향이 없다.
    public var canonicalJSON: String {
        switch self {
        case let .object(items):
            return "{" + items.members.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }.map {
                Self.quote($0.key) + ":" + $0.value.canonicalJSON
            }.joined(separator: ",") + "}"
        case let .array(items): return "[" + items.map(\.canonicalJSON).joined(separator: ",") + "]"
        case let .string(value): return Self.quote(value)
        case let .integer(value): return String(value)
        case let .boolean(value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    /// 터미널에도 안전한 JSON 문자열 escape를 반환한다. 출력 예산은 이 처리 뒤에 센다.
    public static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 0..<32: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}


/// Swift String의 정규화 동등성을 JSON 키 신원으로 쓰지 않는 순서 있는 저장소다.
/// 원소 타입에 독립적이므로 JSON 값/검증기로 되돌아가는 구체 의존이 없다.
public struct RetentionProvenanceObject<Element: Sendable & Equatable>: Sendable, Equatable {
    public struct Member: Sendable, Equatable {
        public let key: String
        public let value: Element
        public init(key: String, value: Element) { self.key = key; self.value = value }
        public static func == (left: Self, right: Self) -> Bool {
            left.key.utf8.elementsEqual(right.key.utf8) && left.value == right.value
        }
    }
    public let members: [Member]
    public init(_ members: [Member]) { self.members = members }
    public var keys: [String] { members.map(\.key) }
    public var values: [Element] { members.map(\.value) }
    public subscript(_ key: String) -> Element? {
        members.first { $0.key.utf8.elementsEqual(key.utf8) }?.value
    }
    public static func == (left: Self, right: Self) -> Bool {
        guard left.members.count == right.members.count else { return false }
        let indexed = Dictionary(right.members.map { (Data($0.key.utf8), $0.value) }, uniquingKeysWith: { first, _ in first })
        return left.members.allSatisfy { indexed[Data($0.key.utf8)] == $0.value }
    }
}
