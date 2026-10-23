import CartographAnalysis
import CartographCore
import CartographExport

extension CartographService {
    /// 하나의 분석 문맥에서 CI에 필요한 네 점검을 모두 실행한다.
    ///
    /// 모듈·타입 순환을 별도 그래프로 확인하고, 베이스라인은 전체 결과에 한 번만 적용한다.
    /// `--since` 범위는 각 진단의 위치에만 적용되며 그래프 자체를 좁히지 않는다. 순환만은 `cycles` 와
    /// 같이 구성원 파일로 판정한다(`scopedCycleDiagnostics`).
    ///
    /// 세션 세대 문맥이면 같은 세대의 점검 결과를 한 번만 만든다(`generationCheck`). 한계는 스토어 시각까지
    /// 키로 보는 한계 캐시에서 따로 받아, 다른 도구의 응답과 같은 목록을 싣는다.
    public func checkDocument(in existingContext: AnalysisContext? = nil) throws -> CheckDocument {
        let context = try existingContext ?? loadContext()
        let findings = try context.generationCheck { try checkFindings(in: context) }
        var limitations = analysisLimitations(context: context, symbolGraph: context.buildGraph(level: .symbol).graph)
        limitations += Set([GraphLevel.module, configuration.level]).sorted { $0.rawValue < $1.rawValue }
            .flatMap { context.buildGraph(level: $0).sourceAttributionLimitations }
        if reportScope != nil {
            limitations.append("scoped-diagnostics: this check reports a selected file scope, not every finding; "
                + "run check without --since for a full CI gate")
        }
        return CheckDocument(
            checks: findings.checks,
            diagnostics: findings.diagnostics,
            limitations: limitations,
            thresholdFailures: findings.thresholdFailures,
            findingCount: findings.findingCount,
            suppressedCount: findings.suppressedCount
        )
    }

    /// 베이스라인을 적용한 네 점검의 결과. 한계 목록은 담지 않는다.
    private func checkFindings(in context: AnalysisContext) throws -> CheckFindings {
        let baseline = try loadBaseline()
        let dead = unusedCode(in: context, computingSuperfluousIgnores: false)
        let moduleCycles = cycles(in: context, level: .module)
        let typeCycles = cycles(in: context, level: .type)
        let rules = try layerViolations(in: context, level: configuration.level)

        let results = [
            checked(
                name: "dead", level: .symbol, graph: dead.graph,
                diagnostics: AnalysisDiagnostics.diagnostics(for: dead.report),
                countedRules: [AnalysisDiagnostics.Rule.unusedSymbol],
                threshold: configuration.thresholds.maxUnusedSymbols,
                baseline: baseline
            ),
            checked(
                name: "cycles", level: .module, graph: moduleCycles.graph,
                diagnostics: scopedCycleDiagnostics(moduleCycles.cycles, level: .module, context: context),
                threshold: configuration.thresholds.maxCycles,
                baseline: baseline, alreadyScoped: true
            ),
            checked(
                name: "cycles", level: .type, graph: typeCycles.graph,
                diagnostics: scopedCycleDiagnostics(typeCycles.cycles, level: .type, context: context),
                threshold: configuration.thresholds.maxCycles,
                baseline: baseline, alreadyScoped: true
            ),
            checked(
                name: "rules", level: configuration.level, graph: rules.graph,
                diagnostics: AnalysisDiagnostics.diagnostics(for: rules.violations)
                    + AnalysisDiagnostics.unassignedLayerDiagnostics(for: rules.unassigned, in: rules.graph),
                countedRules: [AnalysisDiagnostics.Rule.layerViolation],
                threshold: configuration.thresholds.maxRuleViolations,
                baseline: baseline
            ),
        ]
        let baseVariants = PathFilter.variants(of: projectPath)
        let diagnostics = results.flatMap(\.reported).sorted().map { $0.relative(toBaseVariants: baseVariants) }
        return CheckFindings(
            checks: results.map(\.summary),
            diagnostics: diagnostics,
            thresholdFailures: results.compactMap(\.thresholdFailure),
            findingCount: results.reduce(0) { $0 + $1.summary.findingCount },
            suppressedCount: results.reduce(0) { $0 + $1.summary.suppressedCount }
        )
    }

    /// 통합 점검을 선택한 리포트 형식으로 출력한다.
    public func check() throws -> CommandOutcome {
        let document = try checkDocument()
        let output: String
        if configuration.reportFormat == .json {
            output = try Self.encodeSortedJSON(document)
        } else {
            let summary = ReportSummary(
                command: "check",
                subject: "project check",
                suppressedCount: document.suppressedCount,
                limitations: document.limitations.isEmpty ? nil : document.limitations
            )
            output = try DiagnosticReporterFactory.make(configuration.reportFormat)
                .report(document.diagnostics, summary: summary)
        }
        let thresholdFailure = document.thresholdFailures.first.map {
            CartographError.thresholdExceeded(rule: $0.rule, message: $0.message)
        }
        return CommandOutcome(
            output: output,
            findingCount: document.findingCount,
            suppressedCount: document.suppressedCount,
            thresholdFailure: thresholdFailure
        )
    }

    private struct CheckedResult {
        let summary: CheckDocument.Check
        let reported: [Diagnostic]
        let thresholdFailure: CheckDocument.ThresholdFailure?
    }

    private func checked(
        name: String,
        level: GraphLevel,
        graph: CodeGraph,
        diagnostics: [Diagnostic],
        countedRules: Set<String> = [],
        threshold: Int?,
        baseline: Baseline?,
        alreadyScoped: Bool = false
    ) -> CheckedResult {
        let scoped = alreadyScoped ? diagnostics : (reportScope?.filtering(diagnostics) ?? diagnostics)
        let reported = baseline?.filtering(scoped) ?? scoped
        let suppressed = scoped.count - reported.count
        let counted = countedRules.isEmpty
            ? reported
            : reported.filter { countedRules.contains($0.ruleIdentifier) }
        let failure: CheckDocument.ThresholdFailure?
        if let threshold, counted.count > threshold {
            failure = .init(
                name: name,
                level: level.rawValue,
                rule: thresholdRule(name: name),
                message: "found \(counted.count), allowed at most \(threshold)"
            )
        } else {
            failure = nil
        }
        return CheckedResult(
            summary: .init(
                name: name,
                level: level.rawValue,
                nodeCount: graph.nodeCount,
                edgeCount: graph.edgeCount,
                findingCount: counted.count,
                suppressedCount: suppressed
            ),
            reported: reported,
            thresholdFailure: failure
        )
    }

    private func thresholdRule(name: String) -> String {
        switch name {
        case "dead": AnalysisDiagnostics.Rule.unusedSymbol
        case "cycles": AnalysisDiagnostics.Rule.cycle
        case "rules": AnalysisDiagnostics.Rule.layerViolation
        default: name
        }
    }
}

/// 통합 점검에서 한계 목록을 뺀 결과. 세션 세대가 이것만 담아 두고 요청마다 한계를 붙여 문서로 만든다.
///
/// 한계는 스토어 시각까지 키로 보는 별도 캐시를 거친다. 점검 결과와 한 덩어리로 담으면 스토어 시각이 바뀐
/// 뒤 점검 응답만 지난 한계를 싣는다.
struct CheckFindings: Sendable {
    let checks: [CheckDocument.Check]
    let diagnostics: [Diagnostic]
    let thresholdFailures: [CheckDocument.ThresholdFailure]
    let findingCount: Int
    let suppressedCount: Int
}
