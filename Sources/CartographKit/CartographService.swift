import CartographAnalysis
import CartographConfig
import CartographCore
import CartographExport
import CartographIndexStore
import CartographSyntax
import Foundation

/// 설정에서 출력까지의 전체 파이프라인을 조립한다.
///
/// 두 층으로 나뉜다.
/// - 질의 API(`cycles(in:)`, `unusedCode(in:)` …)는 값을 그대로 돌려준다.
///   라이브러리로 임베드하는 쪽은 이쪽만 쓰면 된다.
/// - 명령 API(`detectCycles()` …)는 그 위에 베이스라인·임계값·출력 형식을 얹는다.
///   CI 정책이므로 질의 경로에 섞지 않는다.
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

    // MARK: - 인덱스

    /// 인덱스를 읽고 구문 정보로 보강한 스냅샷.
    public func loadSnapshot() throws -> IndexSnapshot {
        let raw = try makeIndexProvider().loadSnapshot()
        return SnapshotEnricher(fileSystem: environment.fileSystem, retention: configuration.retention)
            .enrich(
                raw,
                interfaceBuilderRoots: configuration.retention.retainInterfaceBuilder ? [projectPath] : [],
                pathFilter: configuration.pathFilter
            )
    }

    /// 인덱스를 한 번만 읽어 만든 분석 문맥.
    public func loadContext() throws -> AnalysisContext {
        AnalysisContext(
            snapshot: try loadSnapshot(),
            pathFilter: configuration.pathFilter,
            edgeKinds: configuration.edgeKinds
        )
    }

    // MARK: - 질의 API

    /// 순환 의존성.
    public func cycles(
        in context: AnalysisContext,
        level: GraphLevel? = nil
    ) -> (graph: CodeGraph, cycles: [DependencyCycle]) {
        let graph = context.buildGraph(level: level ?? configuration.level).graph
        let detector = CycleDetector(options: .init(edgeKinds: configuration.edgeKinds))
        return (graph, detector.detectCycles(in: graph))
    }

    /// 미사용 선언. 언제나 심볼 레벨에서 본다.
    ///
    /// 모듈이나 파일 단위로는 "이 파일이 통째로 안 쓰인다" 이상을 말할 수 없다.
    public func unusedCode(in context: AnalysisContext) -> (graph: CodeGraph, report: UnusedCodeReport) {
        let graph = context.buildGraph(level: .symbol).graph
        let analyzer = ReachabilityAnalyzer(policy: makeRetentionPolicy())
        return (graph, analyzer.analyze(graph: graph, snapshot: context.snapshot))
    }

    /// 아키텍처 지표.
    public func metrics(
        in context: AnalysisContext,
        level: GraphLevel? = nil
    ) -> (graph: CodeGraph, metrics: [NodeMetrics], tolerance: Double) {
        let result = context.buildGraph(level: level ?? configuration.level)
        let calculator = ArchitectureMetricsCalculator()
        return (result.graph, calculator.calculate(result: result, snapshot: context.snapshot), calculator.tolerance)
    }

    /// 레이어 규칙 위반과, 어느 레이어에도 속하지 않은 정점.
    public func layerViolations(
        in context: AnalysisContext,
        level: GraphLevel? = nil
    ) throws -> (graph: CodeGraph, violations: [LayerViolation], unassigned: [NodeID]) {
        try configuration.validate()
        let graph = context.buildGraph(level: level ?? configuration.level).graph
        let evaluator = LayerRuleEvaluator(layers: configuration.layers, rules: configuration.rules)
        return (graph, evaluator.evaluate(graph: graph), evaluator.unassignedNodes(in: graph))
    }

    /// 특정 선언이 살아 있는 이유.
    public func retentionExplanation(
        of subject: String,
        in context: AnalysisContext
    ) -> (graph: CodeGraph, lookup: NodeLookup, explanation: ReachabilityExplanation?) {
        let (graph, report) = unusedCode(in: context)
        let lookup = NodeLookup.resolve(subject, in: graph)
        guard case let .found(node) = lookup else { return (graph, lookup, nil) }
        return (graph, lookup, report.explain(node.id, in: graph))
    }

    // MARK: - 명령 API

    /// 그래프를 지정한 형식으로 내보낸다.
    public func renderGraph(level: GraphLevel? = nil, format: GraphFormat? = nil) throws -> CommandOutcome {
        let graph = try loadContext().buildGraph(level: level ?? configuration.level).graph
        let renderer = GraphRendererFactory.make(format ?? configuration.graphFormat)
        return CommandOutcome(output: try renderer.render(graph))
    }

    public func detectCycles(level: GraphLevel? = nil) throws -> CommandOutcome {
        let (graph, cycles) = cycles(in: try loadContext(), level: level)
        return try finish(
            AnalysisDiagnostics.diagnostics(for: cycles, in: graph),
            command: "cycles",
            subject: describe(graph),
            thresholdLimit: configuration.thresholds.maxCycles,
            thresholdRule: AnalysisDiagnostics.Rule.cycle
        )
    }

    public func detectUnusedCode() throws -> CommandOutcome {
        let (graph, report) = unusedCode(in: try loadContext())
        return try finish(
            AnalysisDiagnostics.diagnostics(for: report),
            command: "dead",
            subject: "\(describe(graph)) · \(report.reachableCount)/\(report.totalCount) reachable",
            thresholdLimit: configuration.thresholds.maxUnusedSymbols,
            thresholdRule: AnalysisDiagnostics.Rule.unusedSymbol
        )
    }

    /// 특정 선언이 왜 살아 있는지 사람이 읽는 문장으로 설명한다.
    public func explainRetention(of subject: String) throws -> CommandOutcome {
        // 그래프를 두 번 만들지 않는다. 질의가 이미 만든 것을 그대로 받는다.
        let (graph, lookup, explanation) = retentionExplanation(of: subject, in: try loadContext())

        switch lookup {
        case .notFound:
            return CommandOutcome(output: "No declaration matches '\(subject)'.\n", subjectNotFound: true)
        case let .ambiguous(candidates):
            let list = candidates.map { "  \($0.qualifiedName)  \($0.usr ?? $0.id.rawValue)" }
            return CommandOutcome(
                output: "'\(subject)' matches \(candidates.count) declarations. "
                    + "Pass one of these USRs instead:\n" + list.joined(separator: "\n") + "\n"
            )
        case let .found(node):
            let outcome = Self.describeExplanation(explanation, for: node, in: graph)
            guard outcome.hasFindings, let baseline = try loadBaseline() else { return outcome }
            // 베이스라인이 억제한 문제를 --explain 만 다시 살려 내면, 같은 저장소·같은
            // 베이스라인인데 보고 방식에 따라 반대 판정이 나온다. 설명은 그대로 두고
            // 판정만 맞춘다.
            let suppressed = baseline.filtering([Self.unusedDiagnostic(for: node)]).isEmpty
            guard suppressed else { return outcome }
            return CommandOutcome(output: outcome.output, findingCount: 0, suppressedCount: 1)
        }
    }

    /// `dead` 가 이 정점에 대해 만들어 낼 진단.
    ///
    /// 베이스라인 지문이 같아야 하므로 `AnalysisDiagnostics` 와 같은 방식으로 만든다.
    private static func unusedDiagnostic(for node: GraphNode) -> Diagnostic {
        Diagnostic(
            ruleIdentifier: AnalysisDiagnostics.Rule.unusedSymbol,
            severity: .warning,
            message: "\(node.kind.rawValue) '\(node.qualifiedName)' is never used",
            location: node.location,
            subject: node.usr ?? node.id.rawValue
        )
    }

    public func measureMetrics(level: GraphLevel? = nil) throws -> CommandOutcome {
        let (graph, metrics, tolerance) = metrics(in: try loadContext(), level: level)
        let diagnostics = AnalysisDiagnostics.diagnostics(for: metrics, thresholds: configuration.thresholds)
        let renderer = MetricsRenderer(tolerance: tolerance)

        let baseline = try loadBaseline()
        let reported = baseline?.filtering(diagnostics) ?? diagnostics
        let suppressed = diagnostics.count - reported.count

        let summary = ReportSummary(
            command: "metrics",
            subject: describe(graph),
            suppressedCount: suppressed
        )
        // sarif/checkstyle/xcode/github-actions 는 진단을 담는 형식이지 지표표를 담는 형식이
        // 아니다. 예전에는 이 형식들이 지표 JSON 을 그대로 받아, 확장자만 `.sarif` 인
        // 코드 스캐닝이 거부하는 문서가 나왔다.
        let output: String = switch configuration.reportFormat {
        case .json:
            try renderer.renderJSON(metrics, diagnostics: reported, suppressedCount: suppressed)
        case .sarif, .checkstyle, .xcode, .githubActions:
            try DiagnosticReporterFactory.make(configuration.reportFormat).report(reported, summary: summary)
        case .text:
            renderer.renderTable(metrics)
                + (reported.isEmpty
                    ? ""
                    : "\n" + (try DiagnosticReporterFactory.make(.text).report(reported, summary: summary)))
        }
        // 다른 명령과 달리 지표 임계값만 CI 를 막지 못했다. 같은 설정 파일 안에서
        // 어떤 임계값은 빌드를 세우고 어떤 임계값은 세우지 않는 상태였다.
        let thresholdFailure: CartographError? = reported.isEmpty
            ? nil
            : .thresholdExceeded(
                rule: AnalysisDiagnostics.Rule.metricThreshold,
                message: "\(reported.count) metric threshold(s) exceeded"
            )
        return CommandOutcome(
            output: output,
            findingCount: reported.count,
            suppressedCount: suppressed,
            thresholdFailure: thresholdFailure
        )
    }

    public func checkRules(level: GraphLevel? = nil) throws -> CommandOutcome {
        let (graph, violations, unassigned) = try layerViolations(in: try loadContext(), level: level)
        var diagnostics = AnalysisDiagnostics.diagnostics(for: violations)
        diagnostics += AnalysisDiagnostics.unassignedLayerDiagnostics(for: unassigned, in: graph)

        return try finish(
            diagnostics,
            command: "rules",
            subject: describe(graph),
            thresholdLimit: configuration.thresholds.maxRuleViolations,
            thresholdRule: AnalysisDiagnostics.Rule.layerViolation,
            // 레이어 미지정은 정보성이라 임계값 계산에 넣지 않는다.
            countedRules: [AnalysisDiagnostics.Rule.layerViolation]
        )
    }

    // MARK: - 베이스라인

    /// 모든 명령의 진단을 한 번의 인덱스 읽기로 모은다.
    ///
    /// 지표 임계값 위반도 함께 담는다. `metrics` 는 베이스라인을 적용하는데
    /// `baseline` 이 그것을 기록하지 못하면 영원히 억제할 수 없는 진단이 생긴다.
    public func collectAllDiagnostics() throws -> [Diagnostic] {
        let context = try loadContext()
        let (moduleGraph, foundCycles) = cycles(in: context)
        let (_, unused) = unusedCode(in: context)
        let (_, metricValues, _) = metrics(in: context)
        let (_, violations, _) = try layerViolations(in: context)

        return AnalysisDiagnostics.diagnostics(for: foundCycles, in: moduleGraph)
            + AnalysisDiagnostics.diagnostics(for: unused)
            + AnalysisDiagnostics.diagnostics(for: violations)
            + AnalysisDiagnostics.diagnostics(for: metricValues, thresholds: configuration.thresholds)
    }

    /// 현재 진단 상태를 베이스라인 파일로 기록한다.
    public func writeBaseline(diagnostics: [Diagnostic], to path: String) throws -> CommandOutcome {
        let baseline = Baseline.capturing(diagnostics)
        try BaselineStore(fileSystem: environment.fileSystem).write(baseline, to: path)
        return CommandOutcome(output: "Wrote \(baseline.fingerprints.count) findings to \(path)\n")
    }

    // MARK: - 내부 구현

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

    private static func describeExplanation(
        _ explanation: ReachabilityExplanation?,
        for node: GraphNode,
        in graph: CodeGraph
    ) -> CommandOutcome {
        let name = node.qualifiedName
        switch explanation {
        case let .retained(reason):
            return CommandOutcome(output: "\(name) is retained because it is \(reason.explanation).\n")
        case let .retainedByMember(inherited):
            let member = graph.node(inherited.member)?.qualifiedName ?? inherited.member.rawValue
            return CommandOutcome(
                output: "\(name) is retained because its member \(member) is \(inherited.reason.explanation).\n"
            )
        case let .reachable(path):
            let trail = path.map { graph.node($0)?.qualifiedName ?? $0.rawValue }.joined(separator: " → ")
            return CommandOutcome(output: "\(name) is reachable:\n  \(trail)\n")
        case .unreachable:
            return CommandOutcome(output: "\(name) is not reachable from any retained root.\n", findingCount: 1)
        case .unknown, nil:
            // 이 분기는 정점을 찾은 뒤에만 도달한다. "찾지 못했다"고 말하면
            // 사용자는 자기가 친 이름이 틀렸다고 오해한다.
            return CommandOutcome(
                output: "Could not determine reachability for \(name).\n",
                findingCount: 1
            )
        }
    }

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

    private func makeIndexProvider() throws -> any IndexProviding {
        if let override = environment.indexProviderOverride { return override }

        let locator = IndexStoreLocator(fileSystem: environment.fileSystem)
        let storePath = try locator.locate(
            explicitPath: configuration.indexStorePath,
            projectPath: projectPath,
            derivedDataPath: configuration.derivedDataPath ?? environment.derivedDataPath
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
