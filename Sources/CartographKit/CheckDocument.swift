import CartographCore

/// 한 번의 CI 점검에서 네 분석 결과와 공통 진단을 묶는다.
public struct CheckDocument: Sendable, Equatable, Codable {
    /// 교환 형식 이름.
    public let format: String
    /// 교환 형식 버전.
    public let version: Int
    /// 분석별 요약. 순서는 dead, module cycles, type cycles, rules로 고정한다.
    public let checks: [Check]
    /// 베이스라인 적용 후 모든 진단을 정렬한 목록.
    public let diagnostics: [Diagnostic]
    /// 전체 실행에 한 번만 붙이는 분석 한계.
    public let limitations: [String]
    /// 임계값을 넘은 분석별 사유.
    public let thresholdFailures: [ThresholdFailure]
    /// 모든 분석의 보고된 진단 수.
    public let findingCount: Int
    /// 베이스라인으로 가려진 진단 수.
    public let suppressedCount: Int
    /// 출력 한도 적용 전의 전체 진단 수.
    public let diagnosticCount: Int
    /// 진단 목록이 출력 한도로 잘렸는지 여부.
    public let truncated: Bool

    /// 분석 하나의 비용·결과 요약.
    public struct Check: Sendable, Equatable, Codable {
        public let name: String
        public let level: String
        public let nodeCount: Int
        public let edgeCount: Int
        public let findingCount: Int
        public let suppressedCount: Int

        public init(
            name: String,
            level: String,
            nodeCount: Int,
            edgeCount: Int,
            findingCount: Int,
            suppressedCount: Int
        ) {
            self.name = name
            self.level = level
            self.nodeCount = nodeCount
            self.edgeCount = edgeCount
            self.findingCount = findingCount
            self.suppressedCount = suppressedCount
        }
    }

    /// 임계값 하나가 실패한 이유.
    public struct ThresholdFailure: Sendable, Equatable, Codable {
        public let name: String
        public let level: String
        public let rule: String
        public let message: String

        public init(name: String, level: String, rule: String, message: String) {
            self.name = name
            self.level = level
            self.rule = rule
            self.message = message
        }
    }

    public init(
        checks: [Check],
        diagnostics: [Diagnostic],
        limitations: [String],
        thresholdFailures: [ThresholdFailure],
        findingCount: Int,
        suppressedCount: Int,
        diagnosticCount: Int? = nil,
        truncated: Bool = false
    ) {
        format = "project-check"
        version = 1
        self.checks = checks
        self.diagnostics = diagnostics
        self.limitations = limitations
        self.thresholdFailures = thresholdFailures
        self.findingCount = findingCount
        self.suppressedCount = suppressedCount
        self.diagnosticCount = diagnosticCount ?? diagnostics.count
        self.truncated = truncated
    }

    /// 진단 출력만 제한하고 검사별 집계와 임계값 정보는 보존한다.
    public func bounded(to limit: Int) -> CheckDocument {
        let diagnostics = Array(self.diagnostics.prefix(max(0, limit)))
        return CheckDocument(
            checks: checks,
            diagnostics: diagnostics,
            limitations: limitations,
            thresholdFailures: thresholdFailures,
            findingCount: findingCount,
            suppressedCount: suppressedCount,
            diagnosticCount: diagnosticCount,
            truncated: truncated || diagnostics.count < self.diagnostics.count
        )
    }
}
