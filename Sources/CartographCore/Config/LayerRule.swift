import Foundation

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
    /// 이 규칙이 왜 있는지. 위반 진단의 `details` 에 그대로 실린다.
    ///
    /// 위반만 알리면 읽는 쪽(특히 코딩 에이전트)은 규칙을 우회하는 가장 짧은 편집을
    /// 고른다. 팀이 적은 이유가 함께 가야 그 의도에 맞는 수정을 고를 수 있다.
    public let rationale: String?
    /// 위반을 어떻게 고치는지에 대한 팀의 안내. 위반 진단의 `details` 에 실린다.
    public let hint: String?

    public init(
        name: String? = nil,
        from: String,
        allow: [String]? = nil,
        deny: [String]? = nil,
        severity: Diagnostic.Severity = .error,
        rationale: String? = nil,
        hint: String? = nil
    ) {
        self.name = name
        self.from = from
        self.allow = allow
        self.deny = deny
        self.severity = severity
        // 설정 파일이든 코드든 같은 불변식을 지키도록 정규화는 여기 한 곳에서 한다.
        self.rationale = Self.singleLine(rationale)
        self.hint = Self.singleLine(hint)
    }

    /// 위반 진단에 붙일 설명 줄. 규칙 이름, 그리고 적혀 있으면 이유와 수정 안내.
    public var violationDetails: [String] {
        ["rule: \(displayName)"]
            + (rationale.map { ["rationale: \($0)"] } ?? [])
            + (hint.map { ["hint: \($0)"] } ?? [])
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
        case name, from, allow, deny, severity, rationale, hint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name),
            from: try container.decode(String.self, forKey: .from),
            allow: try container.decodeIfPresent([String].self, forKey: .allow),
            deny: try container.decodeIfPresent([String].self, forKey: .deny),
            severity: try container.decodeIfPresent(Diagnostic.Severity.self, forKey: .severity) ?? .error,
            rationale: try container.decodeIfPresent(String.self, forKey: .rationale),
            hint: try container.decodeIfPresent(String.self, forKey: .hint)
        )
    }

    /// 선택 설명 문자열을 한 줄로 정규화한다. 빈 값은 적지 않은 것과 같다.
    ///
    /// 한 줄 진단 형식에 섞여 출력되므로 줄바꿈은 공백으로 접는다. 여러 줄 YAML 블록이나
    /// 여러 줄 문자열 리터럴로 적어도 리포트의 한 줄 구조가 깨지지 않는다.
    private static func singleLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let folded = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return folded.isEmpty ? nil : folded
    }
}
