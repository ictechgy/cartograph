import CartographAnalysis
import CartographCore

/// 자동 발견 범위와 미해결 경계를 함께 제공한다. 코드 라인 커버리지와는 다른 측정값이다.
public struct RuntimeDiscoveryDocument: Codable, Sendable, Equatable {
    public let format: String
    public let version: Int
    public let status: String
    public let scope: String
    public let scannedFiles: Int
    public let boundaryCount: Int
    public let connectionCount: Int
    public let unresolvedCount: Int
    public let countsByStatus: [String: Int]
    public let findings: [Finding]
    public let limitations: [String]
    public let truncated: Bool

    /// 원시 구문 후보를 실제 선언과 연결한 출처를 사람이 검토할 수 있게 한다.
    public struct Finding: Codable, Sendable, Equatable {
        public let id: String
        public let kind: RuntimeBoundaryKind
        public let api: String
        public let location: SourceLocation
        public let name: String?
        public let nameOrigin: RuntimeNameOrigin
        public let status: RuntimeDiscoveryStatus
        public let source: SymbolQuery.Subject?
        public let targets: [SymbolQuery.Subject]
        public let targetsOmitted: Int?
        public let candidates: [SymbolQuery.Subject]
        public let candidatesOmitted: Int?
        public let reason: String?
    }

    init(report: RuntimeDiscoveryReport?, files: [RuntimeFileFacts]?, graph: CodeGraph,
         limitations: [String], limit: Int) {
        format = "runtime-discovery"
        version = 1
        scope = "supported patterns in the built configuration; static evidence is not execution coverage"
        scannedFiles = files?.count ?? 0
        let all = report?.findings ?? []
        boundaryCount = all.count
        connectionCount = report?.connections.count ?? 0
        let unresolved: Set<RuntimeDiscoveryStatus> = [.unresolved, .ambiguous, .dynamic, .stale, .unindexed]
        unresolvedCount = all.count { unresolved.contains($0.status) }
        countsByStatus = Dictionary(grouping: all, by: { $0.status.rawValue }).mapValues(\.count)
        status = report == nil ? "unavailable"
            : (unresolvedCount > 0 || !(report?.limitations.isEmpty ?? true) ? "needsReview" : "analyzed")
        var remainingTargets = limit
        var remainingCandidates = limit
        findings = all.prefix(limit).map { entry in
            let targets = entry.targets.prefix(remainingTargets).compactMap { graph.node($0) }
            let candidates = entry.candidates.prefix(remainingCandidates).compactMap { graph.node($0) }
            remainingTargets -= targets.count
            remainingCandidates -= candidates.count
            let targetsOmitted = entry.targets.count - targets.count
            let candidatesOmitted = entry.candidates.count - candidates.count
            return Finding(id: entry.boundary.id, kind: entry.boundary.kind, api: entry.boundary.api,
                location: entry.boundary.location, name: entry.boundary.name, nameOrigin: entry.boundary.nameOrigin,
                status: entry.status, source: entry.source.flatMap { graph.node($0) }.map(SymbolQuery.Subject.init),
                targets: targets.map(SymbolQuery.Subject.init), targetsOmitted: targetsOmitted > 0 ? targetsOmitted : nil,
                candidates: candidates.map(SymbolQuery.Subject.init),
                candidatesOmitted: candidatesOmitted > 0 ? candidatesOmitted : nil, reason: entry.reason)
        }
        truncated = all.count > findings.count || findings.contains {
            ($0.targetsOmitted ?? 0) > 0 || ($0.candidatesOmitted ?? 0) > 0
        }
        self.limitations = Array(Set(limitations + (report?.limitations ?? [])
            + (report == nil ? ["runtime-discovery-unavailable: no automatic discovery input was captured"] : [])))
            .sorted()
    }
}
