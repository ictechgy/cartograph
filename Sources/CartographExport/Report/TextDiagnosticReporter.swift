import CartographCore

/// 사람이 읽는 기본 형식.
///
/// 문제가 없을 때도 무엇을 검사했는지 한 줄로 알려 준다.
/// "아무것도 출력되지 않음"은 통과와 오작동을 구분할 수 없기 때문이다.
public struct TextDiagnosticReporter: DiagnosticReporting {
    public init() {}

    public func report(_ diagnostics: [Diagnostic], summary: ReportSummary) -> String {
        var lines: [String] = []
        for diagnostic in diagnostics.sorted() {
            let location = diagnostic.location.map { "\($0.description): " } ?? ""
            lines.append("\(location)\(diagnostic.severity.rawValue): \(diagnostic.message)")
            lines.append(contentsOf: diagnostic.details.map { "    \($0)" })
        }

        lines.append("")
        lines.append(summaryLine(diagnostics, summary: summary))
        return lines.joined(separator: "\n") + "\n"
    }

    private func summaryLine(_ diagnostics: [Diagnostic], summary: ReportSummary) -> String {
        let counts = Diagnostic.Severity.allCases.reversed().compactMap { severity -> String? in
            let count = diagnostics.filter { $0.severity == severity }.count
            return count > 0 ? "\(count) \(severity.rawValue)\(count == 1 ? "" : "s")" : nil
        }
        let findings = counts.isEmpty ? "no findings" : counts.joined(separator: ", ")
        let suppressed = summary.suppressedCount > 0
            ? " (\(summary.suppressedCount) suppressed by baseline)"
            : ""
        return "\(summary.command): \(findings)\(suppressed) — \(summary.subject)"
    }
}
