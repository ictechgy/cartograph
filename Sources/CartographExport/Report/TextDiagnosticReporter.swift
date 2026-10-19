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
        lines += limitationLines(summary.limitations ?? [])
        // 경로·메시지·세부 정보·요약은 분석 대상 저장소가 통제하는 값이다. 기계 형식과 같은 Core 의
        // 필터를 줄마다 지나야 파일 이름의 개행이 위조 진단 줄을 만들지 못하고 ESC·양방향 재정의가
        // 터미널에 닿지 않는다. 합친 뒤 거르면 줄을 나누는 개행까지 사라지므로 합치기 전에 거른다.
        return lines.map { PrintableText.printable($0) }.joined(separator: "\n") + "\n"
    }

    /// 요약 줄 뒤에 붙이는 한계 블록.
    ///
    /// 텍스트가 CI 로그가 실제로 보여 주는 형식이다. 여기 없으면 이 도구가 무엇을 보지
    /// 못했는지는 아무 데도 없는 것과 같고, 게이트는 눈이 먼 채로 통과한다.
    private func limitationLines(_ limitations: [String]) -> [String] {
        guard !limitations.isEmpty else { return [] }
        return ["limitations:"] + limitations.map { "  \($0)" }
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
        let caveat = summary.caveat.map { " (\($0))" } ?? ""
        // 요약 줄만 읽는 사람에게도 뒤에 블록이 있다는 것을 알린다.
        let count = summary.limitations?.count ?? 0
        let limitations = count > 0 ? " (\(count) limitation\(count == 1 ? "" : "s"))" : ""
        return "\(summary.command): \(findings)\(caveat)\(suppressed)\(limitations) — \(summary.subject)"
    }
}
