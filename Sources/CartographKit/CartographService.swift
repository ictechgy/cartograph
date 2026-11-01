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
    let configuration: CartographConfiguration
    let environment: CartographEnvironment

    /// 보고 범위. nil 이면 발견을 전부 보고한다.
    ///
    /// 설정 파일이 아니라 생성 인자로 받는다. 변경된 파일 목록은 실행할 때마다
    /// 달라지는 값이라 파일에 적을 수 있는 성질이 아니다.
    let reportScope: ReportScope?

    /// 인덱스가 이 프로젝트를 하나도 모를 때도 분석을 진행할지.
    ///
    /// 설정 파일이 아니라 생성 인자로 받는다. `reportScope` 와 같은 이유다 —
    /// 이것은 프로젝트의 성질이 아니라 한 번의 실행에 대한 진술이다. 더구나 이
    /// 가드는 CI 게이트를 지키려고 있는 것이라, 설정 파일에 한 줄 적어 영구히
    /// 끌 수 있게 하면 그 이후 실행에서는 게이트가 풀린 사실이 호출부에 남지 않는다.
    private let allowsEmptyIndex: Bool

    public init(
        configuration: CartographConfiguration,
        environment: CartographEnvironment = .live(),
        reportScope: ReportScope? = nil,
        allowsEmptyIndex: Bool = false
    ) {
        self.configuration = configuration
        self.environment = environment
        self.reportScope = reportScope
        self.allowsEmptyIndex = allowsEmptyIndex
    }

    /// 분석 대상 프로젝트 루트.
    public var projectPath: String {
        configuration.projectPath ?? environment.fileSystem.currentDirectoryPath
    }

    // MARK: - 인덱스

    /// 인덱스를 읽고 구문 정보로 보강한 스냅샷.
    ///
    /// 원시 스냅샷은 비어 있어도 정당한 답이다. "이 인덱스가 아는 것을 값으로 달라"에
    /// 대해 공집합은 거짓말이 아니다. 비었을 때 실패해야 하는 것은 분석 문맥 쪽이라
    /// 가드는 `loadContext()` 에만 둔다. `bridges` 가 이 경로로 내려오는 것도 이유다.
    public func loadSnapshot() throws -> IndexSnapshot {
        let inventory = projectFileInventory()
        let source = try makeIndexSource(
            includeObjectiveCSources: true, sourceRoots: inventory.sourceFiles, inventory: inventory
        )
        return try enrich(source.provider.loadSnapshot(), inventory: inventory).snapshot
    }

    /// 원시 스냅샷에 구문 정보를 얹는다.
    private func enrich(_ raw: IndexSnapshot, inventory: ProjectFileInventory? = nil) -> SnapshotEnricher.Result {
        let interfaceBuilderFiles = inventory.map {
            configuration.retention.retainInterfaceBuilder ? $0.interfaceBuilderFiles : []
        }
        var input = raw
        if let inventory, let dates = raw.sourceFreshnessDates {
            let indexed = Set(dates.keys.map(environment.fileSystem.canonicalPath))
            let missing = inventory.sourceFiles.contains {
                !$0.hasSuffix("/Package.swift") && !indexed.contains(environment.fileSystem.canonicalPath($0))
            }
            if missing {
                // 파일 단위 참조가 사라진 인덱스에서 모듈 사용 부재를 import 제거 근거로 쓰지 않는다.
                for path in input.fileModuleUsages.keys {
                    input.fileModuleUsages[path]?.hasUnattributedReferences = true
                }
            }
        }
        return SnapshotEnricher(
            fileSystem: environment.fileSystem,
            retention: configuration.retention,
            cachePath: environment.usesSyntaxCache
                ? SourceFactsCache.defaultPath(forProject: projectPath)
                : nil
        )
        .enrichWithDiagnostics(
            input,
            interfaceBuilderRoots: inventory == nil && configuration.retention.retainInterfaceBuilder
                ? [projectPath] : [],
            pathFilter: configuration.pathFilter,
            edgeKinds: configuration.edgeKinds,
            interfaceBuilderFiles: interfaceBuilderFiles
        )
    }

    /// 인덱스를 한 번만 읽어 만든 분석 문맥.
    ///
    /// 여기를 지난 스냅샷은 비어 있지 않다. 그 불변식이 이 타입의 계약이다.
    public func loadContext() throws -> AnalysisContext {
        try loadContext(includeSelfReferences: false)
    }

    /// 그래프 표현과 원시 참조 수집을 분리해 재귀 호출을 명시적으로 보존할 수 있게 한다.
    public func loadContext(includeSelfReferences: Bool) throws -> AnalysisContext {
        try loadContext(includeSelfReferences: includeSelfReferences, expectedIndexStorePath: nil)
    }

    /// v2는 자동 선택된 다른 store에 같은 unit 이름이 있어도 캡처된 record 바이트와 혼합하지 않는다.
    func loadContext(includeSelfReferences: Bool, expectedIndexStorePath: String?) throws -> AnalysisContext {
        let (externalRetentions, inventory, source) = try measureQueryPhase(
            .inputPreparation, observer: environment.queryPhaseObserver
        ) {
            // 근거 파일을 인덱스보다 먼저 읽는다. 파일이 깨졌을 때 인덱스 없는 프로젝트에서도
            // 그 오류가 보여야 CLI 계약 검증이 이 경로를 실제로 증명한다.
            let externalPath = configuration.externalRetentionsPath.map(resolveProjectRelativePath)
            let externalRetentions = try ExternalRetentionStore(fileSystem: environment.fileSystem)
                .loadIfConfigured(at: externalPath)
            let inventory = projectFileInventory()
            let source = try makeIndexSource(
                includeObjectiveCSources: true, includeSelfReferences: includeSelfReferences,
                sourceRoots: inventory.sourceFiles, inventory: inventory
            )
            return (externalRetentions, inventory, source)
        }
        if let expectedIndexStorePath {
            guard environment.indexProviderOverride == nil,
                  try environment.fileSystem.realPath(at: source.storePath) == expectedIndexStorePath else {
                throw XcodeLocalPackageIO.invalid("Fresh analysis selected a different index store; use the captured --index-store path.")
            }
        }
        let raw = try measureQueryPhase(.rawSnapshot, observer: environment.queryPhaseObserver) {
            try source.provider.loadSnapshot()
        }
        return try measureQueryPhase(.syntaxContext, observer: environment.queryPhaseObserver) {
            let enriched = enrich(raw, inventory: inventory)
            let snapshot = enriched.snapshot
            try requireNonEmptyIndex(snapshot, from: source)
            let context = AnalysisContext(
                snapshot: snapshot,
                pathFilter: configuration.pathFilter,
                edgeKinds: configuration.edgeKinds,
                externalRetentions: externalRetentions,
                missingSourcePaths: enriched.missingSourcePaths,
                unreadableSourcePaths: enriched.unreadableSourcePaths,
                unresolvedLocalFunctionsByPath: enriched.unresolvedLocalFunctionsByPath,
                localFunctionDiagnostics: enriched.localFunctionDiagnostics,
                runtimeFiles: enriched.runtimeFiles + runtimeResourceFacts(paths: inventory.runtimeFiles),
                runtimeFreshness: runtimeSourceFreshness(snapshot: snapshot,
                    missing: enriched.missingSourcePaths, unreadable: enriched.unreadableSourcePaths)
            )
            return context.bindingProjectFileInventory(inventory)
                .bindingIndexSelectionLimitations(source.selectionLimitations + SwiftPMModuleCoverage(
                    fileSystem: environment.fileSystem).limitations(storePath: source.storePath,
                        projectPath: projectPath, sourcePaths: inventory.sourceFiles, snapshot: raw))
        }
    }

    /// 탈출구를 켜고 아무것도 분석하지 않은 실행이면, 요약 줄에 붙일 단서.
    ///
    /// CI 로그가 보여 주는 것은 이 한 줄뿐이다. 여기 나타나지 않으면 아무것도 분석하지
    /// 않은 실행이 평범한 초록과 구분되지 않고, 그러면 탈출구가 가드를 완전히 무력화한다.
    private func emptyIndexCaveat(_ context: AnalysisContext) -> String? {
        guard allowsEmptyIndex, context.snapshot.symbols.isEmpty else { return nil }
        return "analysed nothing — --allow-empty-index"
    }

    /// 인덱스가 이 프로젝트의 선언을 하나도 모르면 분석을 시작하지 않는다.
    ///
    /// 조용히 "발견 없음"으로 끝내면 `--strict` 가 0줄을 분석하고 통과한다. 그 초록불은
    /// 코드가 깨끗하다는 뜻으로 읽히므로, 발견이 아니라 도구 실패로 다룬다.
    /// 참조가 아니라 심볼만 본다. 선언만 있고 참조가 없는 한 파일짜리 패키지는 정당하다.
    private func requireNonEmptyIndex(_ snapshot: IndexSnapshot, from source: IndexSource) throws {
        guard snapshot.symbols.isEmpty, !allowsEmptyIndex else { return }
        throw CartographError.indexStoreEmpty(emptyIndexFacts(from: source))
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
    public func unusedCode(
        in context: AnalysisContext,
        findingTestOnlyCode: Bool = false
    ) -> (graph: CodeGraph, report: UnusedCodeReport) {
        unusedCode(in: context, findingTestOnlyCode: findingTestOnlyCode, computingSuperfluousIgnores: true)
    }

    /// `unusedCode(in:findingTestOnlyCode:)` 와 같되, 불필요한 무시 주석 판정을 할지 고른다.
    ///
    /// 그 판정은 무시 단위마다 도달성 탐색을 다시 도는 분석에서 가장 비싼 단계이고, 결과를 읽는 곳은
    /// `dead` 뿐이다. check·baseline·fix·explain 은 끈다. 다른 보고는 켜고 끄는 것과 무관하게 같다.
    func unusedCode(
        in context: AnalysisContext,
        findingTestOnlyCode: Bool = false,
        computingSuperfluousIgnores: Bool
    ) -> (graph: CodeGraph, report: UnusedCodeReport) {
        let graph = context.buildGraph(level: .symbol).graph
        let report = analyzeUnusedCode(
            in: context, graph: graph, findingTestOnlyCode: findingTestOnlyCode,
            computingSuperfluousIgnores: computingSuperfluousIgnores
        )
        return (graph, report)
    }

    /// dead는 질의와 같은 도달 근거 위에서 전체 발견 목록을 계산한다.
    private func analyzeUnusedCode(
        in context: AnalysisContext, graph: CodeGraph, findingTestOnlyCode: Bool = false,
        computingSuperfluousIgnores: Bool
    ) -> UnusedCodeReport {
        ReachabilityAnalyzer(
            policy: makeRetentionPolicy(externalRetentions: context.externalRetentionIndex),
            options: .init(
                findsTestOnlyCode: findingTestOnlyCode, computesSuperfluousIgnores: computingSuperfluousIgnores
            )
        ).analyze(graph: graph, snapshot: context.snapshot)
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
        let result = context.buildGraph(level: level ?? configuration.level)
        let graph = result.graph
        let evaluator = LayerRuleEvaluator(
            layers: configuration.layers, rules: configuration.rules,
            projectPaths: LayerRuleProjectPaths.confirmed(projectPath: projectPath, fileSystem: environment.fileSystem),
            referenceLocations: result.referenceLocations(in: context.snapshot)
        )
        // 배정 맵(정점마다 글롭 대조)은 위반 판정과 미지정 수집이 함께 쓴다.
        let (violations, unassigned) = evaluator.assess(graph: graph)
        return (graph, violations, unassigned)
    }

    /// 특정 선언이 살아 있는 이유.
    public func retentionExplanation(
        of subject: String,
        in context: AnalysisContext
    ) -> (graph: CodeGraph, lookup: NodeLookup, explanation: ReachabilityExplanation?) {
        let (graph, report) = unusedCode(in: context, computingSuperfluousIgnores: false)
        let lookup = GraphQueryIndex(graph: graph).resolve(subject)
        guard case let .found(node) = lookup else { return (graph, lookup, nil) }
        return (graph, lookup, report.explain(node.id, in: graph))
    }

    // MARK: - 명령 API

    /// 그래프를 지정한 형식으로 내보낸다.
    public func renderGraph(level: GraphLevel? = nil, format: GraphFormat? = nil) throws -> CommandOutcome {
        let built = try loadContext().buildGraph(level: level ?? configuration.level)
        let renderer = GraphRendererFactory.make(format ?? configuration.graphFormat)
        return CommandOutcome(output: try renderer.render(built.graph), notes: built.sourceAttributionLimitations)
    }

    /// 기존 그래프 API를 유지하면서 opt-in occurrence 근거 JSON을 내보낸다.
    public func renderGraph(
        level: GraphLevel?,
        format: GraphFormat?,
        includingEvidence: Bool
    ) throws -> CommandOutcome {
        try renderGraph(level: level, format: format, includingEvidence: includingEvidence, includingSelfLoops: false)
    }

    /// 기본 그래프 계약을 유지하면서 명시적 심볼 자기 간선과 호출 위치를 함께 내보낸다.
    public func renderGraph(
        level: GraphLevel?,
        format: GraphFormat?,
        includingEvidence: Bool,
        includingSelfLoops: Bool
    ) throws -> CommandOutcome {
        guard includingEvidence || includingSelfLoops else { return try renderGraph(level: level, format: format) }
        let selectedLevel = level ?? configuration.level
        guard !includingSelfLoops || selectedLevel == .symbol else {
            throw CartographError.invalidConfiguration(
                path: projectPath,
                reason: "Self-loop export requires symbol level. Use --level symbol."
            )
        }
        let selectedFormat = format ?? configuration.graphFormat
        guard !includingEvidence || selectedFormat == .json else {
            throw CartographError.invalidConfiguration(
                path: projectPath,
                reason: "Graph occurrence evidence is available only with JSON format. Use --format json."
            )
        }
        let context = try loadContext(includeSelfReferences: includingSelfLoops)
        let result = context.buildGraph(level: selectedLevel, includeSelfLoops: includingSelfLoops)
        guard includingEvidence else {
            return CommandOutcome(output: try GraphRendererFactory.make(selectedFormat).render(result.graph))
        }
        let output = try JSONGraphEvidenceRenderer().render(
            result: result,
            snapshot: context.snapshot,
            projectPath: projectPath,
            sourceFiles: context.projectFileInventory?.sourceFiles
        )
        return CommandOutcome(output: output)
    }

    /// raw symbol graph를 유지하면서 공유 Swift 선언의 module별 USR projection을
    /// 별도 JSON으로 내보낸다.
    public func renderDeclarationProjection(
        primaryModule: String,
        level: GraphLevel? = nil,
        format: GraphFormat? = nil
    ) throws -> CommandOutcome {
        let selectedLevel = level ?? configuration.level
        guard selectedLevel == .symbol else {
            throw CartographError.invalidConfiguration(
                path: projectPath,
                reason: "Declaration projection requires symbol level. Use --level symbol."
            )
        }
        let selectedFormat = format ?? configuration.graphFormat
        guard selectedFormat == .json else {
            throw CartographError.invalidConfiguration(
                path: projectPath,
                reason: "Declaration projection is available only with JSON format. Use --format json."
            )
        }
        guard Self.isValidModuleName(primaryModule) else {
            throw CartographError.invalidConfiguration(
                path: projectPath,
                reason: "The primary module must be a valid Swift module name."
            )
        }
        let context = try loadContext()
        guard context.snapshot.symbols.contains(where: { $0.module == primaryModule }) else {
            throw CartographError.invalidConfiguration(
                path: projectPath,
                reason: "Primary module '\(primaryModule)' does not occur in the project index."
            )
        }
        let result = context.buildGraph(level: selectedLevel)
        let output = try SwiftDeclarationProjectionRenderer().render(
            result: result,
            snapshot: context.snapshot,
            projectPath: projectPath,
            primaryModule: primaryModule
        )
        return CommandOutcome(output: output)
    }

    private static func isValidModuleName(_ value: String) -> Bool {
        guard let first = value.first, first.isLetter || first == "_", value.utf8.count <= 255 else { return false }
        return value.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// 순환 목록에 범위·베이스라인·임계값과 출력 형식을 얹는다.
    ///
    /// `--since` 범위는 `check` 와 같은 구성원 기준이다(`scopedCycleDiagnostics`). 진단 위치는 대표 경로의
    /// 첫 정점 하나라, 위치로 거르면 PR 이 다른 구성원 쪽 파일에서 만든 순환이 이 게이트에서만 사라지고
    /// 위치가 없는 모듈 순환은 범위와 무관하게 전부 남는다.
    public func detectCycles(level: GraphLevel? = nil) throws -> CommandOutcome {
        let context = try loadContext()
        let selectedLevel = level ?? configuration.level
        let (graph, cycles) = cycles(in: context, level: selectedLevel)
        // 순환 검사도 CI 게이트다. 인덱스가 낡은 채로 "순환 없음"이 나가면 그
        // 초록불은 아무것도 검사하지 않은 초록불이다. dead 와 같은 한계를 싣는다.
        return try finish(
            scopedCycleDiagnostics(cycles, level: selectedLevel, context: context),
            command: "cycles",
            subject: describe(graph),
            thresholdLimit: configuration.thresholds.maxCycles,
            thresholdRule: AnalysisDiagnostics.Rule.cycle,
            limitations: limitations(context: context, graph: graph, requestedLevel: level),
            caveat: emptyIndexCaveat(context),
            alreadyScoped: true
        )
    }

    /// - Parameter reportingTestOnlyCode: 테스트·프리뷰만 붙잡고 있는 선언도 함께
    ///   알린다. 죽은 코드가 아니므로 정보로만 보고하고 종료 코드에는 영향을 주지
    ///   않는다.
    public func detectUnusedCode(reportingTestOnlyCode: Bool = false) throws -> CommandOutcome {
        try detectUnusedCode(reportingTestOnlyCode: reportingTestOnlyCode, findingReviewOptions: nil)
    }

    /// 전체 JSON 진단을 유지하면서 선택적 파일 요약과 생성 헤더 제안을 덧붙인다.
    /// 기존 한 인자 함수 참조의 소스 호환성을 유지하려고 별도 오버로드로 제공한다.
    public func detectUnusedCode(reportingTestOnlyCode: Bool = false,
                                 findingReviewOptions: FindingReviewOptions?) throws -> CommandOutcome {
        if let findingReviewOptions {
            guard configuration.reportFormat == .json else {
                throw CartographError.invalidConfiguration(path: projectPath,
                    reason: "Finding file summaries and generated suggestions require JSON report format.")
            }
            try findingReviewOptions.validate()
        }
        let context = try loadContext()
        let (graph, report) = unusedCode(
            in: context, findingTestOnlyCode: reportingTestOnlyCode, computingSuperfluousIgnores: true
        )
        let limitations = analysisLimitations(context: context, symbolGraph: graph)
        return try finish(
            AnalysisDiagnostics.diagnostics(for: report)
                + AnalysisDiagnostics.testOnlyDiagnostics(for: report)
                + AnalysisDiagnostics.unusedParameterDiagnostics(for: report, in: graph)
                + AnalysisDiagnostics.assignOnlyDiagnostics(for: report, in: graph)
                + AnalysisDiagnostics.unusedImportDiagnostics(for: report)
                + AnalysisDiagnostics.superfluousIgnoreDiagnostics(for: report)
                + AnalysisDiagnostics.redundantPublicDiagnostics(for: report),
            command: "dead",
            subject: "\(describe(graph)) · \(report.reachableCount)/\(report.totalCount) reachable",
            thresholdLimit: configuration.thresholds.maxUnusedSymbols,
            thresholdRule: AnalysisDiagnostics.Rule.unusedSymbol,
            // 테스트 전용은 정보성이라 임계값과 --strict 계산에 넣지 않는다.
            countedRules: [AnalysisDiagnostics.Rule.unusedSymbol],
            // 미사용 목록은 에이전트가 삭제의 출발점으로 삼는 답이다. `query` 처럼 한계를 싣는다.
            // 알릴 것이 없으면 키 자체를 만들지 않는다. 빈 배열이 매번 붙으면 그것도 경보다.
            limitations: limitations.isEmpty ? nil : limitations,
            caveat: emptyIndexCaveat(context),
            findingReviewOptions: findingReviewOptions
        )
    }

    /// 특정 선언이 왜 살아 있는지 사람이 읽는 문장으로 설명한다.
    public func explainRetention(of subject: String) throws -> CommandOutcome {
        // 그래프를 두 번 만들지 않는다. 질의가 이미 만든 것을 그대로 받는다.
        let context = try loadContext()
        let (graph, lookup, explanation) = retentionExplanation(of: subject, in: context)

        let notes = context.externalRetentions.map {
            ExternalRetentionProvenanceDiagnostics.limitations($0.provenance)
        } ?? []
        switch lookup {
        case .notFound:
            return CommandOutcome(
                output: Self.describeNotFound(
                    subject,
                    similar: GraphQueryIndex(graph: graph).similarCandidates(to: subject),
                    noun: "declaration"
                ),
                subjectNotFound: true, notes: notes
            )
        case let .ambiguous(candidates):
            return CommandOutcome(output: Self.describeCandidates(candidates, for: subject, in: graph), notes: notes)
        case let .found(node):
            let described = try Self.describeExplanation(
                explanation, for: node, in: graph, externalRetentions: context.externalRetentionIndex,
                projectPath: projectPath
            )
            let outcome = CommandOutcome(output: described.output, findingCount: described.findingCount,
                                         suppressedCount: described.suppressedCount, notes: notes)
            guard outcome.hasFindings, let baseline = try loadBaseline() else { return outcome }
            // 베이스라인이 억제한 문제를 --explain 만 다시 살려 내면, 같은 저장소·같은
            // 베이스라인인데 보고 방식에 따라 반대 판정이 나온다. 설명은 그대로 두고
            // 판정만 맞춘다.
            let suppressed = baseline.filtering([Self.unusedDiagnostic(for: node)]).isEmpty
            guard suppressed else { return outcome }
            return CommandOutcome(output: outcome.output, findingCount: 0, suppressedCount: 1, notes: notes)
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

    /// 특정 정점이 어느 순환에 속하는지 사람이 읽는 문장으로 설명한다.
    ///
    /// "스무 개가 서로 얽혀 있다"는 보고는 정확하지만 손댈 곳을 알려 주지 않는다.
    /// 하나의 정점을 물었을 때 그것이 낀 구체적인 순환과 끊을 후보를 보여 주어야
    /// 실제로 행동할 수 있다.
    public func explainCycles(of subject: String, level: GraphLevel? = nil) throws -> CommandOutcome {
        let (graph, found) = cycles(in: try loadContext(), level: level)
        let lookup = GraphQueryIndex(graph: graph).resolve(subject)
        switch lookup {
        case .notFound:
            return CommandOutcome(
                output: Self.describeNotFound(
                    subject,
                    similar: GraphQueryIndex(graph: graph).similarCandidates(to: subject),
                    noun: "node"
                ),
                subjectNotFound: true
            )
        case let .ambiguous(candidates):
            return CommandOutcome(output: Self.describeAmbiguity(subject, candidates: candidates))
        case let .found(node):
            // 참여 판정은 강한 연결 요소로 한다. 대표 경로에만 있는지를 보면,
            // 같은 묶음에 있으면서 대표 경로에 뽑히지 않은 정점에 "순환에 없다"고
            // 거짓말을 하게 된다. 설명이 틀리는 것은 보고가 틀리는 것보다 나쁘다.
            // 사용자가 그 설명을 믿고 코드를 건드리기 때문이다.
            let involved = found.filter { $0.component.contains(node.id) }
            guard !involved.isEmpty else {
                return CommandOutcome(output: Self.printableLines(["\(node.qualifiedName) is not part of any cycle."]))
            }
            let lines = involved.flatMap { Self.describeCycle($0, for: node.id, in: graph) }
            let judgment = try baselineJudgment(of: involved, in: graph)
            return CommandOutcome(
                output: Self.printableLines(["\(node.qualifiedName) is part of \(involved.count) cycle(s):"] + lines),
                findingCount: judgment.findingCount,
                suppressedCount: judgment.suppressedCount
            )
        }
    }

    /// 설명할 순환 가운데 베이스라인이 억제하지 않은 수와 억제한 수.
    ///
    /// 베이스라인이 억제한 순환을 `--explain` 만 다시 살려 내면, 같은 베이스라인인데 `cycles --strict` 는
    /// 0 으로, `cycles --explain --strict` 는 1 로 끝난다. `explainRetention` 처럼 설명은 그대로 두고
    /// 판정만 맞춘다. 지문이 같아야 하므로 진단은 `detectCycles` 와 같은 변환으로 만든다.
    private func baselineJudgment(
        of cycles: [DependencyCycle], in graph: CodeGraph
    ) throws -> (findingCount: Int, suppressedCount: Int) {
        let diagnostics = AnalysisDiagnostics.diagnostics(for: cycles, in: graph)
        let reported = try loadBaseline()?.filtering(diagnostics) ?? diagnostics
        return (reported.count, diagnostics.count - reported.count)
    }

    /// 특정 정점이 왜 그 레이어에 속하는지, 어떤 규칙이 걸리는지 설명한다.
    public func explainRules(of subject: String, level: GraphLevel? = nil) throws -> CommandOutcome {
        let context = try loadContext()
        let graph = context.buildGraph(level: level ?? configuration.level).graph
        let lookup = GraphQueryIndex(graph: graph).resolve(subject)
        switch lookup {
        case .notFound:
            return CommandOutcome(
                output: Self.describeNotFound(
                    subject,
                    similar: GraphQueryIndex(graph: graph).similarCandidates(to: subject),
                    noun: "node"
                ),
                subjectNotFound: true
            )
        case let .ambiguous(candidates):
            return CommandOutcome(output: Self.describeAmbiguity(subject, candidates: candidates))
        case let .found(node):
            let evaluator = LayerRuleEvaluator(
                layers: configuration.layers, rules: configuration.rules,
                projectPaths: LayerRuleProjectPaths.confirmed(projectPath: projectPath, fileSystem: environment.fileSystem)
            )
            return CommandOutcome(output: Self.printableLines(Self.describeLayer(of: node, using: evaluator)))
        }
    }

    /// 사람이 읽는 설명의 줄들을 Core 의 필터에 하나씩 통과시킨 뒤 개행으로 잇는다.
    ///
    /// `--explain` 계열과 찾지 못한 이름 문구는 정점 이름·경로·레이어와 규칙의 이름처럼 저장소가 통제하는
    /// 값을 터미널과 표준 오류로 그대로 보낸다. 원소 하나가 출력의 한 줄이고, 구조용 개행은 여기서만
    /// 넣는다. 줄마다 거르므로 ESC·OSC 52·U+202E 와 함께 값 속 개행·복귀도 그 줄 안에서 빠진다.
    /// 그래야 파일 경로나 레이어 이름이 가짜 후보 줄·가짜 USR 줄을 끼워 넣지 못한다 — 사용자는 후보
    /// 목록의 USR 을 복사해 다시 묻는다. 줄 수는 값이 아니라 문장 틀이 정한다.
    private static func printableLines(_ lines: [String]) -> String {
        lines.map { PrintableText.printable($0) }.joined(separator: "\n") + "\n"
    }

    private static func describeAmbiguity(_ subject: String, candidates: [GraphNode]) -> String {
        let list = candidates.map { "  \($0.qualifiedName)  \($0.usr ?? $0.id.rawValue)" }
        return printableLines(
            ["'\(subject)' matches \(candidates.count) declarations. Pass one of these USRs instead:"] + list
        )
    }

    /// 순환 하나를 설명하는 줄들. 대표 경로, 필요하면 그 앞의 묶음 안내, 끊을 후보 순이다.
    private static func describeCycle(
        _ cycle: DependencyCycle,
        for node: NodeID,
        in graph: CodeGraph
    ) -> [String] {
        let trail = cycle.path.map { graph.node($0)?.qualifiedName ?? $0.rawValue }
        let path = "  " + (trail + [trail[0]]).joined(separator: " → ")
        // 대표 경로에 없는 정점에게 이 경로를 그대로 보여 주면 자기 이름을 못 찾는다.
        // 같은 묶음에 있다는 사실과 대표 경로를 구분해서 말한다.
        var lines = cycle.path.contains(node) ? [path] : ["  in the same tangle, whose representative cycle is:", path]
        if let edge = cycle.suggestedEdgeToBreak {
            let source = graph.node(edge.source)?.qualifiedName ?? edge.source.rawValue
            let target = graph.node(edge.target)?.qualifiedName ?? edge.target.rawValue
            lines.append("      weakest link: \(source) → \(target)"
                + " (\(edge.kind.rawValue), \(edge.weight) references)")
        }
        return lines
    }

    /// 정점의 레이어 배정과 그 레이어에서 출발하는 규칙을 설명하는 줄들.
    private static func describeLayer(of node: GraphNode, using evaluator: LayerRuleEvaluator) -> [String] {
        let assignment = evaluator.assignment(of: node)
        guard let match = assignment.match else {
            return ["\(node.qualifiedName) belongs to no layer.",
                    "  checked: " + assignment.candidates.joined(separator: ", ")]
        }
        // 대상을 좁힌 레이어만 그 사실을 붙인다. 적지 않은 설정의 설명은 예전 그대로다.
        let targets = match.matchTargets.map { " (match_on: \($0.map(\.rawValue).joined(separator: ", ")))" } ?? ""
        var lines = ["\(node.qualifiedName) is in layer '\(match.layer)'.",
                     "  matched: \(match.candidate) against '\(match.pattern)'\(targets)"]
        let rules = evaluator.rules(from: match.layer)
        guard !rules.isEmpty else {
            return lines + ["  no rule starts from '\(match.layer)', so nothing is enforced here."]
        }
        lines.append("  rules from '\(match.layer)':")
        for rule in rules {
            lines.append("    \(rule.displayName)")
            if let rationale = rule.rationale { lines.append("      rationale: \(rationale)") }
            if let hint = rule.hint { lines.append("      hint: \(hint)") }
        }
        return lines
    }

    /// 정점 하나에 대한 사실을 작게 답한다.
    ///
    /// 그래프 전체를 덤프하면 간선이 수만 개다. 사람도 에이전트도 그것을 읽지 못하고,
    /// 읽는다 해도 "이 심볼을 누가 쓰는가"라는 질문에는 여전히 답이 없다. 역방향
    /// 질의는 지금까지 이 도구 어디에도 없던 기능이다.
    ///
    /// 삭제해도 되는지는 답하지 않는다. 도달 불가라는 사실과, 그 판정이 보지 못한
    /// 채널을 같이 준다. 판단은 부르는 쪽의 몫이다.
    public func query(symbol subject: String, depth: Int = 1, limit: Int = 50) throws -> CommandOutcome {
        let document = try queryDocument(symbol: subject, depth: depth, limit: limit)
        let text = try measureQueryPhase(.serialization, observer: environment.queryPhaseObserver) {
            try Self.encodeQuery(document)
        }
        guard document.status == "notFound" else {
            return CommandOutcome(output: text)
        }
        return CommandOutcome(
            output: text,
            subjectNotFound: true,
            notFoundMessage: Self.singleQueryNotFoundMessage(document)
        )
    }

    /// 단건 `query` 가 notFound 로 끝날 때 stderr 에 나갈 문구.
    ///
    /// JSON 은 이미 표준 출력으로 나간 뒤다. 요청한 이름을 그대로 반향하고,
    /// 비슷한 이름이 있으면 같이 알려 준다. 이름 없이 "없다"만 말하면 부른 쪽은
    /// 무엇을 되물어야 할지 모른다 — 오타가 오타라고 말하지 않는 답이 된다.
    static func singleQueryNotFoundMessage(_ document: SymbolQueryDocument) -> String {
        var message = "no declaration matches '\(document.requested)'"
        let names = (document.candidates ?? []).map(\.qualifiedName)
        if !names.isEmpty {
            message += ". Similar names: " + names.joined(separator: ", ")
                + " — the JSON above lists each with its location and USR"
        }
        // 표준 출력의 JSON 은 이름을 그대로 둔다(되물을 때 맞아야 한다). 이 문구는 표준 오류로 가는
        // 한 줄이라 값 속 개행까지 함께 뺀다.
        return PrintableText.printable(message)
    }

    /// `--explain` 계열이 notFound 로 답할 때 쓰는 문장.
    ///
    /// 그래프는 이미 메모리에 있으므로 비슷한 이름 추천은 공짜다. 이름을 반향하지
    /// 않으면 부른 쪽은 무엇이 틀렸는지 다시 추측해야 한다.
    static func describeNotFound(
        _ subject: String, similar: [GraphNode], noun: String
    ) -> String {
        let names = similar.map(\.qualifiedName)
        guard !names.isEmpty else { return printableLines(["No \(noun) matches '\(subject)'."]) }
        return printableLines(
            ["No \(noun) matches '\(subject)'. Similar names: " + names.joined(separator: ", ") + "."]
        )
    }

    /// 여러 선언을 한 번에 묻는다.
    ///
    /// 그래프와 도달성과 한계 목록을 한 번만 만들고 질문만 반복한다. 답 하나하나는 싸고
    /// 그 앞의 준비가 비싸다. 프로세스를 요청 수만큼 띄우면 그 준비를 요청 수만큼 되풀이한다.
    ///
    /// 하나라도 찾지 못하면 종료 코드는 사용 오류가 되지만 **나머지 답은 전부 돌려준다.**
    /// 이름 하나가 틀렸다고 마흔둘의 답을 버리게 하지 않는다.
    public func queryBatch(symbols: [String], depth: Int = 1, limit: Int = 50) throws -> CommandOutcome {
        let session = try makeQuerySession(subjects: symbols)
        // 같은 이름의 notFound 추천은 이 배치 안에서 한 번만 계산한다. 답의 순서와 중복은 그대로다.
        var suggestions: [String: [GraphNode]] = [:]
        let results = try symbols.map {
            try queryDocument(symbol: $0, depth: depth, limit: limit, in: session, suggestions: &suggestions)
        }
        let text = try measureQueryPhase(.serialization, observer: environment.queryPhaseObserver) {
            try Self.encodeSortedJSON(SymbolQueryBatchDocument(results: results))
        }
        let missing = results.filter { $0.status == "notFound" }.map(\.requested)
        return CommandOutcome(
            output: text,
            subjectNotFound: !missing.isEmpty,
            missingSubjects: missing
        )
    }

    /// `query` 가 내보낼 문서를 만든다. 인코딩과 종료 코드는 부르는 쪽이 정한다.
    public func queryDocument(symbol subject: String, depth: Int = 1, limit: Int = 50) throws -> SymbolQueryDocument {
        let context = try loadContext()
        let session = try makeQuerySession(in: context, subjects: [subject])
        return try queryDocument(symbol: subject, depth: depth, limit: limit, in: session)
    }

    /// 질의 여러 건이 나눠 쓰는 준비물.
    ///
    /// 값으로 묶어 두지 않으면 배치 경로가 요청마다 인덱스를 다시 읽는다.
    struct FoundQueryFacts {
        let report: ReachabilityReport
        let referenceEvidence: ReferenceEvidenceIndex
    }

    struct QuerySession {
        let graph: CodeGraph
        let lookup: GraphQueryIndex
        var foundFacts: FoundQueryFacts?
        let limitations: [String]
        let localFunctionDiagnostics: LocalFunctionDiagnostics?
        /// 억제 판정에 쓸 지문 집합. 답마다 `filtering` 을 부르면 답 수 × 지문 수의
        /// 해싱이 매번 다시 일어난다.
        let baselineFingerprints: Set<String>
        private(set) var foundFactsBuildCount: Int

        mutating func installFoundFacts(_ facts: FoundQueryFacts) {
            guard foundFacts == nil else { return }
            foundFacts = facts
            foundFactsBuildCount += 1
        }
    }

    func makeQuerySession(subjects: [String]? = nil) throws -> QuerySession {
        let context = try loadContext()
        return try makeQuerySession(in: context, subjects: subjects)
    }

    /// 이미 읽은 문맥에서 질의 준비물을 만든다. 세션이 인덱스와 구문 보강을 다시 읽지 않게 한다.
    ///
    /// 베이스라인도 한 번만 읽는다. 없으면 요청마다 파일을 다시 읽는다. 답은 같지만,
    /// 1000건 배치에서 33 밀리초를 파일 시스템에 쓰고 그 값은 베이스라인이 커질수록 커진다.
    func makeQuerySession(in context: AnalysisContext, subjects: [String]? = nil) throws -> QuerySession {
        var session = try measureQueryPhase(.graphQuerySetup, observer: environment.queryPhaseObserver) {
            let graph = context.buildGraph(level: .symbol).graph
            let baseline = try loadBaseline()
            // 필터는 만들 때마다 기준 경로 표기를 파일 시스템에 묻는다. 진단마다 만들지 않는다.
            let pathFilter = configuration.pathFilter
            return QuerySession(
                graph: graph,
                lookup: GraphQueryIndex(graph: graph),
                foundFacts: nil,
                limitations: analysisLimitations(context: context, symbolGraph: graph),
                localFunctionDiagnostics: LocalFunctionDiagnostics.presenting(
                    context.localFunctionDiagnostics.filter { pathFilter.allows($0.location.path) }
                ),
                baselineFingerprints: baseline.map { Set($0.fingerprints) } ?? [],
                foundFactsBuildCount: 0
            )
        }
        if subjects.map({ $0.contains(where: { Self.isFound(session.lookup.resolve($0)) }) }) ?? true {
            session.installFoundFacts(makeFoundQueryFacts(in: context, graph: session.graph))
        }
        return session
    }

    func ensureFoundQueryFacts(
        in context: AnalysisContext, subjects: [String], session: inout QuerySession
    ) {
        guard session.foundFacts == nil,
              subjects.contains(where: { Self.isFound(session.lookup.resolve($0)) })
        else { return }
        session.installFoundFacts(makeFoundQueryFacts(in: context, graph: session.graph))
    }

    private func makeFoundQueryFacts(in context: AnalysisContext, graph: CodeGraph) -> FoundQueryFacts {
        measureQueryPhase(.foundFacts, observer: environment.queryPhaseObserver) {
            let report = ReachabilityAnalyzer(
                policy: makeRetentionPolicy(externalRetentions: context.externalRetentionIndex)
            ).analyzeReachability(graph: graph, snapshot: context.snapshot)
            return FoundQueryFacts(
                report: report, referenceEvidence: ReferenceEvidenceIndex(snapshot: context.snapshot, graph: graph)
            )
        }
    }

    private static func isFound(_ lookup: GraphNodeLookup) -> Bool {
        if case .found = lookup { return true }
        return false
    }

    func queryDocument(
        symbol subject: String,
        depth: Int,
        limit: Int,
        in session: QuerySession
    ) throws -> SymbolQueryDocument {
        var suggestions: [String: [GraphNode]] = [:]
        return try queryDocument(symbol: subject, depth: depth, limit: limit, in: session, suggestions: &suggestions)
    }

    /// 배치가 나눠 쓰는 notFound 추천 메모와 함께 답한다. 같은 이름을 다시 물으면 추천을 다시 계산하지 않는다.
    func queryDocument(
        symbol subject: String,
        depth: Int,
        limit: Int,
        in session: QuerySession,
        suggestions: inout [String: [GraphNode]]
    ) throws -> SymbolQueryDocument {
        try measureQueryPhase(.answer, observer: environment.queryPhaseObserver) {
            let graph = session.graph
            // `unusedCode` 는 설정과 무관하게 항상 심볼 레벨로 만든다. 여기서 설정값을
            // 실어 보내면 심볼 레벨 답을 모듈 레벨 답이라고 말하게 된다.
            let level = GraphLevel.symbol.rawValue

            let limitations = session.limitations

            switch session.lookup.resolve(subject) {
            case .notFound:
                // 오타가 오타라고 말만 하지 않는다. 그래프에 비슷한 이름이 있으면
                // 다시 물을 수 있는 모양(위치·USR 포함)으로 같이 보낸다.
                // 비슷한 이름이 없으면 키 자체를 만들지 않는다 — 빈 배열은
                // "추천이 비었다"는 매번 붙는 말이 된다.
                let similar = Self.candidates(
                    session.lookup.similarCandidates(to: subject, memo: &suggestions),
                    in: graph
                )
                return SymbolQueryDocument(
                    status: "notFound",
                    requested: subject,
                    level: level,
                    limitations: limitations,
                    candidates: similar.isEmpty ? nil : similar,
                    localFunctionDiagnostics: session.localFunctionDiagnostics
                )
            case let .ambiguous(candidates):
                return SymbolQueryDocument(
                    status: "ambiguous",
                    requested: subject,
                    level: level,
                    limitations: limitations,
                    candidates: Self.candidates(candidates, in: graph),
                    localFunctionDiagnostics: session.localFunctionDiagnostics
                )
            case let .found(node):
                guard let foundFacts = session.foundFacts else {
                    throw CartographError.invalidConfiguration(
                        path: projectPath, reason: "The query session has no prepared found-symbol facts."
                    )
                }
                return SymbolQueryDocument(
                    status: "found",
                    requested: subject,
                    level: level,
                    limitations: limitations,
                    result: try describeQuery(
                        of: node, report: foundFacts.report, in: graph,
                        depth: depth, limit: limit, baselineFingerprints: session.baselineFingerprints,
                        referenceEvidence: foundFacts.referenceEvidence
                    ),
                    localFunctionDiagnostics: session.localFunctionDiagnostics
                )
            }
        }
    }

    /// 후보 하나와 그것을 감싸는 타입 이름.
    struct OrderedCandidate {
        let node: GraphNode
        let container: String?
    }

    /// 정점 목록을 후보 문서로 바꾼다. 모호 판정과 notFound 추천이 같은 모양을 쓴다.
    static func candidates(
        _ nodes: [GraphNode], in graph: CodeGraph
    ) -> [SymbolQueryDocument.Candidate] {
        SymbolQueryDocument.presenting(nodes, in: graph)
    }

    /// 후보를 사람이 훑는 순서로 세운다.
    ///
    /// `sortedNodes` 는 USR 사전순이라, 이름이 전부 같은 122개에서 사람이 실제로 읽는
    /// 열(위치)이 무작위로 흩어진다. 파일과 줄로 세우면 같은 파일의 것이 붙어 나온다.
    static func orderedCandidates(_ nodes: [GraphNode], in graph: CodeGraph) -> [OrderedCandidate] {
        nodes
            .map { node in
                OrderedCandidate(
                    node: node,
                    container: graph.semanticParent(of: node.id).flatMap { graph.node($0)?.name }
                )
            }
            .sorted { lhs, rhs in
                let left = (lhs.node.location?.path ?? "", lhs.node.location?.line ?? 0, lhs.node.id.rawValue)
                let right = (rhs.node.location?.path ?? "", rhs.node.location?.line ?? 0, rhs.node.id.rawValue)
                return left < right
            }
    }

    /// 사람이 읽는 후보 목록.
    ///
    /// USR 만 늘어놓으면 고를 수 없다. 실제 앱에서 `body` 를 물으면 후보 127개가 나오고
    /// 그중 122개의 이름이 글자까지 같다. 사람이 읽고 고르는 값은 위치다.
    ///
    /// 그렇다고 전부 찍으면 127 × 2 줄이 터미널을 덮고, 그 안에서 고르는 일은 처음보다
    /// 어렵다. 앞의 것만 보여 주고 몇 개를 접었는지 말한 뒤, 전부 보는 방법을 알려 준다.
    static let shownCandidateLimit = 20

    static func describeCandidates(
        _ candidates: [GraphNode], for subject: String, in graph: CodeGraph
    ) -> String {
        let ordered = orderedCandidates(candidates, in: graph)
        let listed = ordered.prefix(shownCandidateLimit)
        // 후보 하나는 위치 줄과 USR 줄 두 줄이다. 경로 속 개행이 이 짝을 늘리지 못하게 줄로 나눠 둔다.
        let shown = listed.flatMap { candidate -> [String] in
            let site = candidate.node.location.map { "\($0.path):\($0.line)" } ?? "unknown location"
            let name = candidate.container.map { "\($0).\(candidate.node.name)" }
                ?? candidate.node.qualifiedName
            return ["  \(site)  \(candidate.node.kind.rawValue) \(name)",
                    "    \(candidate.node.usr ?? candidate.node.id.rawValue)"]
        }
        let omitted = ordered.count - listed.count
        let tail = omitted > 0
            ? ["  … and \(omitted) more. Run `cartograph query \(subject)` for the full list as JSON."]
            : []
        return printableLines(
            ["'\(subject)' matches \(candidates.count) declarations. Ask again with one of the names or USRs below:"]
                + shown + tail
        )
    }

    private func describeQuery(
        of node: GraphNode,
        report: ReachabilityReport,
        in graph: CodeGraph,
        depth: Int,
        limit: Int,
        baselineFingerprints: Set<String>,
        referenceEvidence: ReferenceEvidenceIndex
    ) throws -> SymbolQuery {
        let explanation = report.explain(node.id, in: graph)
        // 도달 가능한 정점에는 `dead` 가 애초에 진단을 내지 않는다. 그런데도 옛
        // 베이스라인 항목이 지문만 맞으면 억제되었다고 표시되어, "도달 가능한데
        // 팀이 억제했다"는 모순된 답이 나간다.
        let suppressed = explanation == .unreachable && Self.isSuppressed(node, by: baselineFingerprints)
        let neighborhood = GraphNeighborhood(graph: graph)
        let (usedBy, usedByTruncated) = neighborhood.usage(
            of: node.id, depth: depth, limit: limit, incoming: true
        )
        let (dependsOn, dependsOnTruncated) = neighborhood.usage(
            of: node.id, depth: depth, limit: limit, incoming: false
        )
        let (members, membersTruncated) = neighborhood.containment(of: node.id, limit: limit, incoming: false)
        let declaredIn = neighborhood.containment(of: node.id, limit: 1, incoming: true).neighbors.first
        var evidenceBudget = 200
        let describedUsers = Self.describe(usedBy, evidence: referenceEvidence, budget: &evidenceBudget)
        let describedDependencies = Self.describe(dependsOn, evidence: referenceEvidence, budget: &evidenceBudget)
        return SymbolQuery(
            subject: Self.describe(node),
            reachability: Self.describe(explanation, suppressedByBaseline: suppressed, in: graph),
            usedBy: describedUsers,
            dependsOn: describedDependencies,
            members: members.map { Self.describe($0) },
            declaredIn: declaredIn.map { Self.describe($0) },
            truncated: .init(
                usedBy: usedByTruncated,
                dependsOn: dependsOnTruncated,
                members: membersTruncated
            )
        )
    }

    /// 지문 집합 하나로 억제 여부를 답한다. 답마다 Set 을 다시 만들지 않는다.
    private static func isSuppressed(_ node: GraphNode, by fingerprints: Set<String>) -> Bool {
        fingerprints.contains(Self.unusedDiagnostic(for: node).fingerprint)
    }

    private static func encodeQuery(_ document: SymbolQueryDocument) throws -> String {
        try encodeSortedJSON(document)
    }

    /// 파일별 시각과 구문 읽기 실패를 같은 문맥에서 수집한다.
    ///
    /// 세션 세대 문맥이면 같은 스토어 시각의 결과를 세대 안에서 재사용한다(`generationLimitations`).
    /// 수집은 소스마다 경로 정규화와 stat 을 하므로, 같은 세대의 영향·테스트·점검 요청이 그 비용을
    /// 되풀이하지 않게 한다.
    func analysisLimitations(
        storeDate: Date? = nil,
        context: AnalysisContext? = nil,
        symbolGraph: CodeGraph? = nil
    ) -> [String] {
        // 외부 보존 파일의 기존 비교 기준은 유지한다. 소스 신선도는 수집기에서 파일별로 본다.
        let storeDate = storeDate ?? indexStoreDate()
        guard let context else {
            return collectLimitations(storeDate: storeDate, context: nil, symbolGraph: symbolGraph)
        }
        return context.generationLimitations(storeDate: storeDate, hasSymbolGraph: symbolGraph != nil) {
            collectLimitations(storeDate: storeDate, context: context, symbolGraph: symbolGraph)
        }
    }

    private func collectLimitations(
        storeDate: Date?, context: AnalysisContext?, symbolGraph: CodeGraph?
    ) -> [String] {
        var emptyIndexCounts: (total: Int, inScope: Int)?
        if allowsEmptyIndex, let context, context.snapshot.symbols.isEmpty {
            let counts = projectSourceCounts(inventory: context.projectFileInventory)
            emptyIndexCounts = (counts.total, counts.inScope)
        }
        return AnalysisLimitationCollector(
            configuration: configuration,
            fileSystem: environment.fileSystem,
            projectPath: projectPath,
            storeDate: storeDate,
            inventory: context?.projectFileInventory ?? projectFileInventory()
        ).collect(context: context, symbolGraph: symbolGraph, emptyIndexCounts: emptyIndexCounts)
    }

    /// 인덱스 스토어가 마지막으로 쓰인 시각. 찾지 못하면 신선도를 말하지 않는다.
    ///
    /// 모르는 것을 "최신"이라고 말하지 않는다. 항목이 없는 것과 신선하다는 것은
    /// 다르고, 후자를 사실이 아닌데 주장하면 그 위에서 삭제 결정이 내려진다.
    private func indexStoreDate() -> Date? {
        guard environment.indexProviderOverride == nil else { return nil }
        let locator = IndexStoreLocator(fileSystem: environment.fileSystem)
        // DerivedData 도 함께 본다. 넘기지 않으면 Xcode 로 빌드한 프로젝트에서만
        // 신선도를 말하지 못한다 — 하필 그쪽이 인덱스가 가장 자주 낡는 환경이다.
        guard let storePath = try? locator.locate(
            explicitPath: configuration.indexStorePath,
            projectPath: projectPath,
            derivedDataPath: configuration.derivedDataPath ?? environment.derivedDataPath
        ) else { return nil }
        // 스토어 루트의 수정 시각은 믿을 수 없다. SwiftPM 의 `.build/out` 처럼
        // 스토어를 품고 있는 상위 디렉터리를 가리키는 경우, 루트는 처음 만들어진
        // 날짜 그대로이고 실제 레코드는 `v5/units` 아래에 쌓인다. 실제로 이 저장소에서
        // 루트는 이틀 전, `v5/units` 는 방금이었다. 루트만 보면 매번 "인덱스가
        // 낡았다"고 알리게 되고, 매번 붙는 경보는 읽히지 않는다. 스토어를 고를 때와
        // 같은 정의를 써야 고른 스토어와 신선도의 기준 시각이 어긋나지 않는다.
        return locator.storeRecency(at: storePath)
    }

    private static func describe(
        _ neighbors: [GraphNeighborhood.Neighbor], evidence: ReferenceEvidenceIndex, budget: inout Int
    ) -> [SymbolQuery.Neighbor] {
        neighbors.map { neighbor in
            let detail = evidence.evidence(for: neighbor.hops, limit: min(20, budget))
            budget -= detail.items.count
            return describe(neighbor, referenceEvidence: detail)
        }
    }

    private static func describe(
        _ neighbor: GraphNeighborhood.Neighbor, referenceEvidence: ReferenceEvidence? = nil
    ) -> SymbolQuery.Neighbor {
        let node = neighbor.node
        return SymbolQuery.Neighbor(
            name: node.name,
            qualifiedName: node.qualifiedName,
            kind: node.kind.rawValue,
            usr: node.usr,
            module: node.module,
            edges: neighbor.edges.map(\.rawValue).sorted(),
            depth: neighbor.depth,
            location: node.location,
            referenceEvidence: referenceEvidence
        )
    }

    static func describe(_ node: GraphNode) -> SymbolQuery.Subject {
        SymbolQuery.Subject(node: node)
    }

    private static func describe(
        _ explanation: ReachabilityExplanation,
        suppressedByBaseline: Bool,
        in graph: CodeGraph
    ) -> SymbolQuery.Reachability {
        func names(_ path: [NodeID]) -> [String] {
            path.map { graph.node($0)?.qualifiedName ?? $0.rawValue }
        }
        switch explanation {
        case let .retained(reason):
            return .init(state: "retained", reason: reason, path: nil, suppressedByBaseline: suppressedByBaseline)
        case let .retainedByMember(inherited):
            return .init(
                state: "retainedByMember",
                reason: inherited.reason,
                path: names([inherited.member]),
                suppressedByBaseline: suppressedByBaseline
            )
        case let .reachable(path):
            return .init(state: "reachable", reason: nil, path: names(path), suppressedByBaseline: suppressedByBaseline)
        case .unreachable:
            return .init(state: "unreachable", reason: nil, path: nil, suppressedByBaseline: suppressedByBaseline)
        case .unknown:
            return .init(state: "unknown", reason: nil, path: nil, suppressedByBaseline: suppressedByBaseline)
        }
    }

    // MARK: - 브리지 사실

    /// Swift 소스에서 언어 경계의 사실을 모아 isthmus 가 읽는 문서로 만든다.
    ///
    /// 인덱스는 문자열을 모른다. 그런데 Dart 와 Swift 를 잇는 유일한 끈이
    /// `FlutterMethodChannel(name:)` 의 그 문자열이다. 구문에서 리터럴을 뽑고 인덱스에서
    /// USR 을 붙여야, isthmus 가 조인한 결과가 `--external-retentions` 로 돌아올 수 있다.
    ///
    /// - Parameter generatedAt: 문서에 적을 생성 시각. 테스트가 고정하려고 받는다.
    public func bridgeFacts(
        generatedAt: Date = Date(),
        target: BridgeFact.Target? = nil,
        messages: Bool = false,
        events: Bool = false,
        rnEvents: Bool = false
    ) throws -> BridgeFactsDocument {
        // 두 플래그를 함께 켜면 종류별 emit 가드가 서로를 상쇄해 어떤 사실도 나오지
        // 않는다. 조용히 빈 문서를 돌려주는 대신 설정 오류로 거절한다 — CLI 도 같은
        // 검사를 하지만 이 API 는 그 아래 공개 경계다.
        guard !(messages && events) else {
            throw CartographError.invalidConfiguration(path: projectPath, reason:
                "--messages and --events produce separate documents; pass one flag at a time.")
        }
        guard !rnEvents || (!messages && !events && target != .flutter) else {
            throw CartographError.invalidConfiguration(path: projectPath, reason:
                "--rn-events requires a separate React Native event document.")
        }
        let canonicalProject: String
        do {
            canonicalProject = try environment.fileSystem.realPath(at: projectPath)
        } catch let error as CocoaError where error.code == .featureUnsupported {
            throw CartographError.invalidConfiguration(path: projectPath, reason:
                "The provided FileSystem does not support realPath(at:). Implement it before exporting bridge facts.")
        } catch {
            let reason = "Could not resolve the project root: \(error.localizedDescription). "
                + "Check that it exists and is accessible."
            throw CartographError.invalidConfiguration(path: projectPath, reason: reason)
        }
        // 빈 인덱스 가드를 지나지 않는다. `bridges` 는 구문 스캔이 본체이고 인덱스는
        // USR 을 붙이는 데만 쓴다. 공개 플러그인 스캔은 인덱스 기여가 0인 상태로 도는
        // 것이 정상이라, 여기서 실패하면 그 용법이 통째로 막힌다.
        let inventory = projectFileInventory()
        let snapshot = try makeIndexSource(
            includeObjectiveCSources: true,
            includeExternalSymbols: true,
            includeSelfReferences: true,
            sourceRoots: inventory.sourceFiles,
            inventory: inventory
        ).provider.loadSnapshot()
        let sources = bridgeSourceFiles(inventory: inventory)
        let indexedDates = Dictionary((snapshot.sourceFreshnessDates ?? [:]).map {
            (ValueFlowSourceLoader.canonicalPath($0.key), $0.value)
        }, uniquingKeysWith: min)
        let freshPaths = Set(sources.compactMap { path -> String? in
            guard let indexed = indexedDates[ValueFlowSourceLoader.canonicalPath(path)],
                  let modified = environment.fileSystem.modificationDate(at: path), modified <= indexed
            else { return nil }
            return ValueFlowSourceLoader.canonicalPath(path)
        })
        let resolver = BridgeSymbolResolver(snapshot: snapshot, freshPaths: freshPaths)
        if rnEvents {
            var facts: [BridgeFact] = []
            var limitations = ["rn-event-scan-scope: only direct Swift RCTEventEmitter subclasses are scanned; Objective-C, Expo, codegen, wrappers, extensions, conditional compilation/imports and inherited emitter types are not resolved; shadowed identifiers exclude their file"]
            var unsupportedScopes: [String: Int] = [:]
            var unreadable = 0
            for path in sources where path.hasSuffix(".swift") {
                do {
                    let source = try environment.fileSystem.readText(at: path)
                    facts += resolver.resolve(ReactNativeEventScanner().scan(source: source, path: path) {
                        unsupportedScopes[$0, default: 0] += 1
                    })
                } catch {
                    unreadable += 1
                }
            }
            if unreadable > 0 { limitations.append("unreadable-sources: \(unreadable) Swift source(s) could not be read; native emissions may be absent") }
            limitations += externalDirectoryLinkLimitations(inventory)
            for reason in unsupportedScopes.keys.sorted() {
                limitations.append("unattributed-event-emits: \(unsupportedScopes[reason]!) source scope(s) were not scanned (\(reason))")
            }
            let missing = facts.count { $0.symbol?.usr == nil }
            if missing > 0 { limitations.append("missing-event-usrs: \(missing) native event emissions lack indexed identities") }
            let dynamic = facts.count { $0.isDynamic }
            if dynamic > 0 { limitations.append("dynamic-event-names: \(dynamic) native event emissions have non-literal names") }
            try BridgeFactsDocument.validateNames(facts, opaqueHandlerChannels: [])
            return BridgeFactsDocument(tool: .init(name: Cartograph.toolName, version: Cartograph.version),
                generatedAt: Self.bridgeTimestamp(generatedAt), project: canonicalProject, facts: facts,
                extraLimitations: limitations, version: 2, transport: "react-native-event")
        }
        var unreadable = 0
        var objectiveCSources = 0
        var ffiInteropSources = 0
        var sourceCache: [String: String] = [:]
        let firstPass = scanBridgeFiles(
            at: sources, resolver: resolver, resolvedValues: [:], canonicalizesPaths: false,
            messages: messages, events: events
        ) {
            path in
            guard let source = try? environment.fileSystem.readText(at: path) else { unreadable += 1; return nil }
            sourceCache[ValueFlowSourceLoader.canonicalPath(path)] = source
            if !path.hasSuffix(".swift") { objectiveCSources += 1 }
            if Self.containsFfiInteropEvidence(source) { ffiInteropSources += 1 }
            return source
        }
        var facts = firstPass.facts
        var opaqueHandlerChannels = firstPass.opaqueHandlerChannels
        let unscannedEventChannels = firstPass.unscannedEventChannels
        let unscannedMessageChannels = firstPass.unscannedMessageChannels
        let hasFreshDynamicFact = facts.contains { fact in
            guard fact.isDynamic, fact.location.path.hasSuffix(".swift"),
                  let indexed = indexedDates[ValueFlowSourceLoader.canonicalPath(fact.location.path)],
                  let modified = environment.fileSystem.modificationDate(at: fact.location.path) else { return false }
            return modified <= indexed
        }
        if hasFreshDynamicFact {
            let loaded = ValueFlowSourceLoader(fileSystem: environment.fileSystem, projectPath: projectPath,
                pathFilter: configuration.pathFilter).load(snapshot: snapshot, sourceSnapshot: sourceCache)
            let graph = ValueFlowAnalyzer().analyze(loaded.program)
            let resolved = ValueFlowBridgeConstants().resolve(in: graph)
            if !resolved.isEmpty {
                // 원래 사실을 위치별로 덧대지 않고 다시 스캔해 채널 바인딩과 핸들러가 같은 이름을 쓴다.
                let secondPass = scanBridgeFiles(
                    at: sources, resolver: resolver, resolvedValues: resolved, canonicalizesPaths: true,
                    messages: messages, events: events
                ) { sourceCache[ValueFlowSourceLoader.canonicalPath($0)] }
                facts = secondPass.facts
                opaqueHandlerChannels = secondPass.opaqueHandlerChannels
            }
        }
        let selectedFacts = target.map { selected in
            facts.filter { $0.target == selected }
        } ?? facts
        let includesFlutter = target != .reactNative
        var extraLimitations: [String] = []
        if unreadable > 0 {
            extraLimitations.append("unreadable-sources: \(unreadable) file(s) could not be read and were skipped")
        }
        extraLimitations += externalDirectoryLinkLimitations(inventory)
        if ffiInteropSources > 0 {
            extraLimitations.append(
                "unscanned-ffi-interop: \(ffiInteropSources) native source file(s) contain FFI/Dart C API evidence outside channel join coverage"
            )
        }
        if let target, selectedFacts.count != facts.count {
            extraLimitations.append(
                "target-filter: \(facts.count - selectedFacts.count) fact(s) did not match \(target.rawValue)"
            )
        }
        // 전송별 문서는 그 전송의 사실만 담는다. 섞으면 소비자가 transport 없는
        // 이웃 채널을 같은 메커니즘으로 오인해 조인한다.
        let outputFacts = messages ? selectedFacts.filter { $0.kind == .messageHandle }
            : events ? selectedFacts.filter { $0.kind == .streamHandle } : selectedFacts
        let isScopedDocument = includesFlutter && !messages && !events
        try BridgeFactsDocument.validateNames(outputFacts, opaqueHandlerChannels: isScopedDocument ? opaqueHandlerChannels : [])
        return BridgeFactsDocument(
            tool: .init(name: Cartograph.toolName, version: Cartograph.version),
            generatedAt: Self.bridgeTimestamp(generatedAt),
            project: canonicalProject,
            facts: outputFacts,
            // 전송별 문서에는 그 전송의 관측 공백을 실어야 "없다"와 "못 봤다"를
            // 소비자가 구분한다. ObjC 파일 수는 어떤 전송의 핸들러든 가릴 수 있어
            // 문서 구분 없이 실린다.
            unscannedEventChannels: isScopedDocument || events ? unscannedEventChannels : 0,
            unscannedMessageChannels: isScopedDocument || messages ? unscannedMessageChannels : 0,
            objectiveCSourceCount: objectiveCSources,
            extraLimitations: extraLimitations,
            opaqueHandlerChannels: isScopedDocument ? opaqueHandlerChannels : [],
            version: (messages || events) ? BridgeFactsDocument.messageVersion : BridgeFactsDocument.version,
            transport: messages ? "basic-message-channel" : events ? "event-channel" : nil
        )
    }

    /// 소스 파일들을 스캐너 한 벌에 흘려 보낸다.
    ///
    /// Swift 파일은 BridgeFactScanner, 그 밖은 React Native 매크로 스캐너와
    /// Objective-C Flutter 스캐너가 맡는다. 초회 스캔과 해석 상수를 얻은 뒤의
    /// 재스캔이 이 배치를 따로 두면, 네 번째 브리지 메커니즘이나 새 계수가
    /// 늘 때 한쪽만 고쳐지는 자리가 된다.
    ///
    /// 재스캔은 경로를 정규화해 기록하고(realpath 프로젝트와의 표기 일치),
    /// 채널 계수는 초회 패스만 센다 — 재스캔은 사실과 핸들러 표식만 갈아낀다.
    private func scanBridgeFiles(
        at paths: [String],
        resolver: BridgeSymbolResolver,
        resolvedValues: [SourceLocation: String],
        canonicalizesPaths: Bool,
        messages: Bool = false,
        events: Bool = false,
        sourceAt: (String) -> String?
    ) -> (facts: [BridgeFact], opaqueHandlerChannels: [String?], unscannedEventChannels: Int, unscannedMessageChannels: Int) {
        var facts: [BridgeFact] = []
        var dependencyBudget = 1_000_000
        var opaqueHandlerChannels: [String?] = []
        var unscannedEventChannels = 0
        var unscannedMessageChannels = 0
        for path in paths {
            guard let source = sourceAt(path) else { continue }
            if path.hasSuffix(".swift") {
                let scanPath = canonicalizesPaths ? LocalFileSystem.canonicalPath(path) : path
                let scanned = resolvedValues.isEmpty
                    ? BridgeFactScanner().scan(source: source, path: scanPath, messages: messages, events: events)
                    : BridgeFactScanner().scan(source: source, path: scanPath, resolvedValues: resolvedValues,
                                               messages: messages, events: events)
                facts += resolver.resolve(scanned.facts, handlerScopes: scanned.handlerScopes, dependencyBudget: &dependencyBudget)
                opaqueHandlerChannels += scanned.opaqueHandlerChannels
                unscannedEventChannels += scanned.unscannedEventChannels
                unscannedMessageChannels += scanned.unscannedMessageChannels
            } else {
                facts += resolver.resolve(ReactNativeMacroScanner().scanDeclarations(source: source, path: path))
                let scanned = ObjectiveCFlutterScanner().scan(source: source, path: path)
                facts += resolver.resolve(scanned.scannedFacts)
                opaqueHandlerChannels += scanned.opaqueHandlerChannels
            }
        }
        return (facts, opaqueHandlerChannels, unscannedEventChannels, unscannedMessageChannels)
    }

    /// 채널 계약이 덮지 못하는 네이티브 interop 표면 — C export, Dart C API, 동적 심볼 조회.
    /// 어휘 표식이라 주석 안에서도 양성이 나올 수 있다. 그래서 fact가 아니라 파일 수준
    /// 한계 근거로만 쓴다.
    private static let ffiInteropMarkers = [
        "@_cdecl", "@_silgen_name", "dlsym",
        "Dart_PostCObject", "dart_native_api.h", "dart_api_dl.h",
    ]

    private static func containsFfiInteropEvidence(_ source: String) -> Bool {
        ffiInteropMarkers.contains { source.contains($0) }
    }

    /// 구문 값 그래프를 실제 컴파일러 대상과 연결해 호출별 요약을 질의한다.
    public func valueFlowDocument(symbol subject: String, limits: ValueFlowLimits = ValueFlowLimits()) throws
        -> ValueFlowDocument {
        let source = try makeIndexSource(includeExternalSymbols: true, includeSelfReferences: true)
        let raw = try source.provider.loadSnapshot()
        let loaded = ValueFlowSourceLoader(fileSystem: environment.fileSystem, projectPath: projectPath,
            pathFilter: configuration.pathFilter).load(snapshot: raw)
        let symbols = AnalysisContext(snapshot: loaded.snapshot, pathFilter: configuration.pathFilter)
            .buildGraph(level: .symbol).graph
        let lookup = GraphQueryIndex(graph: symbols).resolve(subject)
        let empty = ValueFlowGraph(contexts: [], nodes: [], edges: [],
            limitations: loaded.program.limitations, iterations: 0, truncated: false)
        switch lookup {
        case .notFound:
            return ValueFlowDocument(subject: subject, status: "notFound", limits: limits, graph: empty)
        case let .ambiguous(candidates):
            return ValueFlowDocument(subject: subject, status: "ambiguous",
                candidates: candidates.map { $0.usr ?? $0.id.rawValue }.sorted(), limits: limits, graph: empty)
        case let .found(node):
            let targets = loaded.program.functions.filter { $0.symbolUSR == node.usr && node.usr != nil }
            guard !targets.isEmpty else {
                return ValueFlowDocument(subject: subject, status: "unavailable", symbolUSR: node.usr,
                    limits: limits, graph: empty)
            }
            let ids = Set(targets.map(\.id))
            let analyzer = ValueFlowAnalyzer(limits: limits)
            var graph = analyzer.analyze(loaded.program)
            if !graph.contexts.contains(where: { ids.contains($0.function) }) {
                graph = analyzer.analyze(loaded.program, roots: ids.sorted())
            }
            return ValueFlowDocument(subject: subject,
                status: targets.allSatisfy { $0.unavailableReason != nil } ? "unavailable" : "found",
                symbolUSR: node.usr, selectedContexts: graph.contexts.filter { ids.contains($0.function) }.map(\.id),
                limits: limits, graph: graph)
        }
    }

    /// JSON 결과를 출력하되 없는 심볼은 기존 조회와 같은 사용 오류로 표시한다.
    public func dataflow(symbol: String, limits: ValueFlowLimits = ValueFlowLimits()) throws -> CommandOutcome {
        let document = try valueFlowDocument(symbol: symbol, limits: limits)
        return CommandOutcome(output: try Self.encodeSortedJSON(document), subjectNotFound: document.status == "notFound")
    }

    /// `bridges` 명령. 항상 JSON 이다. 소비자는 사람이 아니라 isthmus 다.
    public func exportBridgeFacts(
        generatedAt: Date = Date(),
        asText: Bool = false,
        target: BridgeFact.Target? = nil,
        messages: Bool = false,
        events: Bool = false,
        rnEvents: Bool = false
    ) throws -> CommandOutcome {
        let document = try bridgeFacts(generatedAt: generatedAt, target: target, messages: messages, events: events, rnEvents: rnEvents)
        return CommandOutcome(output: asText ? document.renderText() : try Self.encodeSortedJSON(document))
    }

    /// Swift 소스에서 DB 관계 참조를 모아 isthmus 가 읽는 persistence 문서로 만든다.
    ///
    /// `bridges` 가 이름 경계를 읽는 것과 같은 원리다 — 인덱스는 문자열을 모르니
    /// `sqlite3_prepare(db, "DELETE FROM …")` 의 SQL 은 구문에서만 나온다. 여기서 낸
    /// `relation-use` 사실은 schemagraph 의 `relation-decl` 과 조인돼야 비로소
    /// "이 코드가 이 테이블을 쓴다"가 된다. 인덱스는 `bridges` 와 같은 이유로
    /// 읽는다 — 조인 결과가 `--external-retentions` 로 돌아오려면 USR 이 필요하다.
    ///
    /// - Parameter generatedAt: 문서에 적을 생성 시각. 테스트가 고정하려고 받는다.
    public func schemaFacts(generatedAt: Date = Date()) throws -> BridgeFactsDocument {
        let canonicalProject: String
        do {
            canonicalProject = try environment.fileSystem.realPath(at: projectPath)
        } catch let error as CocoaError where error.code == .featureUnsupported {
            throw CartographError.invalidConfiguration(path: projectPath, reason:
                "The provided FileSystem does not support realPath(at:). Implement it before exporting schema facts.")
        } catch {
            let reason = "Could not resolve the project root: \(error.localizedDescription). "
                + "Check that it exists and is accessible."
            throw CartographError.invalidConfiguration(path: projectPath, reason: reason)
        }
        let inventory = projectFileInventory()
        let snapshot = try makeIndexSource(
            includeObjectiveCSources: true,
            includeExternalSymbols: true,
            includeSelfReferences: true,
            sourceRoots: inventory.sourceFiles,
            inventory: inventory
        ).provider.loadSnapshot()
        let sources = schemaSourceFiles(inventory: inventory)
        let indexedDates = Dictionary((snapshot.sourceFreshnessDates ?? [:]).map {
            (ValueFlowSourceLoader.canonicalPath($0.key), $0.value)
        }, uniquingKeysWith: min)
        let freshPaths = Set(sources.compactMap { path -> String? in
            guard let indexed = indexedDates[ValueFlowSourceLoader.canonicalPath(path)],
                  let modified = environment.fileSystem.modificationDate(at: path), modified <= indexed
            else { return nil }
            return ValueFlowSourceLoader.canonicalPath(path)
        })
        let resolver = BridgeSymbolResolver(snapshot: snapshot, freshPaths: freshPaths)
        let scanner = SchemaFactScanner()
        var facts: [BridgeFact] = []
        var unreadable = 0
        var unjoinedDynamic = 0
        var skippedSqlLiterals = 0
        var coreDataReferences = 0
        var swiftDataReferences = 0
        var realmReferences = 0
        var unsupportedFrameworkFiles: [String: Int] = [:]
        var unsupportedFrameworkSources: Set<String> = []
        for path in sources {
            do {
                let source = try environment.fileSystem.readText(at: path)
                let result = scanner.scan(source: source, path: path)
                facts += resolver.resolve(result.facts)
                unjoinedDynamic += result.counts.unjoinedDynamic
                skippedSqlLiterals += result.counts.skippedSqlLiterals
                coreDataReferences += result.counts.coreDataReferences
                swiftDataReferences += result.counts.swiftDataReferences
                realmReferences += result.counts.realmReferences
                if !result.counts.unsupportedFrameworks.isEmpty {
                    unsupportedFrameworkSources.insert(path)
                }
                for framework in result.counts.unsupportedFrameworks {
                    unsupportedFrameworkFiles[framework, default: 0] += 1
                }
            } catch {
                unreadable += 1
            }
        }
        var limitations: [String] = []
        if unreadable > 0 {
            limitations.append("unreadable-sources: \(unreadable) file(s) could not be read and were skipped")
        }
        limitations += externalDirectoryLinkLimitations(inventory)
        if unjoinedDynamic > 0 {
            limitations.append(
                "unjoined-dynamic-relations: \(unjoinedDynamic) SQL argument(s) or relation operand(s) "
                    + "were not statically readable; their relations are uncounted"
            )
        }
        if skippedSqlLiterals > 0 {
            limitations.append(
                "skipped-sql-literals: \(skippedSqlLiterals) ungated literal(s) contained SQL verbs but not "
                    + "the uppercase form required for heuristic scanning; not counted"
            )
        }
        if coreDataReferences > 0 {
            limitations.append(
                "core-data-references: \(coreDataReferences) Core Data fetch/entity reference(s) were observed; "
                    + "entity names are not SQL catalog relations, so no facts were emitted for them"
            )
        }
        if swiftDataReferences > 0 {
            limitations.append(
                "swiftdata-references: \(swiftDataReferences) SwiftData model/fetch reference(s) were observed; "
                    + "predicate surfaces are not SQL catalog relations, so no facts were emitted for them"
            )
        }
        if realmReferences > 0 {
            limitations.append(
                "realm-references: \(realmReferences) Realm object reference(s) were observed; "
                    + "Realm objects are not SQL catalog relations, so no facts were emitted for them"
            )
        }
        if !unsupportedFrameworkFiles.isEmpty {
            let breakdown = unsupportedFrameworkFiles.keys.sorted()
                .map { "\($0) (\(unsupportedFrameworkFiles[$0] ?? 0))" }.joined(separator: ", ")
            limitations.append(
                "unsupported-db-frameworks: \(unsupportedFrameworkSources.count) source file(s) "
                    + "import persistence framework(s) outside the supported surface: \(breakdown)"
            )
        }
        let missingUSRs = facts.count { $0.symbol?.usr == nil }
        if missingUSRs > 0 {
            limitations.append("missing-relation-usrs: \(missingUSRs) relation-use fact(s) lack indexed identities")
        }
        try BridgeFactsDocument.validateNames(facts, opaqueHandlerChannels: [])
        return BridgeFactsDocument(
            tool: .init(name: Cartograph.toolName, version: Cartograph.version),
            generatedAt: Self.bridgeTimestamp(generatedAt),
            project: canonicalProject,
            facts: facts,
            extraLimitations: limitations
        )
    }

    /// `schema` 명령. 항상 JSON 이다. 소비자는 사람이 아니라 isthmus 다.
    public func exportSchemaFacts(generatedAt: Date = Date(), asText: Bool = false) throws -> CommandOutcome {
        let document = try schemaFacts(generatedAt: generatedAt)
        return CommandOutcome(output: asText ? document.renderText() : try Self.encodeSortedJSON(document))
    }

    /// route-call 문서의 USR 결합에 쓰는 인덱스 스냅샷. 인덱스가 없으면 nil 이다.
    ///
    /// `bridges` 와 달리 인덱스 없는 실행을 실패로 끝내지 않는다. route-call 의 본체는 구문 스캔이고
    /// 인덱스는 감싸는 선언의 USR 을 붙이는 데만 쓰므로, 자동 탐색이 스토어를 찾지 못하면
    /// `qualifiedName` 만 싣고 `missing-route-usrs:` 로 알린다. 사용자가 경로를 명시했다면 그 경로가
    /// 틀린 것이므로 그대로 실패한다.
    func routeIndexSnapshot(inventory: ProjectFileInventory? = nil) throws -> IndexSnapshot? {
        do {
            return try makeIndexSource(
                includeExternalSymbols: true,
                includeSelfReferences: true,
                sourceRoots: inventory?.sourceFiles,
                inventory: inventory
            ).provider.loadSnapshot()
        } catch CartographError.indexStoreNotFound where configuration.indexStorePath == nil {
            return nil
        } catch CartographError.indexStoreLibraryNotFound where configuration.indexStorePath == nil {
            return nil
        }
    }

    /// 교환 생산자가 요구하는 UTC 밀리초 세 자리 시각을 만든다.
    static func bridgeTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// 브리지 사실을 찾을 소스 파일. 분석 범위와 같은 경로 필터를 건다.
    ///
    /// 인덱스의 파일 목록이 아니라 디스크를 걷는다. 아직 빌드하지 않은 파일과
    /// Objective-C 파일은 인덱스에 없지만 사실은 거기에도 있다.
    private func bridgeSourceFiles(inventory: ProjectFileInventory? = nil) -> [String] {
        let filter = configuration.pathFilter
        let suffixes = [".swift"] + ReactNativeMacroScanner.sourceExtensions.map { "." + $0 }
        if let inventory {
            return inventory.sourceFiles.filter { path in
                suffixes.contains { suffix in path.hasSuffix(suffix) }
            }
        }
        return environment.fileSystem.recursiveFiles(
            under: projectPath,
            isIncluded: { path in filter.allows(path) && suffixes.contains { path.hasSuffix($0) } },
            shouldDescend: BuildArtifactDirectories.shouldDescend(into:)
        )
    }

    /// 관계 참조를 찾을 Swift 소스 파일. 분석 범위와 같은 경로 필터를 건다.
    ///
    /// 인덱스의 파일 목록이 아니라 디스크를 걷는다. 아직 빌드하지 않은 파일은
    /// 인덱스에 없지만 SQL 문자열은 거기에도 있다.
    func schemaSourceFiles(inventory: ProjectFileInventory? = nil) -> [String] {
        let filter = configuration.pathFilter
        if let inventory {
            return inventory.sourceFiles.filter { $0.hasSuffix(".swift") }
        }
        return environment.fileSystem.recursiveFiles(
            under: projectPath,
            isIncluded: { path in filter.allows(path) && path.hasSuffix(".swift") },
            shouldDescend: BuildArtifactDirectories.shouldDescend(into:)
        )
    }

    /// 키 순서를 고정한 JSON. 두 실행의 출력을 diff 할 수 있어야 한다.
    static func encodeSortedJSON(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder.cartographDefault()
        guard let text = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw CartographError.outputUnwritable(path: "<stdout>", underlying: "JSON is not UTF-8")
        }
        return text + "\n"
    }

    public func measureMetrics(level: GraphLevel? = nil) throws -> CommandOutcome {
        let context = try loadContext()
        let (graph, metrics, tolerance) = metrics(in: context, level: level)
        let diagnostics = AnalysisDiagnostics.diagnostics(for: metrics, thresholds: configuration.thresholds)
        let renderer = MetricsRenderer(tolerance: tolerance)

        let (reported, suppressed) = try filterAndApplyBaseline(diagnostics)
        // 지표도 CI 게이트다. 임계값 아래로 깨끗한 답이 낡은 인덱스 위에서
        // 나왔다면 그 사실이 답에 없어야 할 이유가 없다.
        let limitations = self.limitations(context: context, graph: graph, requestedLevel: level)

        let summary = ReportSummary(
            command: "metrics",
            subject: describe(graph),
            suppressedCount: suppressed,
            limitations: limitations
        )
        // sarif/checkstyle/xcode/github-actions 는 진단을 담는 형식이지 지표표를 담는 형식이
        // 아니다. 예전에는 이 형식들이 지표 JSON 을 그대로 받아, 확장자만 `.sarif` 인
        // 코드 스캐닝이 거부하는 문서가 나왔다.
        let baseVariants = PathFilter.variants(of: projectPath)
        let relativeReported = reported.map { $0.relative(toBaseVariants: baseVariants) }
        let output: String = switch configuration.reportFormat {
        case .json:
            try renderer.renderJSON(
                metrics,
                diagnostics: relativeReported,
                suppressedCount: suppressed,
                limitations: limitations
            )
        case .sarif, .checkstyle, .xcode, .githubActions:
            try DiagnosticReporterFactory.make(configuration.reportFormat).report(relativeReported, summary: summary)
        case .text:
            renderer.renderTable(metrics, limitations: limitations ?? [])
                + (reported.isEmpty
                    ? ""
                    : "\n" + (try DiagnosticReporterFactory.make(.text).report(relativeReported, summary: summary)))
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
        let context = try loadContext()
        let (graph, violations, unassigned) = try layerViolations(in: context, level: level)
        var diagnostics = AnalysisDiagnostics.diagnostics(for: violations)
        diagnostics += AnalysisDiagnostics.unassignedLayerDiagnostics(for: unassigned, in: graph)

        return try finish(
            diagnostics,
            command: "rules",
            subject: describe(graph),
            thresholdLimit: configuration.thresholds.maxRuleViolations,
            thresholdRule: AnalysisDiagnostics.Rule.layerViolation,
            // 레이어 미지정은 정보성이라 임계값 계산에 넣지 않는다.
            countedRules: [AnalysisDiagnostics.Rule.layerViolation],
            limitations: limitations(context: context, graph: graph, requestedLevel: level),
            caveat: emptyIndexCaveat(context)
        )
    }

    /// 명령 응답에 실릴 한계 목록. 알릴 것이 없으면 nil — 빈 배열은 매번 붙는 경보다.
    ///
    /// 그래프를 심볼 레벨로 만든 실행은 그 그래프를 재활용한다. 그 외 레벨은
    /// nil 을 넘기는데, 이 경우 심볼 그래프가 다시 만들어지는 것은 외부 보존
    /// 근거를 걸어 둔 프로젝트뿐이다 — 흔한 실행에 숨은 비용을 붙이지 않는다.
    private func limitations(
        context: AnalysisContext, graph: CodeGraph, requestedLevel: GraphLevel?
    ) -> [String]? {
        let effectiveLevel = requestedLevel ?? configuration.level
        let limitations = analysisLimitations(
            context: context,
            symbolGraph: effectiveLevel == .symbol ? graph : nil
        ) + context.buildGraph(level: effectiveLevel).sourceAttributionLimitations
        return limitations.isEmpty ? nil : limitations
    }

    // MARK: - 베이스라인

    /// 모든 명령의 진단을 한 번의 인덱스 읽기로 모은다.
    ///
    /// 지표 임계값 위반도 함께 담는다. `metrics` 는 베이스라인을 적용하는데
    /// `baseline` 이 그것을 기록하지 못하면 영원히 억제할 수 없는 진단이 생긴다.
    /// 순환도 같은 이유로 베이스라인을 적용하는 레벨마다 거둔다(`baselineCycleDiagnostics(in:)`).
    /// `fix` 가 베이스라인으로 거르는 두 경고도 같은 목록(`mechanicallyFixableDiagnostics`)으로 거둔다.
    public func collectAllDiagnostics() throws -> [Diagnostic] {
        let context = try loadContext()
        let (symbolGraph, unused) = unusedCode(in: context, computingSuperfluousIgnores: false)
        let (_, metricValues, _) = metrics(in: context)
        let (_, violations, _) = try layerViolations(in: context)

        return baselineCycleDiagnostics(in: context)
            + AnalysisDiagnostics.diagnostics(for: unused)
            + Self.mechanicallyFixableDiagnostics(for: unused, in: symbolGraph)
            + AnalysisDiagnostics.diagnostics(for: violations)
            + AnalysisDiagnostics.diagnostics(for: metricValues, thresholds: configuration.thresholds)
    }

    /// `check` 의 모듈·타입 순환과 `cycles` 의 설정 레벨 순환. 같은 지문은 한 번만 담는다.
    ///
    /// 순환 지문은 정점 ID 라 레벨마다 다르다. 모듈 이름 기록은 타입 USR 진단과 절대 맞지 않는다.
    /// Swift 는 모듈 순환을 막으므로 설정 레벨(기본 module)만 거두면 실제 순환인 타입 순환이 하나도
    /// 기록되지 않고, `check --strict` 는 baseline 뒤에도 기존 순환으로 계속 실패한다.
    /// 심볼 레벨 순환은 같은 두 타입 사이라면 타입 순환과 지문이 같아 중복을 거른다.
    private func baselineCycleDiagnostics(in context: AnalysisContext) -> [Diagnostic] {
        var fingerprints = Set<String>()
        return Set([GraphLevel.module, .type, configuration.level]).sorted().flatMap { level in
            let (graph, found) = cycles(in: context, level: level)
            return AnalysisDiagnostics.diagnostics(for: found, in: graph)
        }.filter { fingerprints.insert($0.fingerprint).inserted }
    }

    /// 현재 진단 상태를 베이스라인 파일로 기록한다.
    ///
    /// 커밋해서 다른 체크아웃(CI)에서 읽는 파일이므로 `unused-import` 지문의 파일 경로는 프로젝트 기준 상대
    /// 경로로 적는다. `loadBaseline()` 이 그 체크아웃의 루트 표기들로 되돌린다.
    public func writeBaseline(diagnostics: [Diagnostic], to path: String) throws -> CommandOutcome {
        let resolvedPath = resolveProjectRelativePath(path)
        let baseline = Baseline.capturing(diagnostics, relativeToBaseVariants: PathFilter.variants(of: projectPath))
        try BaselineStore(fileSystem: environment.fileSystem).write(baseline, to: resolvedPath)
        return CommandOutcome(output: "Wrote \(baseline.fingerprints.count) findings to \(resolvedPath)\n")
    }

    /// `--baseline`·`baseline_path` 로 이름 붙인 베이스라인 파일이 있는지 확인한다. 이름을 붙이지 않았으면 할 일이
    /// 없다.
    ///
    /// 베이스라인을 읽는 명령이 인덱스를 열기 전에 부르는 사전 확인이다. 읽는 자리(`loadBaseline()`)도 같은 확인을
    /// 하지만 인덱스를 다 읽은 뒤라, 경로 오타 하나를 알리려고 분석 시간을 다 쓰게 된다.
    ///
    /// - Throws: 파일이 없으면 `CartographError.missingBaseline(at:)` — 원인과 해결 방향을 담은 `invalidBaseline`.
    public func requireConfiguredBaseline() throws {
        _ = try configuredBaselinePath()
    }

    // MARK: - 내부 구현

    /// 진단에 리포트 스코프를 적용하고, 베이스라인을 읽어 보고 대상 진단과 억제 건수를 계산한다.
    ///
    /// - Parameter alreadyScoped: 호출자가 이미 범위를 적용했다. 순환은 구성원 기준으로 먼저 거르므로
    ///   (`scopedCycleDiagnostics`) 위치 기준으로 한 번 더 거르면 대표 정점이 범위 밖인 순환이 다시 빠진다.
    func filterAndApplyBaseline(
        _ diagnostics: [Diagnostic], alreadyScoped: Bool = false
    ) throws -> (reported: [Diagnostic], suppressedCount: Int) {
        let scoped = alreadyScoped ? diagnostics : (reportScope?.filtering(diagnostics) ?? diagnostics)
        let baseline = try loadBaseline()
        let reported = baseline?.filtering(scoped) ?? scoped
        let suppressed = scoped.count - reported.count
        return (reported, suppressed)
    }

    /// 순환은 대표 선언 한 줄이 아니라 강결합 요소 구성원 전체의 파일로 범위를 판정한다. 익스텐션 멤버도
    /// 포함한다.
    ///
    /// `check` 와 `cycles` 가 함께 쓴다. 두 명령이 범위를 따로 판정하면 같은 `--since` 가 명령마다
    /// 다른 순환을 보여 준다. 범위가 없으면 모든 순환의 진단을 그대로 만든다.
    func scopedCycleDiagnostics(
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

    /// 베이스라인 적용 → 임계값 검사 → 형식 적용.
    ///
    /// - Parameter alreadyScoped: `filterAndApplyBaseline` 과 같은 뜻이다.
    private func finish(
        _ diagnostics: [Diagnostic],
        command: String,
        subject: String,
        thresholdLimit: Int?,
        thresholdRule: String,
        countedRules: Set<String>? = nil,
        limitations: [String]? = nil,
        caveat: String? = nil,
        alreadyScoped: Bool = false,
        findingReviewOptions: FindingReviewOptions? = nil
    ) throws -> CommandOutcome {
        // 범위를 먼저 좁힌 뒤 베이스라인을 적용한다. 순서를 바꾸면 억제 건수가
        // 범위 밖의 것까지 세어, 사용자가 보는 숫자와 맞지 않는다.
        let (reported, suppressed) = try filterAndApplyBaseline(diagnostics, alreadyScoped: alreadyScoped)

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
        // 표기 펼치기는 기준 경로가 정해져 있으므로 실행당 한 번이면 충분하다.
        // 진단마다 하면 리포트마다 수천 번의 URL 연산이 붙는다.
        let baseVariants = PathFilter.variants(of: projectPath)
        let displayed = reported.map { $0.relative(toBaseVariants: baseVariants) }
        var output = try reporter.report(
            displayed,
            summary: ReportSummary(
                command: command,
                subject: subject,
                suppressedCount: suppressed,
                limitations: limitations,
                caveat: caveat
            )
        )
        if let findingReviewOptions {
            let review = try findingReviewDocument(diagnostics: displayed.sorted(), options: findingReviewOptions)
            output = try appendingFindingReview(review, toJSON: output)
        }
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
        in graph: CodeGraph,
        externalRetentions: ExternalRetentionIndex,
        projectPath: String
    ) throws -> CommandOutcome {
        let name = node.qualifiedName
        switch explanation {
        case let .retained(reason):
            let evidence = try evidenceLines(
                for: node, reason: reason, in: graph, externalRetentions: externalRetentions, projectPath: projectPath
            )
            return CommandOutcome(output: printableLines(
                retentionLead(name: name, node: node, reason: reason, in: graph) + evidence
            ))
        case let .retainedByMember(inherited):
            let memberNode = graph.node(inherited.member)
            let member = memberNode?.qualifiedName ?? inherited.member.rawValue
            let evidence = try memberNode.map {
                try evidenceLines(for: $0, reason: inherited.reason, in: graph,
                                  externalRetentions: externalRetentions, projectPath: projectPath)
            } ?? []
            return CommandOutcome(output: printableLines(
                ["\(name) is retained because its member \(member) is \(inherited.reason.explanation)."] + evidence
            ))
        case let .reachable(path):
            let trail = path.map { graph.node($0)?.qualifiedName ?? $0.rawValue }.joined(separator: " → ")
            return CommandOutcome(output: printableLines(["\(name) is reachable:", "  \(trail)"]))
        case .unreachable:
            return CommandOutcome(
                output: printableLines(["\(name) is not reachable from any retained root."]), findingCount: 1
            )
        case .unknown, nil:
            // 이 분기는 정점을 찾은 뒤에만 도달한다. "찾지 못했다"고 말하면
            // 사용자는 자기가 친 이름이 틀렸다고 오해한다.
            return CommandOutcome(
                output: printableLines(["Could not determine reachability for \(name)."]),
                findingCount: 1
            )
        }
    }

    /// 보존 설명의 첫 줄.
    ///
    /// `main.swift` 의 최상위 선언은 `@main` 과 같은 진입점 근거로 살아남지만, 그 근거의 문장은
    /// "@main 으로 선언됐다"고 말한다. 최상위 문장이 쓰지 않는 도우미까지 그렇게 설명하면, 사용자는
    /// 그 파일의 미사용 선언이 애초에 보고될 수 없다는 사실을 알 길이 없다. 근거 값(`entryPoint`)은
    /// 그대로 두고 문장만 실제 이유를 말한다. 최상위 코드 가상 심볼은 그 자체가 진입점이므로 제외한다.
    private static func retentionLead(
        name: String, node: GraphNode, reason: RetentionReason, in graph: CodeGraph
    ) -> [String] {
        guard reason == .entryPoint, !node.attributes.contains(.entryPoint),
              node.usr?.hasPrefix(IndexStoreMapping.topLevelCodeUSRPrefix) != true,
              RetentionPolicy.isTopLevelCodeDeclaration(node, in: graph)
        else { return ["\(name) is retained because it is \(reason.explanation)."] }
        return [
            "\(name) is retained because it is a top-level declaration in main.swift, the executable's entry point.",
            "  every top-level declaration in main.swift is kept, whether or not top-level code uses it",
        ]
    }

    /// 외부 보존 근거가 살린 선언이면 누가 어디서 불렀는지를 설명 줄로 덧붙인다.
    ///
    /// "외부 파일이 그렇다고 했다"로 끝나면 사용자는 그 파일을 열어 USR 을 찾아야 한다.
    /// 근거는 답의 일부다. 나열하지 못한 호출 수가 Int 범위를 넘으면 `impact` 와 같은 오류로 거부한다.
    /// 포화한 수는 정확한 수처럼 읽히고, 같은 근거 파일에 두 명령이 다른 답을 내게 된다.
    private static func evidenceLines(
        for node: GraphNode,
        reason: RetentionReason,
        in graph: CodeGraph,
        externalRetentions: ExternalRetentionIndex,
        projectPath: String
    ) throws -> [String] {
        guard reason == .externalBridge,
              let retention = externalRetentions.retention(
                  for: node, names: [ExternalRetentionIndex.syntaxQualifiedName(of: node, in: graph)]
              )
        else { return [] }
        guard retention.unlistedCallerCount != nil else { throw CallerOmissionOverflow.error(projectPath: projectPath) }
        // 이름으로 맞은 근거는 그렇다고 말한다. 동명 선언이 여럿이면 이 선언이 그 호출의
        // 진짜 대상이 아닐 수 있다. USR 로 맞은 것처럼 인용하면 지문 수준의 거짓말이다.
        let basis = retention.symbol.usr == nil
            ? ["  matched by qualified name, not by USR; every declaration with this name is kept"]
            : []
        return ["  evidence: \(retention.evidenceDescription)"] + basis
    }

    /// 설정과 프로젝트 경로를 반영한 보존 규칙.
    func makeRetentionPolicy(externalRetentions: ExternalRetentionIndex) -> RetentionPolicy {
        RetentionPolicy(
            options: configuration.retention,
            basePath: projectPath,
            externalRetentions: externalRetentions
        )
    }

    /// 설정이 가리키는 베이스라인. 상대 경로로 적힌 `unused-import` 지문은 이 프로젝트 루트의 표기들로 펼친다.
    ///
    /// 이름 붙인 파일은 없으면 실패하고(`configuredBaselinePath()`), 이름을 붙이지 않았으면 기본 파일을 있을 때만
    /// 읽는다.
    /// 진단 지문을 대조하는 자리(명령 마무리·통합 점검·설명·질의)가 모두 이 함수로 읽으므로, 펼치기를 여기서 한 번만
    /// 하면 다른 경로에 기록한 베이스라인도 어느 자리에서나 같은 발견을 거른다(`writeBaseline` 참고).
    func loadBaseline() throws -> Baseline? {
        let store = BaselineStore(fileSystem: environment.fileSystem)
        let baseline = try configuredBaselinePath().map { try store.load(from: $0) }
            ?? store.loadIfPresent(at: nil, basePath: projectPath)
        return baseline.map { $0.resolvingRelativePaths(againstBaseVariants: PathFilter.variants(of: projectPath)) }
    }

    /// 이름 붙인 베이스라인의 절대 경로. 상대 경로는 프로젝트 루트 기준이다. 이름을 붙이지 않았으면 nil 이다.
    ///
    /// 이름 붙인 파일은 기본 파일(`.cartograph-baseline.json`)처럼 "있으면 쓴다" 로 다루지 않는다. 그러면 오타 하나에
    /// 억제가 전부 사라져, 팀이 받아들인 발견이 새 발견으로 나와도 아무도 이유를 모른다. 기록(`writeBaseline`)은
    /// 이 함수를 거치지 않으므로 아직 없는 `baseline_path` 자리에 처음 쓸 수 있다.
    private func configuredBaselinePath() throws -> String? {
        guard let path = configuration.baselinePath else { return nil }
        let resolved = resolveProjectRelativePath(path)
        guard environment.fileSystem.fileExists(at: resolved) else {
            throw CartographError.missingBaseline(at: resolved)
        }
        return resolved
    }

    /// 상대 경로를 projectPath 기준으로 해결한다. 이미 절대 경로면 그대로 둔다.
    private func resolveProjectRelativePath(_ path: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        return (projectPath as NSString).appendingPathComponent(path)
    }

    func projectFileInventory() -> ProjectFileInventory {
        ProjectFileInventory(
            fileSystem: environment.fileSystem, projectPath: projectPath, pathFilter: configuration.pathFilter
        )
    }

    /// 교환 문서(routes·bridges·schema)에 싣는 루트 밖 디렉터리 링크 한계. 링크가 없으면 비어 있다.
    ///
    /// 이 문서들도 같은 inventory 로 소스를 읽으므로 링크 뒤의 사실이 빠진다. 분석 응답과 같은 문장으로
    /// 알려야 소비자가 "사실 없음"과 "읽지 않음"을 가른다.
    func externalDirectoryLinkLimitations(_ inventory: ProjectFileInventory) -> [String] {
        [AnalysisLimitationCollector.externalDirectoryLinkLimitation(
            inventory.externalDirectoryLinks, projectPath: projectPath),
         AnalysisLimitationCollector.sourceDiscoveryLimitation(
            inventory.discoveryExclusions, projectPath: projectPath)].compactMap { $0 }
    }

    private func describe(_ graph: CodeGraph) -> String {
        "\(graph.level.rawValue) graph · \(graph.nodeCount) nodes · \(graph.edgeCount) edges"
    }

    /// 인덱스 공급자와, 그것을 어떻게 골랐는지.
    ///
    /// 스토어 경로와 라이브러리 경로는 지금까지 공급자를 만들면서 계산했다가 버려졌다.
    /// 빈 인덱스를 설명하려면 둘 다 필요하고, `indexStoreDate()` 도 같은 값을 얻으려고
    /// 로케이터를 한 번 더 돌리고 있었다. 해석을 한 벌로 합친다.
    private struct IndexSource {
        let provider: any IndexProviding
        let storePath: String
        let libraryPath: String
        let origin: EmptyIndexFacts.StoreOrigin
        let inventory: ProjectFileInventory?
        var selectionLimitations: [String] = []
    }

    /// 명시한 생성 소스만 기존 인덱스 스토어에서 읽어 기본 분석 범위와 분리한다.
    func supplementalSnapshot(sourcePaths: [String]) throws -> IndexSnapshot {
        let allowed = Set(sourcePaths.map(LocalFileSystem.canonicalPath))
        guard !allowed.isEmpty else { return IndexSnapshot() }
        let source = try makeIndexSource(
            includeExternalSymbols: true,
            includeSelfReferences: true,
            sourceRoots: allowed.sorted(),
            pathFilter: .passthrough
        )
        let loaded = try source.provider.loadSnapshot()
        let local = loaded.symbols.filter {
            !$0.isExternal && allowed.contains(LocalFileSystem.canonicalPath($0.location.path))
        }
        let localUSRs = Set(local.map(\.usr))
        let references = loaded.references.filter { localUSRs.contains($0.sourceUSR) }
        let externalUSRs = Set(references.map(\.targetUSR)).subtracting(localUSRs)
        let external = loaded.symbols.filter { $0.isExternal && externalUSRs.contains($0.usr) }
        let dates = loaded.indexedFileDates.map { values in
            values.filter { allowed.contains(LocalFileSystem.canonicalPath($0.key)) }
        }
        let oldestDates = loaded.oldestIndexedFileDates.map { values in
            values.filter { allowed.contains(LocalFileSystem.canonicalPath($0.key)) }
        }
        return IndexSnapshot(symbols: local + external, references: references, indexedFileDates: dates,
            oldestIndexedFileDates: oldestDates,
            admittedHeaderPaths: loaded.admittedHeaderPaths.map { paths in
                paths.filter { allowed.contains(LocalFileSystem.canonicalPath($0)) }.sorted()
            },
            enumImpactFiles: loaded.enumImpactFiles?.filter {
                allowed.contains(LocalFileSystem.canonicalPath($0.path))
            }, sourceRecordAdmissions: loaded.sourceRecordAdmissions?.filter {
                allowed.contains(LocalFileSystem.canonicalPath($0.path))
            })
    }

    private func makeIndexSource(
        includeObjectiveCSources: Bool = false,
        includeExternalSymbols: Bool = false,
        includeSelfReferences: Bool = false,
        sourceRoots: [String]? = nil,
        pathFilter: PathFilter? = nil,
        inventory: ProjectFileInventory? = nil
    ) throws -> IndexSource {
        if let override = environment.indexProviderOverride {
            // 주입된 공급자에는 스토어가 없다. 모르는 것을 아는 척하지 않는다.
            return IndexSource(
                provider: override,
                storePath: "(injected provider)",
                libraryPath: "(injected provider)",
                origin: .injected,
                inventory: inventory
            )
        }

        let locator = IndexStoreLocator(fileSystem: environment.fileSystem)
        let selection = try locator.selection(
            explicitPath: configuration.indexStorePath,
            projectPath: projectPath,
            derivedDataPath: configuration.derivedDataPath ?? environment.derivedDataPath
        )
        let storePath = selection.path
        let libraryPath = try locator.locateLibrary(
            explicitPath: nil,
            developerDirectory: environment.developerDirectory
        )
        let effectivePathFilter = pathFilter ?? configuration.pathFilter
        let provider = IndexStoreProvider(
            configuration: .init(
                storePath: storePath,
                databasePath: IndexStoreProvider.defaultDatabasePath(
                    forStore: storePath,
                    libraryPath: libraryPath,
                    libraryModificationDate: environment.fileSystem.modificationDate(at: libraryPath)
                ),
                libraryPath: libraryPath,
                sourceRoots: sourceRoots ?? inventory?.sourceFiles ?? [projectPath],
                pathFilter: effectivePathFilter,
                includeExternalSymbols: includeExternalSymbols,
                includeObjectiveCSources: includeObjectiveCSources,
                includeSelfReferences: includeSelfReferences,
                readerMode: .raw,
                dependencyRoots: inventory.map { _ in [projectPath] }
            ),
            fileSystem: environment.fileSystem
        )
        return IndexSource(
            provider: provider,
            storePath: storePath,
            libraryPath: libraryPath,
            origin: storeOrigin(of: storePath),
            inventory: inventory,
            selectionLimitations: !selection.explicit && selection.candidateCount > 1 ? [
                "index-selection: selected \(String(reflecting: storePath)) from \(selection.candidateCount) "
                    + "existing candidates using newest store/unit-directory timestamp (lexical path tie-break). "
                    + "Recency does not prove source, target, or local package coverage; compare coverage and "
                    + "use --index-store to select the intended build explicitly."
            ] : []
        )
    }

    /// 스토어를 무엇을 보고 골랐는지. 자동 탐색이 남의 스토어를 집는 경우가 가장 흔하다.
    private func storeOrigin(of storePath: String) -> EmptyIndexFacts.StoreOrigin {
        if configuration.indexStorePath != nil { return .explicit }
        let derivedDataPath = configuration.derivedDataPath ?? environment.derivedDataPath
        if let derivedDataPath, storePath.hasPrefix(derivedDataPath) { return .derivedData }
        return .autoDetected
    }

    /// 빈 인덱스의 원인을 좁히는 사실들. 오류 경로에서만 계산한다.
    private func emptyIndexFacts(from source: IndexSource) -> EmptyIndexFacts {
        let counts = projectSourceCounts(inventory: source.inventory)
        return EmptyIndexFacts(
            projectPath: projectPath,
            resolvedProjectPath: LocalFileSystem.canonicalPath(projectPath),
            storePath: source.storePath,
            storeOrigin: source.origin,
            libraryPath: source.libraryPath,
            sourceFileCount: counts.total,
            filteredSourceFileCount: counts.inScope,
            objectiveCSourceCount: counts.objectiveC,
            unitCount: indexUnitCount(at: source),
            projectShape: IndexStoreLocator(fileSystem: environment.fileSystem)
                .projectShape(at: projectPath)
        )
    }

    /// 프로젝트 아래의 Swift 파일 수, 그중 경로 필터를 통과한 수, 그리고 Objective-C 소스 수.
    ///
    /// 세 숫자가 원인을 가른다. Swift 전체가 0이면 `--project` 가 틀렸거나 이 도구가 못 읽는
    /// 언어로 쓰인 프로젝트이고(Objective-C 수가 그 둘을 가른다), 전체는 있는데 통과가 0이면
    /// include/exclude 가 다 걸러 낸 것이다.
    private func projectSourceCounts(inventory: ProjectFileInventory? = nil)
        -> (total: Int, inScope: Int, objectiveC: Int) {
        let filter = configuration.pathFilter
        let files = inventory?.sourceFiles ?? environment.fileSystem.recursiveFiles(
            under: projectPath,
            isIncluded: { path in
                AnalysisLimitationCollector.sourceSuffixes.contains { path.hasSuffix($0) }
            },
            shouldDescend: BuildArtifactDirectories.shouldDescend(into:)
        )
        let allFiles = inventory?.allSourceFiles ?? files
        let swiftFiles = allFiles.filter { $0.hasSuffix(".swift") }
        return (
            swiftFiles.count,
            swiftFiles.count { filter.allows($0) },
            allFiles.count { $0.hasSuffix(".m") || $0.hasSuffix(".mm") }
        )
    }

    /// 스토어가 담고 있는 유닛 수. 셀 수 없으면 nil 을 돌려 아무 말도 하지 않는다.
    private func indexUnitCount(at source: IndexSource) -> Int? {
        guard source.origin != .injected else { return nil }
        for directory in [source.storePath + "/v5/units", source.storePath + "/units"] {
            if let entries = try? environment.fileSystem.contentsOfDirectory(at: directory) {
                return entries.count
            }
        }
        return nil
    }
}
