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
    public let unresolvedInputs: [ImpactDocument.SelectionIssue]
    public let unresolvedCount: Int
    public let truncated: Bool
    public let limitations: [String]

    init(
        status: String,
        current: ImpactDocument,
        before: ImpactDocument,
        unresolvedInputs: [ImpactDocument.SelectionIssue],
        limitations: [String],
        limit: Int
    ) {
        format = "change-impact-comparison"
        version = 1
        self.status = status
        self.current = current
        self.before = before
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
            runtimeFiles: historical.runtimeFiles,
            runtimeFreshness: historical.runtimeFreshness
        )
        let currentContracts = try runtimeContractsPath.map {
            try RuntimeEvidenceStore(fileSystem: environment.fileSystem).contracts(at: $0)
        }
        let current = try impactDocument(
            symbols: symbols,
            files: files,
            maxDepth: maxDepth,
            limit: limit,
            runtimeContracts: currentContracts,
            selectionLimitations: selectionLimitations,
            in: currentContext
        )
        let previous = try impactDocument(
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
        var limitations = selectionLimitations.map { "selection: \($0)" }
            + current.limitations.map { "current: \($0)" }
            + previous.limitations.map { "before: \($0)" }
        if (currentContracts == nil) != (historical.runtimeContracts == nil) {
            limitations.append(
                "runtime-contracts: current and historical inputs use different contract documents; compare their runtime evidence separately"
            )
        }
        let document = ImpactComparisonDocument(
            status: !unresolved.isEmpty ? "incomplete" : (symbols.isEmpty && files.isEmpty ? "noChanges" : "found"),
            current: current,
            before: previous,
            unresolvedInputs: unresolved,
            limitations: limitations,
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

    private static func renderText(_ document: ImpactComparisonDocument) -> String {
        PrintableText.printable(
            "impact comparison: \(document.status) — current \(document.current.summary.affectedSymbols), before \(document.before.summary.affectedSymbols) potential dependents\n"
                + "[current]\n" + document.current.renderText()
                + "[before]\n" + document.before.renderText()
                + document.unresolvedInputs.map { "Unresolved \($0.kind): \($0.requested) (\($0.status))\n" }.joined()
                + document.limitations.map { "Limitation: \($0)\n" }.joined()
        )
    }
}
