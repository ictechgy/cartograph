/// 그래프 정점을 식별하는 안정적인 키.
///
/// 레벨에 따라 원본이 달라진다.
/// - `.symbol`: USR (예: `s:11MyModule3FooV`)
/// - `.type`: 심볼을 감싸는 최상위 타입의 USR
/// - `.file`: 소스 파일 경로
/// - `.module`: 모듈 이름
///
/// 문자열을 그대로 쓰지 않고 별도 타입으로 감싸는 이유는, 레벨이 다른 키가
/// 실수로 섞이는 것을 타입 시스템 밖에서라도 눈에 띄게 하기 위함이다.
public struct NodeID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: NodeID, rhs: NodeID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension NodeID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension NodeID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}
