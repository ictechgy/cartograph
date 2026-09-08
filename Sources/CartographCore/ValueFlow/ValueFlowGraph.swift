import Foundation

/// 분석 예산은 넘친 값을 미상으로 바꾸며, 부분 결과가 완전한 사실처럼 나가지 않게 한다.
public struct ValueFlowLimits: Equatable, Sendable, Codable {
    public var contexts: Int
    public var iterations: Int
    public var valuesPerNode: Int
    public var heapCells: Int
    public var callStringDepth: Int

    /// 실행 자원 상한을 호출자가 정하되 빈 예산으로 조용히 성공하지 않게 한다.
    public init(contexts: Int = 512, iterations: Int = 10_000, valuesPerNode: Int = 32,
                heapCells: Int = 10_000, callStringDepth: Int = 2) {
        self.contexts = max(1, contexts)
        self.iterations = max(1, iterations)
        self.valuesPerNode = max(1, valuesPerNode)
        self.heapCells = max(1, heapCells)
        self.callStringDepth = max(1, callStringDepth)
    }
}

/// 문자열뿐 아니라 값 종류를 보존한다. 함수/객체 ID는 USR과 구별되는 분석 내부 식별자다.
public enum ValueFlowAtom: Hashable, Sendable, Codable {
    case literal(ValueFlowLiteral)
    case reference(String)
    case object(id: String, type: String)
    case function(String)
    case type(String)
}

/// 값의 근거는 원래 리터럴/미상 입력 위치를 가리킨다. 서로 다른 호출의 인자를 합치지 않는다.
public struct ValueFlowOrigin: Hashable, Sendable, Codable {
    public let id: String
    public let location: SourceLocation
    public let literal: ValueFlowLiteral?

    /// 같은 문자열도 원래 출처가 다르면 근거를 구별한다.
    public init(id: String, location: SourceLocation, literal: ValueFlowLiteral? = nil) {
        self.id = id
        self.location = location
        self.literal = literal
    }
}

/// 미상은 알려진 가능 값보다 우선한다. 빈 값 집합은 미상이 아니라 아직 정상 반환이 없는 bottom이다.
public struct ValueFlowValue: Hashable, Sendable, Codable {
    public var atoms: Set<ValueFlowAtom>
    public var origins: Set<ValueFlowOrigin>
    public var unknownReasons: Set<String>
    public var isBottom: Bool { atoms.isEmpty && unknownReasons.isEmpty }
    public var isUnknown: Bool { !unknownReasons.isEmpty }

    /// 빈 초기값은 아직 정상 반환을 모르는 bottom이며 미상과 구별된다.
    public init(atoms: Set<ValueFlowAtom> = [], origins: Set<ValueFlowOrigin> = [],
                unknownReasons: Set<String> = []) {
        self.atoms = atoms
        self.origins = origins
        self.unknownReasons = unknownReasons
    }

    /// 모든 경로가 같은 문자열일 때만 브리지 이름을 정적으로 확정할 수 있다.
    public var singleString: String? {
        guard !isUnknown, atoms.count == 1, case let .literal(.string(value))? = atoms.first else { return nil }
        return value
    }

    /// 실패 이유를 보존해 미상과 빈 도달성 결과를 구분한다.
    public static func unknown(_ reason: String, origins: Set<ValueFlowOrigin> = []) -> ValueFlowValue {
        ValueFlowValue(origins: origins, unknownReasons: [reason])
    }

    /// 유한 높이의 격자로 합친다. 가능한 값 수를 넘기면 확정할 수 있는 척하지 않는다.
    public func joining(_ other: ValueFlowValue, limit: Int) -> ValueFlowValue {
        var result = ValueFlowValue(atoms: atoms.union(other.atoms), origins: origins.union(other.origins),
                                    unknownReasons: unknownReasons.union(other.unknownReasons))
        let spellings = (Array(atoms) + Array(other.atoms)).compactMap { atom -> String? in
            if case let .literal(.string(value)) = atom { return value }
            return nil
        }
        let normalized = Dictionary(grouping: spellings, by: { $0 })
        if normalized.values.contains(where: { group in
            guard let first = group.first else { return false }
            return group.dropFirst().contains { !first.utf8.elementsEqual($0.utf8) }
        }) { result.unknownReasons.insert("unicode-normalization") }
        let (originLimit, overflow) = limit.multipliedReportingOverflow(by: 4)
        if !overflow && result.origins.count > originLimit {
            result.origins = []
            result.unknownReasons.insert("origin-budget")
        }
        if result.atoms.count > limit {
            result.atoms = []
            result.unknownReasons.insert("value-budget")
        }
        return result
    }
}

/// 어떤 호출의 인자/반환인지 명시한다. 같은 함수의 서로 다른 호출은 별도 문맥이다.
public struct ValueFlowContextResult: Sendable, Codable {
    public let id: String
    public let function: String
    public let symbolUSR: String?
    public let callSite: SourceLocation?
    public let caller: String?
    public let callers: [String]
    public let effects: [ValueFlowMemoryEffect]
    public let reason: String
    public let arguments: [ValueFlowValue]
    public let result: ValueFlowValue
    public let mayReturn: Bool

    /// 호출자와 효과의 순서를 고정해 같은 분석의 출력이 달라지지 않게 한다.
    public init(id: String, function: String, symbolUSR: String?, callSite: SourceLocation?, caller: String?,
                reason: String, arguments: [ValueFlowValue], result: ValueFlowValue, mayReturn: Bool,
                callers: [String] = [], effects: [ValueFlowMemoryEffect] = []) {
        self.id = id
        self.function = function
        self.symbolUSR = symbolUSR
        self.callSite = callSite
        self.caller = caller
        self.callers = callers.sorted()
        self.effects = effects.sorted { $0.address < $1.address }
        self.reason = reason
        self.arguments = arguments
        self.result = result
        self.mayReturn = mayReturn
    }
}

/// 호출 전후의 메모리 값을 비교해 inout·필드·전역 상태의 부수 효과를 드러낸다.
public struct ValueFlowMemoryEffect: Sendable, Codable {
    public let address: String
    public let fieldUSR: String?
    public let before: ValueFlowValue?
    public let after: ValueFlowValue
    public let escaped: Bool

    /// 새 저장소의 이전 값 부재와 실제 변경 전후를 구별한다.
    public init(address: String, fieldUSR: String?, before: ValueFlowValue?, after: ValueFlowValue, escaped: Bool) {
        self.address = address
        self.fieldUSR = fieldUSR
        self.before = before
        self.after = after
        self.escaped = escaped
    }
}

/// 값 노드는 호출 문맥을 포함한다. 기존 심볼 정점의 dependsOn 의미를 바꾸지 않는다.
public struct ValueFlowGraphNode: Sendable, Codable {
    public let id: String
    public let context: String
    public let function: String
    public let instruction: Int
    public let kind: String
    public let location: SourceLocation
    public let value: ValueFlowValue

    /// 값을 심볼 전체가 아니라 특정 호출 문맥의 명령에 귀속한다.
    public init(id: String, context: String, function: String, instruction: Int, kind: String,
                location: SourceLocation, value: ValueFlowValue) {
        self.id = id
        self.context = context
        self.function = function
        self.instruction = instruction
        self.kind = kind
        self.location = location
        self.value = value
    }
}

/// 문맥이 맞는 인자·반환·메모리 연결의 근거를 보관한다.
public struct ValueFlowGraphEdge: Hashable, Sendable, Codable {
    public let source: String
    public let target: String
    public let kind: String

    /// 인자·반환·메모리 관계를 출력 단계까지 구별한다.
    public init(source: String, target: String, kind: String) {
        self.source = source
        self.target = target
        self.kind = kind
    }
}

/// 함수 간 분석의 산출물. 미상/예산 초과를 모든 소비자가 함께 볼 수 있다.
public struct ValueFlowGraph: Sendable, Codable {
    public let contexts: [ValueFlowContextResult]
    public let nodes: [ValueFlowGraphNode]
    public let edges: [ValueFlowGraphEdge]
    public let limitations: [String]
    public let iterations: Int
    public let truncated: Bool

    /// 불완전성 정보가 부분 그래프와 분리되어 유실되지 않게 한다.
    public init(contexts: [ValueFlowContextResult], nodes: [ValueFlowGraphNode], edges: [ValueFlowGraphEdge],
                limitations: [String], iterations: Int, truncated: Bool) {
        self.contexts = contexts
        self.nodes = nodes
        self.edges = edges
        self.limitations = limitations
        self.iterations = iterations
        self.truncated = truncated
    }
}

extension ValueFlowLiteral {
    /// 길이 접두사를 사용해 값 안의 구분자가 정렬/문맥 키 충돌을 만들지 않게 한다.
    public var stableKey: String {
        switch self {
        case let .string(value): "s\(value.utf8.count):\(value)"
        case let .integer(value): "i\(value)"
        case let .boolean(value): value ? "b1" : "b0"
        case .null: "n"
        case .unit: "u"
        }
    }
}

extension ValueFlowAtom {
    /// 집합 순서와 프로세스별 Hashable 시드가 출력이나 문맥 발견 순서를 바꾸지 않게 한다.
    public var stableKey: String {
        switch self {
        case let .literal(value): "l" + value.stableKey
        case let .reference(value): "r\(value.utf8.count):\(value)"
        case let .function(value): "f\(value.utf8.count):\(value)"
        case let .type(value): "t\(value.utf8.count):\(value)"
        case let .object(id, type): "o\(id.utf8.count):\(id)\(type.utf8.count):\(type)"
        }
    }
}

extension ValueFlowValue {
    private enum CodingKeys: String, CodingKey { case atoms, origins, unknownReasons }

    /// JSON 집합은 반드시 정렬한다. sortedKeys만으로 배열 순서는 고정되지 않는다.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(atoms.sorted { $0.stableKey < $1.stableKey }, forKey: .atoms)
        let sortedOrigins = origins.sorted {
            if $0.id != $1.id { return $0.id < $1.id }
            if $0.location.path != $1.location.path { return $0.location.path < $1.location.path }
            if $0.location.line != $1.location.line { return $0.location.line < $1.location.line }
            if $0.location.column != $1.location.column { return $0.location.column < $1.location.column }
            return ($0.literal?.stableKey ?? "") < ($1.literal?.stableKey ?? "")
        }
        try container.encode(sortedOrigins, forKey: .origins)
        try container.encode(unknownReasons.sorted(), forKey: .unknownReasons)
    }

    /// 직렬화된 값 종류와 미상 이유를 복원한다.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        atoms = Set(try container.decode([ValueFlowAtom].self, forKey: .atoms))
        origins = Set(try container.decode([ValueFlowOrigin].self, forKey: .origins))
        unknownReasons = Set(try container.decode([String].self, forKey: .unknownReasons))
    }
}
