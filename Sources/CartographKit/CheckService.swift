import CartographAnalysis
import CartographCore
import CartographExport

extension CartographService {
    /// 하나의 분석 문맥에서 CI에 필요한 네 점검을 모두 실행한다.
    ///
    /// 모듈·타입 순환을 별도 그래프로 확인하고, 베이스라인은 전체 결과에 한 번만 적용한다.
    /// `--since` 범위는 각 진단의 위치에만 적용되며 그래프 자체를 좁히지 않는다.
    public func checkDocument(in existingContext: AnalysisContext? = nil) throws -> CheckDocument {
        let context = try existingContext ?? loadContext()
        let baseline = try loadBaseline()
        let dead = unusedCode(in: context)
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
        var limitations = analysisLimitations(context: context, symbolGraph: dead.graph)
        if reportScope != nil {
            limitations.append("scoped-diagnostics: this check reports a selected file scope, not every finding; "
                + "run check without --since for a full CI gate")
        }
        return CheckDocument(
            checks: results.map(\.summary),
            diagnostics: diagnostics,
            limitations: limitations,
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

    /// 순환은 대표 선언 한 줄이 아니라 구성원 전체의 파일로 범위를 판정한다. 익스텐션 멤버도 포함한다.
    private func scopedCycleDiagnostics(
        _ cycles: [DependencyCycle], level: GraphLevel, context: AnalysisContext
    ) -> [Diagnostic] {
        let built = context.buildGraph(level: level)
        guard let reportScope else { return AnalysisDiagnostics.diagnostics(for: cycles, in: built.graph) }
        let includedPaths = Set(context.snapshot.filePaths.filter {
            reportScope.files.contains(ReportScope.normalized($0))
        })
        let touchedNodes = Set(context.snapshot.symbols.filter {
            includedPaths.contains($0.location.path)
        }.compactMap { built.nodeIDByUSR[$0.usr] })
        return AnalysisDiagnostics.diagnostics(for: cycles.filter {
            !$0.component.allSatisfy { !touchedNodes.contains($0) }
        }, in: built.graph)
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
