import CartographCore

extension ImpactDocument {
    /// 터미널에서는 소비자와 바로 앞 근거를 나란히 보여 준다. 긴 경로는 JSON의 via 사슬로 공유한다.
    func renderText() -> String {
        var lines = [
            "impact: \(status) — \(summary.selectedSymbols) selected, \(summary.changeScopeSymbols) in change scope, "
                + "\(summary.affectedSymbols) potential dependents, "
                + "\(summary.testSymbols) test declarations, \(summary.runtimeReviewSymbols) runtime review targets",
        ]
        let names = Dictionary((changeScope + affected.map(\.symbol)).compactMap { symbol in
            symbol.usr.map { ($0, symbol.qualifiedName) }
        }, uniquingKeysWith: { first, _ in first })
        for affected in affected {
            let site = affected.symbol.location.map { "\($0.path):\($0.line) " } ?? ""
            let via = names[affected.via] ?? affected.via
            let contract = affected.dispatchContract.map { " via dispatch contract \($0.qualifiedName)" } ?? ""
            lines.append("  \(site)\(affected.symbol.qualifiedName) ← \(via) "
                + "[depth \(affected.depth), \(affected.relationship): \(affected.edges.joined(separator: ", "))]\(contract)")
        }
        for item in runtimeReview {
            lines.append("  Runtime review: \(item.symbol.qualifiedName) — "
                + (item.reasons.map(\.rawValue) + item.runtimeContracts.map { "contract \($0)" }).joined(separator: ", "))
        }
        for issue in selectionIssues { lines.append("  Unresolved \(issue.kind): \(issue.requested) (\(issue.status))") }
        if let automaticRuntime {
            lines.append("  Automatic runtime: \(automaticRuntime.boundaryCount) related boundaries, "
                + "\(automaticRuntime.connectionCount) connections, \(automaticRuntime.unresolvedCount) unresolved.")
        }
        if let observedRuntime {
            lines.append("  Runtime trace: \(observedRuntime.eventCount) events, "
                + "\(observedRuntime.connectionCount) observed lookup/invocation/registration connections "
                + "(\(observedRuntime.status)).")
        }
        if truncated.depth { lines.append("  Truncated: consumer depth reached; increase --depth or omit it.") }
        if truncated.output {
            lines.append("  Truncated sections: \(truncated.sections.joined(separator: ", ")); "
                + "increase --limit. Summary counts are uncapped.")
        }
        for limitation in limitations { lines.append("  Limitation: \(limitation)") }
        lines.append("Potential impact describes dependencies. Rebuild and run relevant tests after editing; review runtime boundaries.")
        return lines.map { PrintableText.printable($0) }.joined(separator: "\n") + "\n"
    }
}
