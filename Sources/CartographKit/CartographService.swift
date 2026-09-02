import CartographAnalysis
import CartographConfig
import CartographCore
import CartographExport
import CartographIndexStore
import CartographSyntax
import Foundation

/// 설정에서 출력까지의 전체 파이프라인을 조립한다.
///
/// 각 명령은 "그래프를 만들고 → 분석하고 → 베이스라인을 적용하고 → 형식을 입힌다"는
/// 같은 골격을 공유한다. 그 골격을 여기 한 번만 쓰고 명령마다 다른 부분만 갈아 끼운다.
public struct CartographService: Sendable {
    private let configuration: CartographConfiguration
    private let environment: CartographEnvironment

    public init(configuration: CartographConfiguration, environment: CartographEnvironment = .live()) {
        self.configuration = configuration
        self.environment = environment
    }

    /// 분석 대상 프로젝트 루트.
    public var projectPath: String {
        configuration.projectPath ?? environment.fileSystem.currentDirectoryPath
    }

    // MARK: - 인덱스와 그래프

    /// 인덱스를 읽고 구문 정보로 보강한 스냅샷.
    public func loadSnapshot() throws -> IndexSnapshot {
        let provider = try makeIndexProvider()
        let raw = try provider.loadSnapshot()
        return SnapshotEnricher(fileSystem: environment.fileSystem).enrich(raw)
    }

    /// 지정한 해상도의 그래프. 레벨을 주지 않으면 설정값을 쓴다.
    public func buildGraph(level: GraphLevel? = nil, includeExternal: Bool = false) throws
        -> (result: GraphBuilder.BuildResult, snapshot: IndexSnapshot) {
        let snapshot = try loadSnapshot()
        let options = GraphBuilder.Options(
            level: level ?? configuration.level,
            pathFilter: configuration.pathFilter,
            edgeKinds: configuration.edgeKinds,
            includeExternal: includeExternal
        )
        return (GraphBuilder(options: options).buildResult(from: snapshot), snapshot)
    }

    // MARK: - 명령

    /// 그래프를 지정한 형식으로 내보낸다.
    public func renderGraph(level: GraphLevel? = nil, format: GraphFormat? = nil) throws -> CommandOutcome {
        let (result, _) = try buildGraph(level: level)
        let renderer = GraphRendererFactory.make(format ?? configuration.graphFormat)
        return CommandOutcome(output: try renderer.render(result.graph))
    }

    /// 순환 의존성을 찾는다.
    public func detectCycles(level: GraphLevel? = nil) throws -> CommandOutcome {
        let (result, _) = try buildGraph(level: level)
        let cycles = CycleDetector(options: .init(edgeKinds: configuration.edgeKinds))
            .detectCycles(in: result.graph)
        let diagnostics = AnalysisDiagnostics.diagnostics(for: cycles, in: result.graph)

        return try finish(
            diagnostics,
            command: "cycles",
            subject: describe(result.graph),
            thresholdLimit: configuration.thresholds.maxCycles,
            thresholdRule: AnalysisDiagnostics.Rule.cycle
        )
    }

    /// 미사용 선언을 찾는다.
    ///
    /// 데드코드는 반드시 심볼 레벨에서 본다. 모듈이나 파일 단위로는
    /// "이 파일 전체가 안 쓰인다" 정도밖에 말할 수 없다.
    public func detectUnusedCode() throws -> CommandOutcome {
        let (result, snapshot) = try buildGraph(level: .symbol)
        let report = ReachabilityAnalyzer(policy: makeRetentionPolicy())
            .analyze(graph: result.graph, snapshot: snapshot)
        let diagnostics = AnalysisDiagnostics.diagnostics(for: report)

        return try finish(
            diagnostics,
            command: "dead",
            subject: "\(describe(result.graph)) · "
                + "\(report.reachableCount)/\(report.totalCount) reachable",
            thresholdLimit: configuration.thresholds.maxUnusedSymbols,
            thresholdRule: AnalysisDiagnostics.Rule.unusedSymbol
        )
    }

    /// 특정 선언이 왜 살아 있는지 설명한다.
    public func explainRetention(of subject: String) throws -> CommandOutcome {
        let (result, snapshot) = try buildGraph(level: .symbol)
        let graph = result.graph
        let report = ReachabilityAnalyzer(policy: makeRetentionPolicy())
            .analyze(graph: graph, snapshot: snapshot)

        guard let node = Self.findNode(matching: subject, in: graph) else {
            return CommandOutcome(output: "No declaration matches '\(subject)'.\n")
        }

        let name = node.qualifiedName
        switch report.explain(node.id, in: graph) {
        case let .retained(reason):
            return CommandOutcome(output: "\(name) is retained because it is \(reason.explanation).\n")
        case let .reachable(path):
            let trail = path.map { graph.node($0)?.qualifiedName ?? $0.rawValue }.joined(separator: " → ")
            return CommandOutcome(output: "\(name) is reachable:\n  \(trail)\n")
        case .unreachable:
            return CommandOutcome(output: "\(name) is not reachable from any retained root.\n", findingCount: 1)
        case .unknown:
            return CommandOutcome(output: "No declaration matches '\(subject)'.\n")
        }
    }

    /// 아키텍처 지표를 계산한다.
    public func measureMetrics(level: GraphLevel? = nil) throws -> CommandOutcome {
        let (result, snapshot) = try buildGraph(level: level)
        let calculator = ArchitectureMetricsCalculator()
        let metrics = calculator.calculate(result: result, snapshot: snapshot)
        let diagnostics = AnalysisDiagnostics.diagnostics(
            for: metrics,
            thresholds: configuration.thresholds
        )
        let renderer = MetricsRenderer(tolerance: calculator.tolerance)

        let baseline = try loadBaseline()
        let reported = baseline?.filtering(diagnostics) ?? diagnostics
        let suppressed = diagnostics.count - reported.count

        let output: String = switch configuration.reportFormat {
        case .json, .sarif, .checkstyle:
            try renderer.renderJSON(metrics, diagnostics: reported)
        default:
            renderer.renderTable(metrics)
                + (reported.isEmpty
                    ? ""
                    : "\n" + (try DiagnosticReporterFactory.make(.text).report(
                        reported,
                        summary: ReportSummary(
                            command: "metrics",
                            subject: describe(result.graph),
                            suppressedCount: suppressed
                        )
                    )))
        }
        return CommandOutcome(output: output, findingCount: reported.count, suppressedCount: suppressed)
    }

    /// 레이어 규칙 위반을 찾는다.
    public func checkRules(level: GraphLevel? = nil) throws -> CommandOutcome {
        try configuration.validate()
        let (result, _) = try buildGraph(level: level)
        let evaluator = LayerRuleEvaluator(layers: configuration.layers, rules: configuration.rules)
        var diagnostics = AnalysisDiagnostics.diagnostics(for: evaluator.evaluate(graph: result.graph))
        diagnostics += AnalysisDiagnostics.unassignedLayerDiagnostics(
            for: evaluator.unassignedNodes(in: result.graph),
            in: result.graph
        )

        return try finish(
            diagnostics,
            command: "rules",
            subject: describe(result.graph),
            thresholdLimit: configuration.thresholds.maxRuleViolations,
            thresholdRule: AnalysisDiagnostics.Rule.layerViolation,
            // 레이어 미지정은 정보성이라 임계값 계산에 넣지 않는다.
            countedRules: [AnalysisDiagnostics.Rule.layerViolation]
        )
    }

    // MARK: - 공통 마무리

    /// 베이스라인 적용 → 임계값 검사 → 형식 적용.
    private func finish(
        _ diagnostics: [Diagnostic],
        command: String,
        subject: String,
        thresholdLimit: Int?,
        thresholdRule: String,
        countedRules: Set<String>? = nil
    ) throws -> CommandOutcome {
        let baseline = try loadBaseline()
        let reported = baseline?.filtering(diagnostics) ?? diagnostics
        let suppressed = diagnostics.count - reported.count

        let counted = countedRules.map { rules in
            reported.filter { rules.contains($0.ruleIdentifier) }
        } ?? reported

        // 임계값 초과를 여기서 던지면 리포트가 출력되지 않아 무엇이 문제인지 알 수 없다.
        // 사유만 실어 보내고 출력은 그대로 만든다.
        var thresholdFailure: CartographError?
        do {
            try AnalysisDiagnostics.enforceCountThreshold(
                counted.count,
                limit: thresholdLimit,
                rule: thresholdRule
            )
        } catch let error as CartographError {
            thresholdFailure = error
        }

        let reporter = DiagnosticReporterFactory.make(configuration.reportFormat)
        let output = try reporter.report(
            reported.map { $0.relative(to: projectPath) },
            summary: ReportSummary(command: command, subject: subject, suppressedCount: suppressed)
        )
        return CommandOutcome(
            output: output,
            findingCount: counted.count,
            suppressedCount: suppressed,
            thresholdFailure: thresholdFailure
        )
    }

    /// 현재 진단 상태를 베이스라인 파일로 기록한다.
    public func writeBaseline(diagnostics: [Diagnostic], to path: String) throws -> CommandOutcome {
        let baseline = Baseline.capturing(diagnostics)
        try BaselineStore(fileSystem: environment.fileSystem).write(baseline, to: path)
        return CommandOutcome(
            output: "Wrote \(baseline.fingerprints.count) findings to \(path)\n"
        )
    }

    /// 모든 명령의 진단을 모아 베이스라인 후보로 만든다.
    public func collectAllDiagnostics() throws -> [Diagnostic] {
        let (moduleResult, _) = try buildGraph()
        let (symbolResult, snapshot) = try buildGraph(level: .symbol)

        var diagnostics = AnalysisDiagnostics.diagnostics(
            for: CycleDetector().detectCycles(in: moduleResult.graph),
            in: moduleResult.graph
        )
        diagnostics += AnalysisDiagnostics.diagnostics(
            for: ReachabilityAnalyzer(policy: makeRetentionPolicy())
                .analyze(graph: symbolResult.graph, snapshot: snapshot)
        )
        diagnostics += AnalysisDiagnostics.diagnostics(
            for: LayerRuleEvaluator(layers: configuration.layers, rules: configuration.rules)
                .evaluate(graph: moduleResult.graph)
        )
        return diagnostics
    }

    // MARK: - 내부 구현

    /// 설정과 프로젝트 경로를 반영한 보존 규칙.
    private func makeRetentionPolicy() -> RetentionPolicy {
        RetentionPolicy(options: configuration.retention, basePath: projectPath)
    }

    private func loadBaseline() throws -> Baseline? {
        try BaselineStore(fileSystem: environment.fileSystem).loadIfPresent(at: configuration.baselinePath)
    }

    private func describe(_ graph: CodeGraph) -> String {
        "\(graph.level.rawValue) graph · \(graph.nodeCount) nodes · \(graph.edgeCount) edges"
    }

    /// USR 완전 일치를 먼저 보고, 없으면 이름으로 찾는다.
    ///
    /// 사용자는 USR 을 외우지 않는다. 타입 이름으로 물어볼 수 있어야 한다.
    static func findNode(matching subject: String, in graph: CodeGraph) -> GraphNode? {
        if let exact = graph.node(NodeID(subject)) { return exact }
        return graph.sortedNodes.first {
            $0.name == subject || $0.baseName == subject || $0.qualifiedName == subject
        }
    }

    private func makeIndexProvider() throws -> any IndexProviding {
        if let override = environment.indexProviderOverride { return override }

        let locator = IndexStoreLocator(fileSystem: environment.fileSystem)
        let storePath = try locator.locate(
            explicitPath: configuration.indexStorePath,
            projectPath: projectPath,
            derivedDataPath: environment.derivedDataPath
        )
        let libraryPath = try locator.locateLibrary(
            explicitPath: nil,
            developerDirectory: environment.developerDirectory
        )
        return IndexStoreProvider(
            configuration: .init(
                storePath: storePath,
                databasePath: IndexStoreProvider.defaultDatabasePath(
                    forStore: storePath,
                    libraryPath: libraryPath,
                    libraryModificationDate: environment.fileSystem.modificationDate(at: libraryPath)
                ),
                libraryPath: libraryPath,
                sourceRoots: [projectPath],
                pathFilter: configuration.pathFilter
            ),
            fileSystem: environment.fileSystem
        )
    }
}
