import CartographCore

/// 진단 배열만 집계하며 파일명, 생성 코드 여부, 보존 정책을 해석하지 않는다.
public enum FindingFileSummarizer {
    /// 많이 보고된 파일부터 보여 주되 생략 수와 위치 없는 진단을 따로 보존한다.
    public static func summarize(_ diagnostics: [Diagnostic], maximumFiles: Int = 200) throws
        -> FindingReviewDocument {
        guard (1...10_000).contains(maximumFiles) else {
            throw CartographError.invalidConfiguration(path: "finding-summary",
                reason: "Finding summary file limit must be between 1 and 10000.")
        }
        var counts: [String: Counts] = [:]
        var unlocated = 0
        for diagnostic in diagnostics {
            guard let path = diagnostic.location?.path, !path.isEmpty else { unlocated += 1; continue }
            counts[path, default: Counts()].add(diagnostic)
        }
        let files = counts.map { path, count in
            FindingFileSummary(path: path, findingCount: count.total,
                ruleCounts: count.rules, severityCounts: count.severities)
        }.sorted {
            $0.findingCount == $1.findingCount ? $0.path < $1.path : $0.findingCount > $1.findingCount
        }
        return .init(diagnostics: diagnostics, files: Array(files.prefix(maximumFiles)), totalFileCount: files.count,
            unlocatedFindingCount: unlocated,
            limitations: files.count > maximumFiles
                ? ["finding-summary-limit: \(files.count - maximumFiles) file summaries omitted; "
                    + "all findings preserved."]
                : [])
    }

    private struct Counts {
        var total = 0
        var rules: [String: Int] = [:]
        var severities: [String: Int] = [:]

        mutating func add(_ diagnostic: Diagnostic) {
            total += 1
            rules[diagnostic.ruleIdentifier, default: 0] += 1
            severities[diagnostic.severity.rawValue, default: 0] += 1
        }
    }
}
