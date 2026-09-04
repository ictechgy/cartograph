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

    /// 보고 범위. nil 이면 발견을 전부 보고한다.
    ///
    /// 설정 파일이 아니라 생성 인자로 받는다. 변경된 파일 목록은 실행할 때마다
    /// 달라지는 값이라 파일에 적을 수 있는 성질이 아니다.
    private let reportScope: ReportScope?

    public init(
        configuration: CartographConfiguration,
        environment: CartographEnvironment = .live(),
        reportScope: ReportScope? = nil
    ) {
        self.configuration = configuration
        self.environment = environment
        self.reportScope = reportScope
    }

    /// 분석 대상 프로젝트 루트.
    public var projectPath: String {
        configuration.projectPath ?? environment.fileSystem.currentDirectoryPath
    }

    // MARK: - 인덱스

    /// 인덱스를 읽고 구문 정보로 보강한 스냅샷.
    public func loadSnapshot() throws -> IndexSnapshot {
        let raw = try makeIndexProvider().loadSnapshot()
        return SnapshotEnricher(
            fileSystem: environment.fileSystem,
            retention: configuration.retention,
            cachePath: environment.usesSyntaxCache
                ? SourceFactsCache.defaultPath(forProject: projectPath)
                : nil
        )
            .enrich(
                raw,
                interfaceBuilderRoots: configuration.retention.retainInterfaceBuilder ? [projectPath] : [],
                pathFilter: configuration.pathFilter
            )
    }

    /// 인덱스를 한 번만 읽어 만든 분석 문맥.
    public func loadContext() throws -> AnalysisContext {
        // 근거 파일을 인덱스보다 먼저 읽는다. 파일이 깨졌을 때 인덱스 없는 프로젝트에서도
        // 그 오류가 보여야 CLI 계약 검증이 이 경로를 실제로 증명한다.
        let externalRetentions = try ExternalRetentionStore(fileSystem: environment.fileSystem)
            .loadIfConfigured(at: configuration.externalRetentionsPath)
        return AnalysisContext(
            snapshot: try loadSnapshot(),
            pathFilter: configuration.pathFilter,
            edgeKinds: configuration.edgeKinds,
            externalRetentions: externalRetentions
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
    public func unusedCode(
        in context: AnalysisContext,
        findingTestOnlyCode: Bool = false
    ) -> (graph: CodeGraph, report: UnusedCodeReport) {
        let graph = context.buildGraph(level: .symbol).graph
        let analyzer = ReachabilityAnalyzer(
            policy: makeRetentionPolicy(externalRetentions: context.externalRetentionIndex),
            options: .init(findsTestOnlyCode: findingTestOnlyCode)
        )
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

    /// - Parameter reportingTestOnlyCode: 테스트·프리뷰만 붙잡고 있는 선언도 함께
    ///   알린다. 죽은 코드가 아니므로 정보로만 보고하고 종료 코드에는 영향을 주지
    ///   않는다.
    public func detectUnusedCode(reportingTestOnlyCode: Bool = false) throws -> CommandOutcome {
        let context = try loadContext()
        let (graph, report) = unusedCode(in: context, findingTestOnlyCode: reportingTestOnlyCode)
        return try finish(
            AnalysisDiagnostics.diagnostics(for: report)
                + AnalysisDiagnostics.testOnlyDiagnostics(for: report),
            command: "dead",
            subject: "\(describe(graph)) · \(report.reachableCount)/\(report.totalCount) reachable",
            thresholdLimit: configuration.thresholds.maxUnusedSymbols,
            thresholdRule: AnalysisDiagnostics.Rule.unusedSymbol,
            // 테스트 전용은 정보성이라 임계값과 --strict 계산에 넣지 않는다.
            countedRules: [AnalysisDiagnostics.Rule.unusedSymbol],
            // 미사용 목록은 에이전트가 삭제의 출발점으로 삼는 답이다. `query` 처럼 한계를 싣는다.
            limitations: analysisLimitations(context: context, symbolGraph: graph)
        )
    }

    /// 특정 선언이 왜 살아 있는지 사람이 읽는 문장으로 설명한다.
    public func explainRetention(of subject: String) throws -> CommandOutcome {
        // 그래프를 두 번 만들지 않는다. 질의가 이미 만든 것을 그대로 받는다.
        let context = try loadContext()
        let (graph, lookup, explanation) = retentionExplanation(of: subject, in: context)

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
            let outcome = Self.describeExplanation(
                explanation, for: node, in: graph, externalRetentions: context.externalRetentionIndex
            )
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

    /// 특정 정점이 어느 순환에 속하는지 사람이 읽는 문장으로 설명한다.
    ///
    /// "스무 개가 서로 얽혀 있다"는 보고는 정확하지만 손댈 곳을 알려 주지 않는다.
    /// 하나의 정점을 물었을 때 그것이 낀 구체적인 순환과 끊을 후보를 보여 주어야
    /// 실제로 행동할 수 있다.
    public func explainCycles(of subject: String, level: GraphLevel? = nil) throws -> CommandOutcome {
        let (graph, found) = cycles(in: try loadContext(), level: level)
        let lookup = NodeLookup.resolve(subject, in: graph)
        switch lookup {
        case .notFound:
            return CommandOutcome(output: "No node matches '\(subject)'.\n", subjectNotFound: true)
        case let .ambiguous(candidates):
            return CommandOutcome(output: Self.describeAmbiguity(subject, candidates: candidates))
        case let .found(node):
            // 참여 판정은 강한 연결 요소로 한다. 대표 경로에만 있는지를 보면,
            // 같은 묶음에 있으면서 대표 경로에 뽑히지 않은 정점에 "순환에 없다"고
            // 거짓말을 하게 된다. 설명이 틀리는 것은 보고가 틀리는 것보다 나쁘다.
            // 사용자가 그 설명을 믿고 코드를 건드리기 때문이다.
            let involved = found.filter { $0.component.contains(node.id) }
            guard !involved.isEmpty else {
                return CommandOutcome(output: "\(node.qualifiedName) is not part of any cycle.\n")
            }
            let lines = involved.map { Self.describeCycle($0, for: node.id, in: graph) }
            return CommandOutcome(
                output: "\(node.qualifiedName) is part of \(involved.count) cycle(s):\n"
                    + lines.joined(separator: "\n") + "\n",
                findingCount: involved.count
            )
        }
    }

    /// 특정 정점이 왜 그 레이어에 속하는지, 어떤 규칙이 걸리는지 설명한다.
    public func explainRules(of subject: String, level: GraphLevel? = nil) throws -> CommandOutcome {
        let context = try loadContext()
        let graph = context.buildGraph(level: level ?? configuration.level).graph
        let lookup = NodeLookup.resolve(subject, in: graph)
        switch lookup {
        case .notFound:
            return CommandOutcome(output: "No node matches '\(subject)'.\n", subjectNotFound: true)
        case let .ambiguous(candidates):
            return CommandOutcome(output: Self.describeAmbiguity(subject, candidates: candidates))
        case let .found(node):
            let evaluator = LayerRuleEvaluator(layers: configuration.layers, rules: configuration.rules)
            return CommandOutcome(output: Self.describeLayer(of: node, using: evaluator))
        }
    }

    private static func describeAmbiguity(_ subject: String, candidates: [GraphNode]) -> String {
        let list = candidates.map { "  \($0.qualifiedName)  \($0.usr ?? $0.id.rawValue)" }
        return "'\(subject)' matches \(candidates.count) declarations. "
            + "Pass one of these USRs instead:\n" + list.joined(separator: "\n") + "\n"
    }

    private static func describeCycle(
        _ cycle: DependencyCycle,
        for node: NodeID,
        in graph: CodeGraph
    ) -> String {
        let trail = cycle.path.map { graph.node($0)?.qualifiedName ?? $0.rawValue }
        var line = "  " + (trail + [trail[0]]).joined(separator: " → ")
        // 대표 경로에 없는 정점에게 이 경로를 그대로 보여 주면 자기 이름을 못 찾는다.
        // 같은 묶음에 있다는 사실과 대표 경로를 구분해서 말한다.
        if !cycle.path.contains(node) {
            line = "  in the same tangle, whose representative cycle is:\n  " + line.dropFirst(2)
        }
        if let edge = cycle.suggestedEdgeToBreak {
            let source = graph.node(edge.source)?.qualifiedName ?? edge.source.rawValue
            let target = graph.node(edge.target)?.qualifiedName ?? edge.target.rawValue
            line += "\n      weakest link: \(source) → \(target)"
                + " (\(edge.kind.rawValue), \(edge.weight) references)"
        }
        return line
    }

    private static func describeLayer(of node: GraphNode, using evaluator: LayerRuleEvaluator) -> String {
        let assignment = evaluator.assignment(of: node)
        guard let match = assignment.match else {
            return "\(node.qualifiedName) belongs to no layer.\n"
                + "  checked: " + assignment.candidates.joined(separator: ", ") + "\n"
        }
        var output = "\(node.qualifiedName) is in layer '\(match.layer)'.\n"
            + "  matched: \(match.candidate) against '\(match.pattern)'\n"
        let rules = evaluator.rules(from: match.layer)
        guard !rules.isEmpty else {
            output += "  no rule starts from '\(match.layer)', so nothing is enforced here.\n"
            return output
        }
        output += "  rules from '\(match.layer)':\n"
        for rule in rules {
            output += "    \(rule.displayName)\n"
        }
        return output
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
        let text = try Self.encodeQuery(document)
        return CommandOutcome(output: text, subjectNotFound: document.status == "notFound")
    }

    /// `query` 가 내보낼 문서를 만든다. 인코딩과 종료 코드는 부르는 쪽이 정한다.
    public func queryDocument(symbol subject: String, depth: Int = 1, limit: Int = 50) throws -> SymbolQueryDocument {
        let context = try loadContext()
        let (graph, report) = unusedCode(in: context)
        // `unusedCode` 는 설정과 무관하게 항상 심볼 레벨로 만든다. 여기서 설정값을
        // 실어 보내면 심볼 레벨 답을 모듈 레벨 답이라고 말하게 된다.
        let level = GraphLevel.symbol.rawValue

        let limitations = analysisLimitations(context: context, symbolGraph: graph)

        switch NodeLookup.resolve(subject, in: graph) {
        case .notFound:
            return SymbolQueryDocument(
                status: "notFound", requested: subject, level: level, limitations: limitations
            )
        case let .ambiguous(candidates):
            return SymbolQueryDocument(
                status: "ambiguous",
                requested: subject,
                level: level,
                limitations: limitations,
                candidates: candidates.map {
                    .init(qualifiedName: $0.qualifiedName, usr: $0.usr ?? $0.id.rawValue)
                }
            )
        case let .found(node):
            return SymbolQueryDocument(
                status: "found",
                requested: subject,
                level: level,
                limitations: limitations,
                result: try describeQuery(of: node, report: report, in: graph, depth: depth, limit: limit)
            )
        }
    }

    private func describeQuery(
        of node: GraphNode,
        report: UnusedCodeReport,
        in graph: CodeGraph,
        depth: Int,
        limit: Int
    ) throws -> SymbolQuery {
        let explanation = report.explain(node.id, in: graph)
        // 도달 가능한 정점에는 `dead` 가 애초에 진단을 내지 않는다. 그런데도 옛
        // 베이스라인 항목이 지문만 맞으면 억제되었다고 표시되어, "도달 가능한데
        // 팀이 억제했다"는 모순된 답이 나간다.
        let suppressed = try explanation == .unreachable && isSuppressedByBaseline(node)
        let (usedBy, usedByTruncated) = Self.neighbors(
            of: node.id, in: graph, depth: depth, limit: limit, incoming: true
        )
        let (dependsOn, dependsOnTruncated) = Self.neighbors(
            of: node.id, in: graph, depth: depth, limit: limit, incoming: false
        )
        let (members, membersTruncated) = Self.containment(of: node.id, in: graph, limit: limit, incoming: false)
        let declaredIn = Self.containment(of: node.id, in: graph, limit: 1, incoming: true).neighbors.first
        return SymbolQuery(
            subject: Self.describe(node),
            reachability: Self.describe(explanation, suppressedByBaseline: suppressed, in: graph),
            usedBy: usedBy,
            dependsOn: dependsOn,
            members: members,
            declaredIn: declaredIn,
            truncated: .init(
                usedBy: usedByTruncated,
                dependsOn: dependsOnTruncated,
                members: membersTruncated
            )
        )
    }

    private func isSuppressedByBaseline(_ node: GraphNode) throws -> Bool {
        guard let baseline = try loadBaseline() else { return false }
        return baseline.filtering([Self.unusedDiagnostic(for: node)]).isEmpty
    }

    private static func encodeQuery(_ document: SymbolQueryDocument) throws -> String {
        try encodeSortedJSON(document)
    }

    /// 이 분석이 보지 못하는 채널을 프로젝트에서 실제로 찾아 알린다.
    ///
    /// README 의 한계 목록을 문서에만 두면 소비자는 읽지 않는다. 특히 에이전트는
    /// 읽지 않는다. 눈앞의 답에 실어야 그 답을 어디까지 믿을지 스스로 정할 수 있다.
    func analysisLimitations(
        storeDate: Date? = nil,
        context: AnalysisContext? = nil,
        symbolGraph: CodeGraph? = nil
    ) -> [String] {
        // 한 번만 걷는다. 분석 범위와 같은 경로 필터를 걸어야 그래프가 보지 않는
        // 파일까지 세지 않는다. 범위 밖의 파일을 한계로 알리면 매번 붙는 경보가
        // 되고, 매번 붙는 경보는 읽히지 않는다.
        let filter = configuration.pathFilter
        let storeDate = storeDate ?? indexStoreDate()
        let files = environment.fileSystem.recursiveFiles(
            under: projectPath,
            isIncluded: { path in
                filter.allows(path) && Self.limitationSuffixes.contains { path.hasSuffix($0) }
            },
            shouldDescend: BuildArtifactDirectories.shouldDescend(into:)
        )

        func count(_ suffixes: String...) -> Int {
            files.count { path in suffixes.contains { path.hasSuffix($0) } }
        }
        let objectiveCCount = count(".m", ".mm")
        let interfaceBuilderCount = count(".xib", ".storyboard")
        let swiftFiles = files.filter { $0.hasSuffix(".swift") }
        let newerThanStore = storeDate.map { built in
            swiftFiles.count { (environment.fileSystem.modificationDate(at: $0) ?? .distantPast) > built }
        } ?? 0

        var result: [String] = []
        if objectiveCCount > 0 {
            result.append(
                "objective-c-sources: \(objectiveCCount) file(s) are not analysed, "
                    + "so a Swift declaration used only from Objective-C looks unreached"
            )
        }
        if interfaceBuilderCount > 0 {
            result.append(
                "interface-builder-documents: \(interfaceBuilderCount) document(s) are matched by "
                    + "custom class name only, never connection by connection"
            )
        }
        if newerThanStore > 0 {
            result.append(
                "index-staleness: \(newerThanStore) of \(swiftFiles.count) source file(s) changed after the "
                    + "index store was written, so a call added since the last build is not here yet"
            )
        }
        if !configuration.include.isEmpty || !configuration.exclude.isEmpty {
            result.append(
                "configured-path-filter: include/exclude patterns are in effect, so an empty "
                    + "'usedBy' can mean the caller was filtered out rather than absent"
            )
        }
        if !configuration.edgeKinds.isEmpty {
            result.append(
                "configured-edge-kinds: only "
                    + configuration.edgeKinds.map(\.rawValue).sorted().joined(separator: ", ")
                    + " edges are in the graph, so other relations are invisible here"
            )
        }
        result.append(
            "single-configuration: the index store knows only the configuration that was built, "
                + "so declarations behind an uncompiled #if branch do not exist here"
        )
        result += externalRetentionLimitations(in: context, symbolGraph: symbolGraph, storeDate: storeDate)
        return result
    }

    /// 외부 보존 근거가 걸려 있으면 그 사실과 신선도를 알린다.
    ///
    /// `retained` 에 `externalBridge` 가 붙은 답은 인덱스가 아니라 그 파일을 믿은 것이다.
    /// 파일이 낡았으면 이름을 바꾼 핸들러의 근거가 아무것도 가리키지 않게 되고,
    /// 그 수를 세어 주지 않으면 소비자는 파일이 최신이라고 믿는다.
    private func externalRetentionLimitations(
        in context: AnalysisContext?,
        symbolGraph: CodeGraph?,
        storeDate: Date?
    ) -> [String] {
        guard let context, let document = context.externalRetentions else { return [] }
        let index = context.externalRetentionIndex
        var result = [
            "external-retentions: \(index.count) retention(s) from \(document.provenanceDescription) are in "
                + "effect, so a 'retained' answer with reason 'externalBridge' rests on that file, not on the index"
        ]
        // 부르는 쪽이 이미 만든 심볼 그래프를 받는다. 여기서 다시 만들면 `query` 한 번에
        // 그래프를 두 번 짓는다. 인덱스 읽기 다음으로 비싼 단계다.
        let graph = symbolGraph ?? context.buildGraph(level: .symbol).graph
        let unmatched = index.unmatchedCount(in: graph)
        if unmatched > 0 {
            result.append(
                "external-retentions-unmatched: \(unmatched) of \(index.count) retention(s) name no declaration "
                    + "in this index, so the file may predate a rename or a rebuild"
            )
        }
        // 이름만 있는 근거가 여러 선언에 맞으면 전부 살린다. 확신이 없으면 살리는 쪽이
        // 이 도구의 규칙이지만, 그렇게 살아난 것이 있다는 사실은 알려야 한다.
        let ambiguous = index.ambiguousNameMatchCount(in: graph)
        if ambiguous > 0 {
            result.append(
                "external-retentions-ambiguous: \(ambiguous) name(s) from retentions without a USR match more than "
                    + "one declaration, and every one of those declarations is kept"
            )
        }
        // 파일이 인덱스보다 오래됐으면 그 사이의 이름 변경을 모른다. 날짜를 보여 주기만
        // 하면 판단은 사용자 몫인데, 비교는 이쪽이 할 수 있다.
        if let generated = document.generatedAt.flatMap(Self.parseISO8601),
           let built = storeDate, generated < built {
            result.append(
                "external-retentions-stale: the retentions file (\(document.generatedAt ?? "")) predates the index "
                    + "store, so it does not know about declarations renamed or added since"
            )
        }
        return result
    }

    /// 한계 목록을 세는 데 필요한 확장자. 다른 파일은 걷지도 담지도 않는다.
    private static let limitationSuffixes = [".m", ".mm", ".xib", ".storyboard", ".swift"]

    /// 인덱스 스토어가 마지막으로 쓰인 시각. 찾지 못하면 신선도를 말하지 않는다.
    ///
    /// 모르는 것을 "최신"이라고 말하지 않는다. 항목이 없는 것과 신선하다는 것은
    /// 다르고, 후자를 사실이 아닌데 주장하면 그 위에서 삭제 결정이 내려진다.
    private func indexStoreDate() -> Date? {
        guard environment.indexProviderOverride == nil else { return nil }
        let locator = IndexStoreLocator(fileSystem: environment.fileSystem)
        guard let storePath = try? locator.locate(
            explicitPath: configuration.indexStorePath,
            projectPath: projectPath
        ) else { return nil }
        // 스토어 루트의 수정 시각은 믿을 수 없다. SwiftPM 의 `.build/out` 처럼
        // 스토어를 품고 있는 상위 디렉터리를 가리키는 경우, 루트는 처음 만들어진
        // 날짜 그대로이고 실제 레코드는 `v5/units` 아래에 쌓인다. 실제로 이 저장소에서
        // 루트는 이틀 전, `v5/units` 는 방금이었다. 루트만 보면 매번 "인덱스가
        // 낡았다"고 알리게 되고, 매번 붙는 경보는 읽히지 않는다.
        let markers = [storePath, storePath + "/v5/units", storePath + "/units"]
        return markers.compactMap { environment.fileSystem.modificationDate(at: $0) }.max()
    }

    private static func describe(
        _ node: GraphNode,
        reachedBy edges: [String],
        depth: Int
    ) -> SymbolQuery.Neighbor {
        SymbolQuery.Neighbor(
            name: node.name,
            qualifiedName: node.qualifiedName,
            kind: node.kind.rawValue,
            usr: node.usr,
            module: node.module,
            edges: edges,
            depth: depth,
            // 선언 위치다. 사용 지점이 아니다. 이웃이 subject 를 어느 줄에서 쓰는지는
            // 이 그래프가 들고 있지 않다.
            location: node.location
        )
    }

    private static func describe(_ node: GraphNode) -> SymbolQuery.Subject {
        SymbolQuery.Subject(
            name: node.name,
            qualifiedName: node.qualifiedName,
            kind: node.kind.rawValue,
            module: node.module,
            usr: node.usr,
            accessibility: node.accessibility.rawValue,
            location: node.location
        )
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

    /// 사용 의미가 있는 간선만 따라 이웃을 모은다.
    ///
    /// 깊이와 개수를 모두 제한한다. 전이 의존자 수천 개는 결국 또 하나의 덤프이고,
    /// 이 명령이 존재하는 이유가 덤프를 만들지 않는 것이다.
    /// 담는 관계(`member` 간선)만 한 단계 따라간다.
    ///
    /// 쓰는 관계와 섞지 않는다. 타입이 멤버를 "쓴다"고 말하는 것은 사실이 아니고,
    /// 그렇다고 빼 버리면 타입에 물었을 때 답이 비어 나온다.
    private static func containment(
        of start: NodeID,
        in graph: CodeGraph,
        limit: Int,
        incoming: Bool
    ) -> (neighbors: [SymbolQuery.Neighbor], truncated: Bool) {
        let edges = incoming ? graph.incomingEdges(to: start) : graph.outgoingEdges(from: start)
        let others = edges.filter { $0.kind == .member }
            .map { incoming ? $0.source : $0.target }
        var collected: [SymbolQuery.Neighbor] = []
        var truncated = false
        for other in Set(others).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let node = graph.node(other) else { continue }
            guard collected.count < max(1, limit) else { truncated = true; break }
            collected.append(describe(node, reachedBy: [EdgeKind.member.rawValue], depth: 1))
        }
        return (collected, truncated)
    }

    /// 사용 의미가 있는 간선만 따라 이웃을 모은다.
    ///
    /// 깊이와 개수를 모두 제한한다. 전이 의존자 수천 개는 결국 또 하나의 덤프이고,
    /// 이 명령이 존재하는 이유가 덤프를 만들지 않는 것이다.
    ///
    /// 따라가는 간선의 조건(`impliesUsage`)은 도달 가능성 분석이 쓰는 것과 같다.
    /// 두 집합이 어긋나면 "아무도 안 쓰는데 도달은 가능"처럼 서로 모순된 두 사실이
    /// 한 응답에 실린다.
    private static func neighbors(
        of start: NodeID,
        in graph: CodeGraph,
        depth: Int,
        limit: Int,
        incoming: Bool
    ) -> ([SymbolQuery.Neighbor], Bool) {
        var collected: [SymbolQuery.Neighbor] = []
        var visited: Set<NodeID> = [start]
        var frontier: [NodeID] = [start]
        var truncated = false

        for level in 1...max(1, depth) {
            // 같은 이웃으로 가는 간선이 여럿일 수 있다(호출이면서 오버라이드처럼).
            // 하나만 골라 담으면 나머지 관계가 응답에서 사라지고, 무엇을 고를지도
            // 정렬 타이에 따라 실행마다 달라진다. 종류를 모아 함께 보고한다.
            var kindsByNeighbor: [NodeID: Set<String>] = [:]
            for current in frontier {
                let edges = incoming ? graph.incomingEdges(to: current) : graph.outgoingEdges(from: current)
                for edge in edges where edge.kind.impliesUsage {
                    let other = incoming ? edge.source : edge.target
                    guard !visited.contains(other) else { continue }
                    kindsByNeighbor[other, default: []].insert(edge.kind.rawValue)
                }
            }

            var next: [NodeID] = []
            for other in kindsByNeighbor.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                visited.insert(other)
                guard let node = graph.node(other), let kinds = kindsByNeighbor[other] else { continue }
                guard collected.count < max(1, limit) else { truncated = true; continue }
                collected.append(describe(node, reachedBy: kinds.sorted(), depth: level))
                next.append(other)
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return (collected, truncated)
    }

    // MARK: - 브리지 사실

    /// Swift 소스에서 언어 경계의 사실을 모아 isthmus 가 읽는 문서로 만든다.
    ///
    /// 인덱스는 문자열을 모른다. 그런데 Dart 와 Swift 를 잇는 유일한 끈이
    /// `FlutterMethodChannel(name:)` 의 그 문자열이다. 구문에서 리터럴을 뽑고 인덱스에서
    /// USR 을 붙여야, isthmus 가 조인한 결과가 `--external-retentions` 로 돌아올 수 있다.
    ///
    /// - Parameter generatedAt: 문서에 적을 생성 시각. 테스트가 고정하려고 받는다.
    public func bridgeFacts(generatedAt: Date = Date()) throws -> BridgeFactsDocument {
        let resolver = BridgeSymbolResolver(snapshot: try makeIndexProvider().loadSnapshot())
        let sources = bridgeSourceFiles()
        var facts: [BridgeFact] = []
        var unreadable = 0
        var unscannedEventChannels = 0
        var unscannedMessageChannels = 0
        for path in sources {
            guard let source = try? environment.fileSystem.readText(at: path) else { unreadable += 1; continue }
            if path.hasSuffix(".swift") {
                let scanned = BridgeFactScanner().scan(source: source, path: path)
                facts += resolver.resolve(scanned.facts)
                unscannedEventChannels += scanned.unscannedEventChannels
                unscannedMessageChannels += scanned.unscannedMessageChannels
            } else {
                facts += ReactNativeMacroScanner().scan(source: source, path: path)
            }
        }
        return BridgeFactsDocument(
            tool: .init(name: Cartograph.toolName, version: Cartograph.version),
            generatedAt: generatedAt.ISO8601Format(),
            project: projectPath,
            facts: facts,
            unscannedEventChannels: unscannedEventChannels,
            unscannedMessageChannels: unscannedMessageChannels,
            extraLimitations: unreadable > 0
                ? ["unreadable-sources: \(unreadable) file(s) could not be read and were skipped"] : []
        )
    }

    /// `bridges` 명령. 항상 JSON 이다. 소비자는 사람이 아니라 isthmus 다.
    public func exportBridgeFacts(generatedAt: Date = Date(), asText: Bool = false) throws -> CommandOutcome {
        let document = try bridgeFacts(generatedAt: generatedAt)
        return CommandOutcome(output: asText ? document.renderText() : try Self.encodeSortedJSON(document))
    }

    /// 브리지 사실을 찾을 소스 파일. 분석 범위와 같은 경로 필터를 건다.
    ///
    /// 인덱스의 파일 목록이 아니라 디스크를 걷는다. 아직 빌드하지 않은 파일과
    /// Objective-C 파일은 인덱스에 없지만 사실은 거기에도 있다.
    private func bridgeSourceFiles() -> [String] {
        let filter = configuration.pathFilter
        let suffixes = [".swift"] + ReactNativeMacroScanner.sourceExtensions.map { "." + $0 }
        return environment.fileSystem.recursiveFiles(
            under: projectPath,
            isIncluded: { path in filter.allows(path) && suffixes.contains { path.hasSuffix($0) } },
            shouldDescend: BuildArtifactDirectories.shouldDescend(into:)
        )
    }

    /// 키 순서를 고정한 JSON. 두 실행의 출력을 diff 할 수 있어야 한다.
    static func encodeSortedJSON(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let text = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw CartographError.outputUnwritable(path: "<stdout>", underlying: "JSON is not UTF-8")
        }
        return text + "\n"
    }

    public func measureMetrics(level: GraphLevel? = nil) throws -> CommandOutcome {
        let (graph, metrics, tolerance) = metrics(in: try loadContext(), level: level)
        let diagnostics = AnalysisDiagnostics.diagnostics(for: metrics, thresholds: configuration.thresholds)
        let renderer = MetricsRenderer(tolerance: tolerance)

        let scoped = reportScope?.filtering(diagnostics) ?? diagnostics
        let baseline = try loadBaseline()
        let reported = baseline?.filtering(scoped) ?? scoped
        let suppressed = scoped.count - reported.count

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
        countedRules: Set<String>? = nil,
        limitations: [String]? = nil
    ) throws -> CommandOutcome {
        // 범위를 먼저 좁힌 뒤 베이스라인을 적용한다. 순서를 바꾸면 억제 건수가
        // 범위 밖의 것까지 세어, 사용자가 보는 숫자와 맞지 않는다.
        let scoped = reportScope?.filtering(diagnostics) ?? diagnostics
        let baseline = try loadBaseline()
        let reported = baseline?.filtering(scoped) ?? scoped
        let suppressed = scoped.count - reported.count

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
            summary: ReportSummary(
                command: command, subject: subject, suppressedCount: suppressed, limitations: limitations
            )
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
        in graph: CodeGraph,
        externalRetentions: ExternalRetentionIndex
    ) -> CommandOutcome {
        let name = node.qualifiedName
        switch explanation {
        case let .retained(reason):
            return CommandOutcome(
                output: "\(name) is retained because it is \(reason.explanation)."
                    + evidenceSentence(for: node, reason: reason, in: graph, externalRetentions: externalRetentions)
                    + "\n"
            )
        case let .retainedByMember(inherited):
            let memberNode = graph.node(inherited.member)
            let member = memberNode?.qualifiedName ?? inherited.member.rawValue
            let evidence = memberNode.map {
                evidenceSentence(for: $0, reason: inherited.reason, in: graph, externalRetentions: externalRetentions)
            } ?? ""
            return CommandOutcome(
                output: "\(name) is retained because its member \(member) is \(inherited.reason.explanation)."
                    + evidence + "\n"
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

    /// 외부 보존 근거가 살린 선언이면 누가 어디서 불렀는지를 문장으로 덧붙인다.
    ///
    /// "외부 파일이 그렇다고 했다"로 끝나면 사용자는 그 파일을 열어 USR 을 찾아야 한다.
    /// 근거는 답의 일부다.
    private static func evidenceSentence(
        for node: GraphNode,
        reason: RetentionReason,
        in graph: CodeGraph,
        externalRetentions: ExternalRetentionIndex
    ) -> String {
        guard reason == .externalBridge,
              let retention = externalRetentions.retention(
                  for: node, names: [ExternalRetentionIndex.syntaxQualifiedName(of: node, in: graph)]
              )
        else { return "" }
        return "\n  evidence: \(retention.evidenceDescription)"
    }

    /// isthmus 가 쓰는 시각을 읽는다. `2026-09-04T12:00:00.000Z` 처럼 소수점 초가 붙는다.
    ///
    /// `.iso8601` 기본 전략은 소수점 초를 거부한다. 그러면 신선도 비교가 조용히 빠져
    /// 낡은 파일이 새것처럼 보인다.
    private static func parseISO8601(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601))
            ?? (try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
    }

    /// 설정과 프로젝트 경로를 반영한 보존 규칙.
    private func makeRetentionPolicy(externalRetentions: ExternalRetentionIndex) -> RetentionPolicy {
        RetentionPolicy(
            options: configuration.retention,
            basePath: projectPath,
            externalRetentions: externalRetentions
        )
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
