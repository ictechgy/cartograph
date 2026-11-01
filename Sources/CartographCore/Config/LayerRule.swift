import Foundation

/// 레이어 패턴을 정점의 어느 문자열에 대조할지.
public enum LayerMatchTarget: String, Codable, Sendable, CaseIterable, Comparable {
    /// 정점 이름과 정규화 이름(`Module.Type.member`).
    case name
    /// 정점이 속한 모듈 이름.
    case module
    /// 선언이 있는 파일 경로. 절대 경로와 프로젝트 기준 상대 경로를 모두 본다.
    case path

    public static func < (lhs: LayerMatchTarget, rhs: LayerMatchTarget) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }
}

/// 아키텍처 레이어 정의.
///
/// 레이어는 모듈/타입/파일 이름에 대한 글롭 집합이다. 정점이 어느 레이어에
/// 속하는지는 기본적으로 이름과 파일 경로 모두로 판단한다.
public struct LayerDefinition: Sendable, Codable, Equatable {
    public let name: String
    public let patterns: [GlobPattern]
    /// 패턴을 대조할 대상(`match_on`). nil 이면 이름·모듈·경로를 모두 본다.
    ///
    /// 디렉터리를 뜻한 패턴이 타입 이름에도 걸리면 그 타입이 엉뚱한 레이어로 끌려가고, 먼저 정의된
    /// 레이어가 이기므로 원래 레이어의 정당한 의존이 위반으로 보고된다. 대상을 좁히면 패턴의 의도가
    /// 설정에 남는다. 적지 않은 설정은 예전과 같은 답을 내야 하므로 기본은 전부다.
    public let matchTargets: [LayerMatchTarget]?

    public init(name: String, patterns: [GlobPattern], matchTargets: [LayerMatchTarget]? = nil) {
        self.name = name
        self.patterns = patterns
        // 순서와 중복은 뜻이 없다. 같은 설정이 같은 값으로 비교·직렬화되도록 여기서 정규화한다.
        self.matchTargets = matchTargets.map { Array(Set($0)).sorted() }
    }

    /// 주어진 후보 문자열들(정점 이름, 모듈명, 파일 경로) 중 하나라도 일치하면 참.
    ///
    /// 후보는 이미 `matchTargets` 로 고른 것이어야 한다. 문자열만으로는 그것이 이름인지 경로인지
    /// 알 수 없다 — 대상별 후보를 고르는 일은 `LayerRuleEvaluator` 가 한다.
    public func matches(candidates: [String]) -> Bool {
        candidates.contains { patterns.matchesAny($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case patterns = "match"
        case matchTargets = "match_on"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 값을 비운 `match_on:` 은 YAML 에서 null 이다. 빈 목록처럼 거부한다 — null 을 "전부"로 받으면 지우다 만
        // 줄 하나가 대상을 좁히려던 레이어를 조용히 예전 판정으로 되돌린다.
        if container.contains(.matchTargets), try container.decodeNil(forKey: .matchTargets) {
            throw DecodingError.dataCorruptedError(
                forKey: .matchTargets, in: container, debugDescription: Self.emptyMatchTargetsReason
            )
        }
        let raw: [String]?
        // `match_on: path` 처럼 하나만 적는 경우가 가장 흔하다. 목록만 받으면 그 한 줄이 타입 오류가 된다.
        if let single = try? container.decodeIfPresent(String.self, forKey: .matchTargets) {
            raw = [single]
        } else {
            raw = try container.decodeIfPresent([String].self, forKey: .matchTargets)
        }
        // 열거형으로 바로 풀면 오타가 "올바르지 않은 값" 한 줄로 끝난다. 쓸 수 있는 값을 함께 알려 준다.
        let targets = try raw?.map { value in
            guard let target = LayerMatchTarget(rawValue: value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .matchTargets, in: container,
                    debugDescription: "unknown match_on value '\(value)'; use name, module or path"
                )
            }
            return target
        }
        // 빈 목록은 어떤 정점에도 맞지 않는 레이어가 된다. 규칙은 그 레이어를 조용히 비운 채 통과한다.
        if let targets, targets.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .matchTargets, in: container, debugDescription: Self.emptyMatchTargetsReason
            )
        }
        self.init(
            name: try container.decode(String.self, forKey: .name),
            patterns: try container.decode([GlobPattern].self, forKey: .patterns),
            matchTargets: targets
        )
    }

    /// 대상이 하나도 없는 레이어를 거부하는 이유. 디코딩과 설정 검증이 같은 문장을 쓴다.
    static let emptyMatchTargetsReason = "match_on must list at least one of name, module, path"

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(patterns, forKey: .patterns)
        // 지정하지 않은 레이어는 예전과 같은 바이트로 직렬화한다.
        try container.encodeIfPresent(matchTargets, forKey: .matchTargets)
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
