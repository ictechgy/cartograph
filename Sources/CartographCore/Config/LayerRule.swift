/// 아키텍처 레이어 정의.
///
/// 레이어는 모듈/타입/파일 이름에 대한 글롭 집합이다. 정점이 어느 레이어에
/// 속하는지는 이름과 파일 경로 모두로 판단한다.
public struct LayerDefinition: Sendable, Codable, Equatable {
    public let name: String
    public let patterns: [GlobPattern]

    public init(name: String, patterns: [GlobPattern]) {
        self.name = name
        self.patterns = patterns
    }

    /// 주어진 후보 문자열들(정점 이름, 모듈명, 파일 경로) 중 하나라도 일치하면 참.
    public func matches(candidates: [String]) -> Bool {
        candidates.contains { patterns.matchesAny($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case patterns = "match"
    }
}

/// 레이어 사이의 의존 규칙.
///
/// ArchUnit 과 dependency-cruiser 에서 검증된 모델을 따른다.
/// - `allow` 만 있으면 화이트리스트(그 외 모든 의존이 위반)
/// - `deny` 만 있으면 블랙리스트(명시된 의존만 위반)
/// - 둘 다 있으면 `deny` 를 먼저 적용한 뒤 `allow` 를 확인한다.
public struct LayerRule: Sendable, Codable, Equatable {
    public let name: String?
    /// 규칙이 적용되는 출발 레이어 이름.
    public let from: String
    /// 허용되는 도착 레이어 이름 목록. nil 이면 화이트리스트를 쓰지 않는다.
    public let allow: [String]?
    /// 금지되는 도착 레이어 이름 목록.
    public let deny: [String]?
    public let severity: Diagnostic.Severity

    public init(
        name: String? = nil,
        from: String,
        allow: [String]? = nil,
        deny: [String]? = nil,
        severity: Diagnostic.Severity = .error
    ) {
        self.name = name
        self.from = from
        self.allow = allow
        self.deny = deny
        self.severity = severity
    }

    /// 사람이 읽는 규칙 이름. 지정하지 않으면 내용으로 만들어 준다.
    public var displayName: String {
        if let name { return name }
        if let deny, !deny.isEmpty { return "\(from) must not depend on \(deny.joined(separator: ", "))" }
        if let allow { return "\(from) may only depend on \(allow.isEmpty ? "nothing" : allow.joined(separator: ", "))" }
        return "\(from) dependency rule"
    }

    /// 출발 레이어에서 도착 레이어로의 의존이 위반인지 판단한다.
    ///
    /// 같은 레이어 안에서의 의존은 언제나 허용한다.
    public func isViolated(from source: String, to target: String) -> Bool {
        guard source == from, source != target else { return false }
        if let deny, deny.contains(target) { return true }
        if let allow { return !allow.contains(target) }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case name, from, allow, deny, severity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name),
            from: try container.decode(String.self, forKey: .from),
            allow: try container.decodeIfPresent([String].self, forKey: .allow),
            deny: try container.decodeIfPresent([String].self, forKey: .deny),
            severity: try container.decodeIfPresent(Diagnostic.Severity.self, forKey: .severity) ?? .error
        )
    }
}
