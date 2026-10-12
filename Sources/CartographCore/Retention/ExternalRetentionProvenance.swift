import Foundation

/// v0 외부 보존의 선택적 문서 수준 출처다. 근거 선택에는 영향을 주지 않는다.
public struct ExternalRetentionProvenance: Sendable, Equatable, Codable {
    /// JSONDecoder보다 먼저 확인한 원본 envelope를 전달하는 내부 로딩 계약이다.
    public static let admittedCodingKey = CodingUserInfoKey(rawValue: "cartograph.retentionProvenance")!
    public static let maximumBytes = 1_048_576
    public static let maximumSources = 256
    public static let maximumLimitations = 4096
    public static let maximumDepth = 64
    public let value: RetentionProvenanceValue

    public init(value: RetentionProvenanceValue) throws {
        try Self.validate(value)
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        guard !(try decoder.singleValueContainer().decodeNil()), let admitted = decoder.userInfo[Self.admittedCodingKey] as? Self else { throw Self.invalid() }
        self = admitted
    }

    public func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
    public var version: Int64 { value.object?["version"]?.integer ?? 0 }
    public var sources: [RetentionProvenanceValue]? { value.object?["sources"]?.array }
    public var limitations: [RetentionProvenanceValue]? { value.object?["limitations"]?.array }

    /// 알 수 없는 버전에도 상한을 먼저 적용하고 알려진 모양으로 추측하지 않는다.
    private static func validate(_ value: RetentionProvenanceValue) throws {
        var budget = ValueBudget()
        try budget.visit(value, parentDepth: 0)
        guard let object = value.object, let version = object["version"]?.integer, version > 0,
              (object["sources"]?.array?.count ?? 0) <= maximumSources,
              (object["limitations"]?.array?.count ?? 0) <= maximumLimitations else { throw invalid() }
        guard version == 1 else { return }
        guard let limitations = object["limitations"]?.array else { throw invalid() }
        for item in limitations {
            guard let limitation = item.object,
                  limitation["platform"]?.string != nil, limitation["tool"]?.string != nil,
                  limitation["message"]?.string != nil, nullableString(limitation["target"]) else { throw invalid() }
            try optionalString(limitation, "origin")
            try optionalStrings(limitation, "channels")
            if let scope = limitation["routeScope"] {
                guard let fields = scope.object else { throw invalid() }
                for key in ["templates", "templatePrefixes", "templateSuffixes", "methods"] { try optionalStrings(fields, key) }
                if let count = fields["withheldElements"] { guard let number = count.integer, number >= 0 else { throw invalid() } }
            }
        }
        if let rawSources = object["sources"] {
            guard let sources = rawSources.array else { throw invalid() }
            for item in sources {
                guard let source = item.object, source["format"]?.string == "bridge-facts",
                      let version = source["version"]?.integer, version == 1 || version == 2,
                      let tool = source["tool"]?.object, tool["name"]?.string != nil, tool["version"]?.string != nil,
                      source["platform"]?.string != nil, source["project"]?.string != nil,
                      nullableString(source["target"]) else { throw invalid() }
                guard timestamp(source["generatedAt"]) else { throw invalidTimestamp() }
                if let modified = source["sourceModifiedAt"], !timestamp(modified) { throw invalidTimestamp() }
                if version == 2 {
                    guard let transport = source["transport"]?.string,
                          ["basic-message-channel", "event-channel", "react-native-event"].contains(transport) else { throw invalid() }
                } else if source["transport"] != nil { throw invalid() }
            }
        }
    }

    /// 큰 typed API 값도 전체 정규 문자열/자식 배열을 복사하기 전에 상한에서 멈춘다.
    private struct ValueBudget {
        var bytes = 0
        mutating func add(_ count: Int) throws {
            guard count <= maximumBytes - bytes else { throw invalid() }
            bytes += count
        }
        mutating func string(_ text: String) throws {
            try add(2)
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 34, 92, 8, 9, 10, 12, 13: try add(2)
                case 0..<32: try add(6)
                case 0...0x7f: try add(1)
                case 0x80...0x7ff: try add(2)
                case 0x800...0xffff: try add(3)
                default: try add(4)
                }
            }
        }
        mutating func visit(_ value: RetentionProvenanceValue, parentDepth: Int) throws {
            switch value {
            case let .object(object):
                guard parentDepth < maximumDepth else { throw invalid() }
                try add(2)
                var keys: Set<Data> = []
                for (index, member) in object.members.enumerated() {
                    if index > 0 { try add(1) }
                    try string(member.key)
                    guard keys.insert(Data(member.key.utf8)).inserted else { throw invalid() }
                    try add(1)
                    try visit(member.value, parentDepth: parentDepth + 1)
                }
            case let .array(array):
                guard parentDepth < maximumDepth else { throw invalid() }
                try add(2)
                for (index, item) in array.enumerated() {
                    if index > 0 { try add(1) }
                    try visit(item, parentDepth: parentDepth + 1)
                }
            case let .string(text): try string(text)
            case let .integer(number):
                guard (-9_007_199_254_740_991...9_007_199_254_740_991).contains(number) else { throw invalid() }
                try add(String(number).utf8.count)
            case let .boolean(value): try add(value ? 4 : 5)
            case .null: try add(4)
            }
        }
    }

    private static func nullableString(_ value: RetentionProvenanceValue?) -> Bool {
        value == .null || value?.string != nil
    }
    private static func optionalString(_ object: RetentionProvenanceObject, _ key: String) throws {
        if let value = object[key], value.string == nil { throw invalid() }
    }
    private static func optionalStrings(_ object: RetentionProvenanceObject, _ key: String) throws {
        if let value = object[key] {
            guard let values = value.array, values.allSatisfy({ $0.string != nil }) else { throw invalid() }
        }
    }
    private static func timestamp(_ value: RetentionProvenanceValue?) -> Bool {
        guard let text = value?.string,
              text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$"#,
                         options: .regularExpression) != nil else { return false }
        let date = text.prefix(10).split(separator: "-")
        guard date.count == 3, let year = Int(date[0]), let month = Int(date[1]), let day = Int(date[2]),
              (1...12).contains(month) else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return false }
        let clock = text.dropFirst(11).prefix(8).split(separator: ":")
        guard clock.count == 3, let hour = Int(clock[0]), let minute = Int(clock[1]), let second = Int(clock[2]),
              hour <= 23, minute <= 59, second <= 59 else { return false }
        if text.last != "Z" && text.last != "z" {
            let offset = text.suffix(5).split(separator: ":")
            guard offset.count == 2, let hour = Int(offset[0]), let minute = Int(offset[1]),
                  hour <= 23, minute <= 59 else { return false }
        }
        // 이 계약은 leap-second :60을 지원하지 않는다. 원본 대소문자·소수 자릿수는 보존한다.
        return true
    }
    private static func invalidTimestamp() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription:
            "External retention provenance timestamp is outside the portable profile (seconds 00-59; leap seconds are unsupported)."))
    }
    static func invalid() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "External retention provenance is malformed or exceeds its bounds."))
    }
}
