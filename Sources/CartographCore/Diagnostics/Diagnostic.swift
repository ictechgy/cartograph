/// 사용자에게 보고할 문제 하나.
///
/// 모든 분석 명령(cycles/dead/metrics/rules)이 같은 타입으로 결과를 내보내므로,
/// 리포터는 명령의 종류를 몰라도 출력 형식만 책임지면 된다.
public struct Diagnostic: Hashable, Sendable, Codable {
    public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
        case info
        case warning
        case error

        private var rank: Int {
            switch self {
            case .info: 0
            case .warning: 1
            case .error: 2
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    /// 규칙 식별자. 베이스라인과 CI 필터링의 키가 된다. 예: `cycle`, `unused-symbol`.
    public let ruleIdentifier: String
    public let severity: Severity
    public let message: String
    public let location: SourceLocation?
    /// 베이스라인 대조에 쓰는 안정적인 키. 심볼이면 USR, 그 외에는 정점 식별자.
    public let subject: String?
    /// 리포터가 추가로 보여 줄 수 있는 부가 정보. 순서를 고정해 출력 결정성을 지킨다.
    public let details: [String]

    public init(
        ruleIdentifier: String,
        severity: Severity,
        message: String,
        location: SourceLocation? = nil,
        subject: String? = nil,
        details: [String] = []
    ) {
        self.ruleIdentifier = ruleIdentifier
        self.severity = severity
        self.message = message
        self.location = location
        self.subject = subject
        self.details = details
    }

    /// 베이스라인 대조용 지문.
    ///
    /// 줄 번호는 코드가 조금만 움직여도 바뀌므로 일부러 제외한다.
    /// Periphery 가 USR 만으로 베이스라인을 관리한 것과 같은 이유다.
    public var fingerprint: String {
        "\(ruleIdentifier)|\(subject ?? message)"
    }

    /// 기준 경로 기준 상대 경로로 위치를 바꾼 복사본.
    public func relative(to base: String) -> Diagnostic {
        Diagnostic(
            ruleIdentifier: ruleIdentifier,
            severity: severity,
            message: message,
            location: location?.relative(to: base),
            subject: subject,
            details: details
        )
    }
}

extension Diagnostic: Comparable {
    /// 출력 순서를 고정하기 위한 정렬 기준.
    public static func < (lhs: Diagnostic, rhs: Diagnostic) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        if lhs.ruleIdentifier != rhs.ruleIdentifier { return lhs.ruleIdentifier < rhs.ruleIdentifier }
        switch (lhs.location, rhs.location) {
        case let (left?, right?) where left != right:
            return left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return lhs.message < rhs.message
        }
    }
}
