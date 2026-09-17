import CartographAnalysis
import CartographCore
import Foundation

/// 현재 그래프와 저장된 과거 그래프의 영향 결과를 나란히 담는다.
public struct ImpactComparisonDocument: Sendable, Equatable, Codable {
    public let format: String
    public let version: Int
    public let status: String
    public let current: ImpactDocument
    public let before: ImpactDocument
    /// 변경 범위 안에서 두 그래프가 달라진 정점과 간선. 계산하지 않은 경우가 아니라
    /// 차이가 없으면 빈 목록 넷과 0 개수로 나온다.
    public let scopeDiff: ScopeDiff
    public let unresolvedInputs: [ImpactDocument.SelectionIssue]
    public let unresolvedCount: Int
    public let truncated: Bool
    public let limitations: [String]

    /// 양쪽 변경 범위의 합집합 위에서 유도된 서브그래프의 차이.
    ///
    /// 영향 탐색은 변경 정점의 **소비자**만 걷는다. 변경된 두 파일 사이에서
    /// 사라진 간선은 양 끝이 전부 `changeScope` 에 들어가 `affected` 에는 절대
    /// 나타나지 않는다 — 파일 시드 비교가 같은 범위를 두 그래프에서 직접
    /// 대조해야 하는 이유다.
    public struct ScopeDiff: Sendable, Equatable, Codable {
        /// 범위 안 정점 중 현재 범위에만 있는 것. 이름 변경은 USR 이 달라지므로
        /// 제거·추가 한 쌍으로 나타나고, 다른 파일로 옮겨져 범위를 들어온 선언도
        /// 여기 나온다 — "새로 생긴 것"만이 아니라 범위 소속의 차이다.
        public let addedSymbols: [SymbolQuery.Subject]
        /// 범위 안 정점 중 과거 범위에만 있는 것. 삭제뿐 아니라 다른 파일로 옮겨져
        /// 범위를 벗어난 선언도 나온다 — 현재 그래프에는 남아 있을 수 있다.
        public let removedSymbols: [SymbolQuery.Subject]
        /// 양 끝이 모두 범위 안인 간선 중 현재 그래프에만 있는 것.
        public let addedEdges: [EdgeChange]
        /// 양 끝이 모두 범위 안인 간선 중 과거 그래프에만 있는 것.
        public let removedEdges: [EdgeChange]
        /// 출력 한도를 적용하기 전 각 목록의 전체 개수.
        public let addedSymbolCount: Int
        public let removedSymbolCount: Int
        public let addedEdgeCount: Int
        public let removedEdgeCount: Int
        /// 어느 한 목록이라도 한도를 넘겼는지.
        public let truncated: Bool
    }

    /// 범위 안에서 생기거나 사라진 간선 하나.
    public struct EdgeChange: Sendable, Equatable, Codable {
        /// 의존하는 쪽(소비자). 제거된 간선이면 과거 그래프의 정점으로 설명된다.
        public let source: SymbolQuery.Subject
        /// 의존되는 쪽(피소비자).
        public let target: SymbolQuery.Subject
        /// 간선 종류. `call`·`reference`·`member` 등 `EdgeKind` 의 원시값.
        public let kind: String
    }

    init(
        status: String,
        current: ImpactDocument,
        before: ImpactDocument,
        unresolvedInputs: [ImpactDocument.SelectionIssue],
        limitations: [String],
        scopeDiff: ScopeDiff,
        limit: Int
    ) {
        format = "change-impact-comparison"
        version = 1
        self.status = status
        self.current = current
        self.before = before
        self.scopeDiff = scopeDiff
        unresolvedCount = unresolvedInputs.count
        var budget = limit
        var omittedCandidates = false
        self.unresolvedInputs = unresolvedInputs.prefix(limit).map { issue in
            let candidates = issue.candidates.map { Array($0.prefix(budget)) }
            let omitted = (issue.candidates?.count ?? 0) - (candidates?.count ?? 0)
            budget -= candidates?.count ?? 0
            omittedCandidates = omittedCandidates || omitted > 0
            return .init(requested: issue.requested, kind: issue.kind, status: issue.status,
                candidates: candidates, candidatesOmitted: omitted > 0 ? omitted : nil)
        }
        truncated = current.truncated.depth || current.truncated.output
            || before.truncated.depth || before.truncated.output
            || unresolvedCount > self.unresolvedInputs.count || omittedCandidates
            || scopeDiff.truncated
        self.limitations = limitations
    }
}

extension CartographService {
    /// 저장된 스냅샷과 현재 그래프를 합치지 않고 각각 영향 분석한다.
    public func compareImpact(
        symbols: [String],
        files: [String],
        beforePath: String,
        maxDepth: Int?,
        limit: Int,
        format: String,
        fileSelectionIsDerived: Bool = false,
        runtimeContractsPath: String? = nil,
        selectionLimitations: [String] = [],
        coreDataBuildEvidencePath: String? = nil
    ) throws -> CommandOutcome {
        let before = try loadAnalysisSnapshot(at: beforePath)
        let currentContext = try coreDataBuildEvidencePath.map {
            try coreDataRuntimeContext(evidencePath: $0)
        } ?? loadContext()
        let historical = before.rebased(to: projectPath)
        let historicalContext = AnalysisContext(
            snapshot: historical.snapshot,
            edgeKinds: Set(historical.edgeKinds),
            externalRetentions: historical.externalRetentions,
            localFunctionDiagnostics: historical.localFunctionDiagnostics ?? [],
            runtimeFiles: historical.runtimeFiles,
            runtimeFreshness: historical.runtimeFreshness
        )
        let currentContracts = try runtimeContractsPath.map {
            try RuntimeEvidenceStore(fileSystem: environment.fileSystem).contracts(at: $0)
        }
        let current = try makeImpactDocument(
            symbols: symbols,
            files: files,
            maxDepth: maxDepth,
            limit: limit,
            runtimeContracts: currentContracts,
            selectionLimitations: selectionLimitations,
            in: currentContext
        )
        let previous = try makeImpactDocument(
            symbols: symbols,
            files: files,
            maxDepth: maxDepth,
            limit: limit,
            runtimeContracts: historical.runtimeContracts,
            recordedLimitations: historical.limitations
                + ["historical-snapshot: source and index freshness describe the captured project, not today's files"],
            selectionLimitations: selectionLimitations,
            in: historicalContext
        )
        let currentGraph = currentContext.buildGraph(level: .symbol).graph
        let historicalGraph = historicalContext.buildGraph(level: .symbol).graph
        let unresolved = Self.reconcileIssues(
            symbols: symbols, files: files,
            currentGraph: currentGraph, historicalGraph: historicalGraph, projectPath: projectPath,
            currentContracts: currentContracts, historicalContracts: historical.runtimeContracts,
            currentArtifacts: ImpactSelection.artifactTargets(in: currentContext.runtimeDiscovery(),
                resourcePaths: currentContext.runtimeFiles?.map(\.path) ?? []),
            historicalArtifacts: ImpactSelection.artifactTargets(in: historicalContext.runtimeDiscovery(),
                resourcePaths: historicalContext.runtimeFiles?.map(\.path) ?? [])
        )
        let scopeDiff = Self.scopeDiff(
            currentScope: current.scope,
            historicalScope: previous.scope,
            currentGraph: currentGraph,
            historicalGraph: historicalGraph,
            currentEdgeKinds: configuration.edgeKinds,
            historicalEdgeKinds: Set(historical.edgeKinds),
            limit: limit
        )
        var limitations = selectionLimitations.map { "selection: \($0)" }
            + current.document.limitations.map { "current: \($0)" }
            + previous.document.limitations.map { "before: \($0)" }
        if (currentContracts == nil) != (historical.runtimeContracts == nil) {
            limitations.append(
                "runtime-contracts: current and historical inputs use different contract documents; compare their runtime evidence separately"
            )
        }
        if configuration.edgeKinds != Set(historical.edgeKinds) {
            limitations.append(
                "edge-kind-filter-mismatch: current and historical graphs include different edge kinds; "
                    + "scopeDiff only reports a change when the other graph could have contained that kind"
            )
        }
        let document = ImpactComparisonDocument(
            status: !unresolved.isEmpty ? "incomplete" : (symbols.isEmpty && files.isEmpty ? "noChanges" : "found"),
            current: current.document,
            before: previous.document,
            unresolvedInputs: unresolved,
            limitations: limitations,
            scopeDiff: scopeDiff,
            limit: limit
        )
        guard format == "json" || format == "text" else {
            throw CartographError.invalidConfiguration(path: projectPath, reason: "Impact comparison format must be text or json.")
        }
        let output = format == "json" ? try Self.encodeSortedJSON(document) : Self.renderText(document)
        let explanation = "Some impact inputs could not be resolved in either snapshot. Review unresolvedInputs and rebuild or capture a matching pre-change snapshot."
        let evidenceFailure = unresolved.contains { $0.kind == "runtimeContract" }
        return CommandOutcome(
            output: output,
            subjectNotFound: !unresolved.isEmpty && !fileSelectionIsDerived && !evidenceFailure,
            notFoundMessage: explanation,
            incompleteAnalysis: !unresolved.isEmpty && (fileSelectionIsDerived || evidenceFailure) ? explanation : nil
        )
    }

    private func loadAnalysisSnapshot(at path: String) throws -> AnalysisSnapshotDocument {
        let data: Data
        do { data = try environment.fileSystem.readData(at: path) }
        catch {
            throw CartographError.invalidConfiguration(path: path, reason: "Could not read the analysis snapshot.")
        }
        guard data.count <= AnalysisSnapshotDocument.maximumByteCount else {
            throw CartographError.invalidConfiguration(path: path, reason: "Analysis snapshot exceeds 128 MiB.")
        }
        do {
            let document = try JSONDecoder().decode(AnalysisSnapshotDocument.self, from: data)
            try document.validate()
            return document
        } catch let error as CartographError {
            throw error
        } catch {
            throw CartographError.invalidConfiguration(
                path: path,
                reason: "Analysis snapshot is not valid analysis-snapshot v1 or v2 JSON."
            )
        }
    }

    private static func reconcileIssues(
        symbols: [String],
        files: [String],
        currentGraph: CodeGraph,
        historicalGraph: CodeGraph,
        projectPath: String,
        currentContracts: RuntimeContractsDocument?,
        historicalContracts: RuntimeContractsDocument?,
        currentArtifacts: [String: Set<NodeID>], historicalArtifacts: [String: Set<NodeID>]
    ) -> [ImpactDocument.SelectionIssue] {
        let currentIssues = fullSelectionIssues(symbols: symbols, files: files, graph: currentGraph,
            projectPath: projectPath, artifactTargets: currentArtifacts)
        let beforeIssues = fullSelectionIssues(symbols: symbols, files: files, graph: historicalGraph,
            projectPath: projectPath, artifactTargets: historicalArtifacts)
        let grouped = Dictionary(grouping: currentIssues + beforeIssues) { "\($0.kind)\u{0}\($0.requested)" }
        var unresolved = grouped.values.compactMap { issues -> ImpactDocument.SelectionIssue? in
            let ambiguous = issues.contains { $0.status == "ambiguous" }
            let inCurrent = currentIssues.contains { $0.kind == issues[0].kind && $0.requested == issues[0].requested }
            let inBefore = beforeIssues.contains { $0.kind == issues[0].kind && $0.requested == issues[0].requested }
            guard ambiguous || (inCurrent && inBefore) else { return nil }
            return issues.sorted { ($0.kind, $0.requested) < ($1.kind, $1.requested) }.first
        }
        unresolved += runtimeIssues(contracts: currentContracts, graph: currentGraph)
        unresolved += runtimeIssues(contracts: historicalContracts, graph: historicalGraph)
        return unresolved.sorted { ($0.kind, $0.requested) < ($1.kind, $1.requested) }
    }

    private static func runtimeIssues(
        contracts: RuntimeContractsDocument?, graph: CodeGraph
    ) -> [ImpactDocument.SelectionIssue] {
        guard let contracts else { return [] }
        let report = RuntimeContractValidator().validate(contracts: contracts.contracts, in: graph)
        return report.results.filter { $0.status != .declared }.map { result in
            let candidates = SymbolQueryDocument.presenting(
                result.sourceCandidates + result.targetCandidates, in: graph
            )
            return .init(
                requested: result.contractID,
                kind: "runtimeContract",
                status: result.status.rawValue,
                candidates: candidates.isEmpty ? nil : candidates
            )
        }
    }

    private static func fullSelectionIssues(
        symbols: [String], files: [String], graph: CodeGraph, projectPath: String,
        artifactTargets: [String: Set<NodeID>]
    ) -> [ImpactDocument.SelectionIssue] {
        ImpactSelection(symbols: Array(Set(symbols)).sorted(), files: files,
            projectPath: projectPath, graph: graph, artifactTargets: artifactTargets).issues
    }

    /// 변경 범위의 합집합 위에서 유도된 서브그래프의 차이를 계산한다.
    ///
    /// `affected` 는 변경 정점의 **소비자**만 모으므로, 범위 안에서 사라지거나
    /// 생긴 간선은 이 대조 없이는 보이지 않는다. 상대쪽 그래프의 간선 종류
    /// 필터가 담을 수 없던 관계는 "달라진 것"이 아니라 "그쪽에서는 원래 없던
    /// 것"이므로 보고하지 않는다.
    private static func scopeDiff(
        currentScope: Set<NodeID>,
        historicalScope: Set<NodeID>,
        currentGraph: CodeGraph,
        historicalGraph: CodeGraph,
        currentEdgeKinds: Set<EdgeKind>,
        historicalEdgeKinds: Set<EdgeKind>,
        limit: Int
    ) -> ImpactComparisonDocument.ScopeDiff {
        struct Signature: Hashable {
            let source: NodeID
            let target: NodeID
            let kind: EdgeKind
            init(_ edge: GraphEdge) {
                source = edge.source
                target = edge.target
                kind = edge.kind
            }
        }
        let scope = currentScope.union(historicalScope)
        // 범위 안 간선은 인접 목록에서만 모은다 — 그래프 전체를 훑어 서명 집합을
        // 만들지 않는다. 빈 범위면 간선도 비어 스캔할 것이 없다.
        let currentScoped = scopedEdges(of: currentGraph, within: scope)
        let historicalScoped = scopedEdges(of: historicalGraph, within: scope)
        let currentSignatures = Set(currentScoped.map(Signature.init))
        let historicalSignatures = Set(historicalScoped.map(Signature.init))
        let removedEdges = historicalScoped.filter {
            !currentSignatures.contains(Signature($0))
                && edgeKindAllowed(currentEdgeKinds, $0.kind)
        }.sorted()
        let addedEdges = currentScoped.filter {
            !historicalSignatures.contains(Signature($0))
                && edgeKindAllowed(historicalEdgeKinds, $0.kind)
        }.sorted()
        let removedSymbols = historicalScope.subtracting(currentScope).sorted()
            .compactMap { historicalGraph.node($0) }
        let addedSymbols = currentScope.subtracting(historicalScope).sorted()
            .compactMap { currentGraph.node($0) }
        return .init(
            addedSymbols: addedSymbols.prefix(limit).map(describe),
            removedSymbols: removedSymbols.prefix(limit).map(describe),
            addedEdges: addedEdges.prefix(limit).compactMap { edgeChange($0, in: currentGraph) },
            removedEdges: removedEdges.prefix(limit).compactMap { edgeChange($0, in: historicalGraph) },
            addedSymbolCount: addedSymbols.count,
            removedSymbolCount: removedSymbols.count,
            addedEdgeCount: addedEdges.count,
            removedEdgeCount: removedEdges.count,
            truncated: addedSymbols.count > limit || removedSymbols.count > limit
                || addedEdges.count > limit || removedEdges.count > limit
        )
    }

    /// 빈 종류 집합은 "필터 없음"이므로 모든 종류를 담을 수 있던 것으로 본다.
    private static func edgeKindAllowed(_ kinds: Set<EdgeKind>, _ kind: EdgeKind) -> Bool {
        kinds.isEmpty || kinds.contains(kind)
    }

    /// 양 끝이 모두 `scope` 안인 간선. 정점 인접 목록에서 모아 전체 간선 스캔을 피한다.
    private static func scopedEdges(of graph: CodeGraph, within scope: Set<NodeID>) -> [GraphEdge] {
        scope.flatMap { graph.outgoingEdges(from: $0) }.filter { scope.contains($0.target) }
    }

    /// 간선의 두 끝이 서로 다른 그래프의 정점으로 풀려야 하므로 그래프를 함께 받는다.
    private static func edgeChange(
        _ edge: GraphEdge, in graph: CodeGraph
    ) -> ImpactComparisonDocument.EdgeChange? {
        guard let source = graph.node(edge.source), let target = graph.node(edge.target) else { return nil }
        return .init(source: describe(source), target: describe(target), kind: edge.kind.rawValue)
    }

    private static func renderText(_ document: ImpactComparisonDocument) -> String {
        let diff = document.scopeDiff
        var lines = [
            "impact comparison: \(document.status) — current \(document.current.summary.affectedSymbols), before \(document.before.summary.affectedSymbols) potential dependents",
            "[current]\n" + document.current.renderText(),
            "[before]\n" + document.before.renderText(),
            "scope diff: +\(diff.addedSymbolCount) -\(diff.removedSymbolCount) symbols, "
                + "+\(diff.addedEdgeCount) -\(diff.removedEdgeCount) edges within the change scope",
        ]
        lines += diff.removedSymbols.map { "  - symbol \($0.qualifiedName)" }
        lines += diff.addedSymbols.map { "  + symbol \($0.qualifiedName)" }
        lines += diff.removedEdges.map { "  - edge \($0.source.qualifiedName) -[\($0.kind)]-> \($0.target.qualifiedName)" }
        lines += diff.addedEdges.map { "  + edge \($0.source.qualifiedName) -[\($0.kind)]-> \($0.target.qualifiedName)" }
        if diff.truncated {
            lines.append("  scope diff truncated: counts are uncapped; increase --limit")
        }
        lines += document.unresolvedInputs.map { "Unresolved \($0.kind): \($0.requested) (\($0.status))" }
        lines += document.limitations.map { "Limitation: \($0)" }
        return PrintableText.printable(lines.joined(separator: "\n")) + "\n"
    }
}
