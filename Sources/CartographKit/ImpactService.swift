import CartographAnalysis
import CartographCore
import Foundation

extension CartographService {
    /// 인덱스 문맥을 재사용하면서 수정 대상의 전이 소비자를 찾는다. 보고 범위와 베이스라인은 영향을 숨기지 않는다.
    public func impactDocument(
        symbols: [String] = [], files: [String] = [], maxDepth: Int? = nil, limit: Int = 200,
        runtimeContracts: RuntimeContractsDocument? = nil, recordedLimitations: [String]? = nil,
        selectionLimitations: [String] = [], in existingContext: AnalysisContext? = nil
    ) throws -> ImpactDocument {
        try makeImpactDocument(symbols: symbols, files: files, maxDepth: maxDepth, limit: limit,
            runtimeContracts: runtimeContracts, recordedLimitations: recordedLimitations,
            selectionLimitations: selectionLimitations, runtimeTrace: nil, in: existingContext)
    }

    /// 실행 근거는 공개 파일 검증 경로에서 같은 문맥에 묶은 값만 넘긴다.
    private func makeImpactDocument(
        symbols: [String] = [],
        files: [String] = [],
        maxDepth: Int? = nil,
        limit: Int = 200,
        runtimeContracts: RuntimeContractsDocument? = nil,
        recordedLimitations: [String]? = nil,
        selectionLimitations: [String] = [],
        runtimeTrace: RuntimeTraceReport? = nil,
        in existingContext: AnalysisContext? = nil
    ) throws -> ImpactDocument {
        guard (1...10_000).contains(limit), maxDepth.map({ (1...128).contains($0) }) ?? true else {
            throw CartographError.invalidConfiguration(
                path: projectPath, reason: "Impact limits require 1...10000 results and an optional depth of 1...128."
            )
        }
        let context = try existingContext ?? loadContext()
        let graph = context.buildGraph(level: .symbol).graph
        let automatic = context.runtimeDiscovery()
        let automaticDependencies = automatic?.connections.compactMap { connection -> ImpactDependency? in
            guard let source = connection.source, source != connection.target else { return nil }
            return .init(source: source, target: connection.target, contract: connection.boundaryID,
                origin: .automatic, kind: connection.kind)
        } ?? []
        let observedDependencies = runtimeTrace?.evidenceCurrent == true
            ? (runtimeTrace?.connections ?? []).map { connection in
                ImpactDependency(source: connection.source, target: connection.target,
                    contract: "trace:\(connection.source.rawValue):\(connection.target.rawValue):\(connection.kind.rawValue)",
                    origin: .observed, kind: connection.kind)
            } : []
        let runtime = try ImpactRuntimeInputs(contracts: runtimeContracts, graph: graph, projectPath: projectPath)
        let artifactTargets = ImpactSelection.artifactTargets(in: automatic,
            resourcePaths: context.runtimeFiles?.map(\.path) ?? [])
        let selection = ImpactSelection(symbols: symbols, files: files, projectPath: projectPath,
            graph: graph, extraIssues: runtime.issues, artifactTargets: artifactTargets)
        let report = ImpactAnalyzer().analyze(changing: selection.nodes, in: graph, maxDepth: maxDepth,
            additionalDependencies: runtime.dependencies + automaticDependencies + observedDependencies)
        let reasons = context.impactReviewReasons()
        let summaries = try ImpactSummaries(report: report, selection: selection, graph: graph,
            reasons: reasons, context: context, limit: limit, runtime: runtime, projectPath: projectPath)
        let output = ImpactOutput(report: report, selection: selection, summaries: summaries, limit: limit)
        var limitations = (recordedLimitations ?? analysisLimitations(context: context, symbolGraph: graph))
            + selectionLimitations
        let reviewed = Set(report.changed + report.affected.map(\.node))
        let selectedFiles = Set(selection.files)
        let relevantAutomatic = automatic.map { value in
            RuntimeDiscoveryReport(findings: value.findings.filter { finding in
                finding.source.map { reviewed.contains($0) } == true
                    || !reviewed.isDisjoint(with: finding.targets + finding.candidates)
                    || selectedFiles.contains(ReportScope.normalized(finding.boundary.location.path))
            }, limitations: value.limitations)
        }
        let automaticDocument = relevantAutomatic.map {
            RuntimeDiscoveryDocument(report: $0, files: context.runtimeFiles, graph: graph, limitations: [], limit: limit)
        }
        let observedDocument = runtimeTrace.map { RuntimeTraceReportDocument(report: $0, graph: graph, limit: limit) }
        let unresolvedStates: Set<RuntimeDiscoveryStatus> = [.dynamic, .unresolved, .ambiguous, .stale, .unindexed]
        let unresolvedRuntime = automatic?.findings.count { unresolvedStates.contains($0.status) } ?? 0
        if unresolvedRuntime > 0 {
            limitations.append("unresolved-runtime-boundaries: \(unresolvedRuntime) boundary(s) have unresolved names, "
                + "receivers or index evidence; impact can miss paths through them. Inspect runtime discover or collect a trace.")
        }
        limitations += automatic?.limitations ?? []
        limitations += runtimeTrace?.limitations ?? []
        var truncatedSections = output.truncatedSections
        if automaticDocument?.truncated == true { truncatedSections.append("automaticRuntime") }
        if observedDocument?.truncated == true { truncatedSections.append("observedRuntime") }
        if report.affected.contains(where: { $0.runtimeEvidence.count > limit }) {
            truncatedSections.append("runtimeEvidence")
        }
        if !selection.issues.isEmpty {
            limitations.append("unresolved-impact-inputs: \(selection.issues.count) input(s) could not be resolved; "
                + "deleted, renamed, excluded or unbuilt declarations require the pre-change index or explicit review")
        }
        return ImpactDocument(
            status: selection.status,
            requestedSymbols: Array(symbols.prefix(limit)),
            requestedFiles: Array(selection.files.prefix(limit)),
            selected: selection.selected.sorted().prefix(limit).compactMap { graph.node($0) }.map(Self.describe),
            changeScope: output.changeScope.compactMap { graph.node($0) }.map(Self.describe),
            affected: report.affected.prefix(limit).compactMap { Self.describeImpact($0, in: graph, limit: limit) },
            summary: summaries.summary,
            tests: Array(summaries.tests.prefix(limit)),
            entryPoints: Array(summaries.entryPoints.prefix(limit)),
            runtimeReview: Array(summaries.runtimeReview.prefix(limit)),
            runtimeDependencies: Array(summaries.runtimeDependencies.prefix(limit)),
            selectionIssues: output.issues,
            limitations: limitations,
            truncated: .init(depth: report.truncatedByDepth, sections: truncatedSections),
            automaticRuntime: automaticDocument, observedRuntime: observedDocument
        )
    }

    /// 명령과 세션 모두 같은 문서를 사용한다. 미확인 입력은 부분 결과를 출력한 뒤 사용 오류로 알린다.
    public func impact(
        symbols: [String] = [], files: [String] = [], maxDepth: Int? = nil,
        limit: Int = 200, format: String = "text", fileSelectionIsDerived: Bool = false,
        runtimeContractsPath: String? = nil, selectionLimitations: [String] = [],
        runtimeTracePath: String? = nil, runtimeExecutablePath: String? = nil,
        coreDataBuildEvidencePath: String? = nil
    ) throws -> CommandOutcome {
        guard format == "text" || format == "json" else {
            throw CartographError.invalidConfiguration(path: projectPath, reason: "Impact format must be text or json.")
        }
        let runtime = try runtimeContractsPath.map {
            try RuntimeEvidenceStore(fileSystem: environment.fileSystem).contracts(at: $0)
        }
        guard (runtimeTracePath == nil) == (runtimeExecutablePath == nil) else {
            throw CartographError.invalidConfiguration(path: projectPath,
                reason: "Runtime trace impact requires both the trace and executable paths.")
        }
        guard runtimeTracePath == nil || coreDataBuildEvidencePath == nil else {
            throw CartographError.invalidConfiguration(
                path: projectPath,
                reason: "Runtime trace and Core Data build evidence cannot be combined."
            )
        }
        let context: AnalysisContext
        if let coreDataBuildEvidencePath {
            context = try coreDataRuntimeContext(evidencePath: coreDataBuildEvidencePath)
        } else {
            context = try runtimeTracePath == nil ? loadContext() : loadRuntimeEvidenceContext()
        }
        let trace = try runtimeTracePath.map {
            try runtimeTraceReport(tracePath: $0, executablePath: runtimeExecutablePath!, in: context)
        }
        let document = try makeImpactDocument(symbols: symbols, files: files, maxDepth: maxDepth,
            limit: limit, runtimeContracts: runtime, selectionLimitations: selectionLimitations,
            runtimeTrace: trace, in: context)
        let incomplete = !document.selectionIssues.isEmpty
        let unresolvedEvidence = document.selectionIssues.contains { $0.kind == "runtimeContract" }
        let explanation = "Some impact inputs could not be resolved. Review selectionIssues and rebuild "
            + "the relevant targets, or inspect the pre-change index for deleted or renamed declarations."
        return CommandOutcome(
            output: format == "json" ? try Self.encodeSortedJSON(document) : document.renderText(),
            subjectNotFound: incomplete && !fileSelectionIsDerived && !unresolvedEvidence,
            notFoundMessage: explanation,
            incompleteAnalysis: trace?.evidenceCurrent == false ? "Runtime trace evidence is incomplete or stale."
                : (incomplete && (fileSelectionIsDerived || unresolvedEvidence) ? explanation : nil)
        )
    }

    private static func describeImpact(
        _ visit: ImpactVisit, in graph: CodeGraph, limit: Int
    ) -> ImpactDocument.Affected? {
        guard let node = graph.node(visit.node) else { return nil }
        let contracts = Array(visit.runtimeContracts.prefix(limit))
        let omitted = visit.runtimeContracts.count - contracts.count
        return .init(
            symbol: describe(node), depth: visit.depth, via: visit.via.rawValue,
            relationship: visit.relationship.rawValue, edges: visit.edges.map(\.rawValue),
            dispatchContract: visit.dispatchContract.flatMap { graph.node($0) }.map(describe),
            runtimeContracts: contracts.isEmpty ? nil : contracts,
            runtimeContractsCount: omitted > 0 ? visit.runtimeContracts.count : nil,
            runtimeContractsOmitted: omitted > 0 ? omitted : nil,
            runtimeEvidence: visit.runtimeEvidence.isEmpty ? nil : Array(visit.runtimeEvidence.prefix(limit)),
            runtimeEvidenceOmitted: visit.runtimeEvidence.count > limit ? visit.runtimeEvidence.count - limit : nil
        )
    }
}

/// 파일은 입력 시드만 고른다. 그 파일 밖의 소비자는 전체 심볼 그래프에서 계속 따라간다.
struct ImpactSelection {
    let requestedSymbolCount: Int
    let selected: Set<NodeID>
    let nodes: Set<NodeID>
    let files: [String]
    let issues: [ImpactDocument.SelectionIssue]
    let status: String

    static func artifactTargets(
        in report: RuntimeDiscoveryReport?, resourcePaths: [String]
    ) -> [String: Set<NodeID>] {
        let connections = (report?.connections ?? []).filter { $0.source == nil }
        var targets = Dictionary(grouping: connections,
            by: { ReportScope.normalized($0.location.path) }).mapValues { Set($0.map(\.target)) }
        let inputs = Set(resourcePaths.map(ReportScope.normalized))
        for connection in connections where connection.kind == .coreDataEntityClass {
            let container = RuntimeResourcePath.coreDataModelContainer(connection.location.path)
            let marker = ReportScope.normalized(container + "/.xccurrentversion")
            if inputs.contains(marker), RuntimeResourcePath.isCoreDataVersionSelection(marker) {
                targets[marker, default: []].insert(connection.target)
            }
        }
        return targets
    }

    init(symbols: [String], files: [String], projectPath: String, graph: CodeGraph,
         extraIssues: [ImpactDocument.SelectionIssue] = [], artifactTargets: [String: Set<NodeID>] = [:]) {
        let lookup = GraphQueryIndex(graph: graph)
        var nodes: Set<NodeID> = []
        var issues = extraIssues
        for subject in symbols {
            switch lookup.resolve(subject) {
            case let .found(node): nodes.insert(node.id)
            case let .ambiguous(candidates):
                if let type = Self.sharedExtendedType(candidates, graph: graph) {
                    nodes.insert(type.id)
                } else {
                    issues.append(.init(requested: subject, kind: "symbol", status: "ambiguous",
                        candidates: SymbolQueryDocument.presenting(candidates, in: graph)))
                }
            case .notFound:
                let candidates = SymbolQueryDocument.presenting(lookup.similarCandidates(to: subject), in: graph)
                issues.append(.init(requested: subject, kind: "symbol", status: "notFound",
                    candidates: candidates.isEmpty ? nil : candidates))
            }
        }
        let normalizedFiles = Set(files.map { file in
            ReportScope.normalized(file.hasPrefix("/") ? file : (projectPath as NSString).appendingPathComponent(file))
        })
        var nodesByFile: [String: [NodeID]] = [:]
        if !normalizedFiles.isEmpty {
            var rawPaths: [String: [NodeID]] = [:]
            for node in graph.sortedNodes {
                if let path = node.location?.path { rawPaths[path, default: []].append(node.id) }
            }
            for (path, ids) in rawPaths { nodesByFile[ReportScope.normalized(path), default: []] += ids }
        }
        for file in normalizedFiles.sorted() {
            let matches = (nodesByFile[file] ?? []) + Array(artifactTargets[file] ?? [])
            guard !matches.isEmpty else {
                issues.append(.init(requested: file, kind: "file", status: "unindexed", candidates: nil))
                continue
            }
            nodes.formUnion(matches)
        }
        self.selected = nodes
        requestedSymbolCount = symbols.count
        self.nodes = Self.expandingContainers(nodes, graph: graph)
        self.files = normalizedFiles.sorted()
        self.issues = issues
        status = !issues.isEmpty ? "incomplete" : (symbols.isEmpty && files.isEmpty ? "noChanges" : "found")
    }

    /// 타입과 그 타입의 익스텐션만 동명이면 의미상 같은 타입 선택이다. 다른 선언이 섞이면 추측하지 않는다.
    private static func sharedExtendedType(_ candidates: [GraphNode], graph: CodeGraph) -> GraphNode? {
        let types = candidates.filter { $0.kind.isTypeDeclaration }
        guard types.count == 1, let type = types.first else { return nil }
        let others = candidates.filter { $0.id != type.id }
        guard others.allSatisfy({ node in
            node.kind == .extensionDeclaration
                && Set(graph.outgoingEdges(from: node.id).filter { $0.kind == .extends }.map(\.target)) == [type.id]
        }) else { return nil }
        return type
    }

    /// 타입 전체를 수정 대상으로 고르면 익스텐션의 멤버도 포함한다. 이후 소비자의 형제까지 확장하지 않는다.
    private static func expandingContainers(_ selected: Set<NodeID>, graph: CodeGraph) -> Set<NodeID> {
        let roots = selected.filter {
            graph.node($0)?.kind.isTypeDeclaration == true || graph.node($0)?.kind == .extensionDeclaration
        }.sorted()
        guard !roots.isEmpty else { return selected }
        var children: [NodeID: Set<NodeID>] = [:]
        for edge in graph.edges where edge.kind == .member {
            children[edge.source, default: []].insert(edge.target)
            if let owner = graph.semanticParent(of: edge.target) { children[owner, default: []].insert(edge.target) }
        }
        for edge in graph.edges where edge.kind == .extends && graph.node(edge.source)?.kind == .extensionDeclaration {
            children[edge.target, default: []].insert(edge.source)
        }
        var result = selected
        var queue = roots
        var head = 0
        while head < queue.count {
            let parent = queue[head]
            head += 1
            for child in (children[parent] ?? []).sorted() where result.insert(child).inserted {
                queue.append(child)
            }
        }
        return result
    }
}

/// 집계는 표시 한도 적용 전에 만든다. 출력에서 생략된 테스트가 없다고 오해하게 해서는 안 된다.
private struct ImpactSummaries {
    let summary: ImpactDocument.Summary
    let tests: [SymbolQuery.Subject]
    let entryPoints: [SymbolQuery.Subject]
    let runtimeReview: [ImpactDocument.RuntimeReview]
    let runtimeDependencies: [ImpactDocument.RuntimeDependency]
    let runtimeEvidenceTruncated: Bool
    let runtimeContractsTruncated: Bool

    init(report: ImpactReport, selection: ImpactSelection, graph: CodeGraph,
         reasons: [NodeID: Set<RetentionReason>], context: AnalysisContext, limit: Int,
         runtime: ImpactRuntimeInputs, projectPath: String) throws {
        let affected = report.affected.compactMap { graph.node($0.node) }
        let reviewed = (report.changed + report.affected.map(\.node)).compactMap { graph.node($0) }
        let reviewedIDs = Set(reviewed.map(\.id))
        runtimeDependencies = runtime.documents.filter {
            $0.source?.usr.map { reviewedIDs.contains(NodeID($0)) } == true
                || $0.target?.usr.map { reviewedIDs.contains(NodeID($0)) } == true
        }
        tests = reviewed.filter { reasons[$0.id]?.contains(where: \.isTestTargetRoot) == true }
            .map(SymbolQuery.Subject.init(node:))
        entryPoints = reviewed.filter { reasons[$0.id]?.contains(.entryPoint) == true }.map(SymbolQuery.Subject.init(node:))
        var evidenceTruncated = false
        var contractsTruncated = false
        runtimeReview = try reviewed.compactMap { node in
            let contracts = runtime.contractsByNode[node.id] ?? []
            let external = context.externalRetentionIndex.matchingRetentions(
                for: node, names: [ExternalRetentionIndex.syntaxQualifiedName(of: node, in: graph)]
            ).compactMap(\.evidence)
            evidenceTruncated = evidenceTruncated || external.count > limit
                || external.contains { ($0.callersOmitted ?? 0) > 0 }
                || external.contains { ($0.callers?.count ?? 0) > limit }
            contractsTruncated = contractsTruncated || contracts.count > limit
            return try Self.runtimeReview(node, reasons: reasons[node.id] ?? [], external: external,
                contracts: contracts, limit: limit, projectPath: projectPath)
        }
        runtimeEvidenceTruncated = evidenceTruncated
        runtimeContractsTruncated = contractsTruncated
        let files = Set(affected.compactMap { $0.location?.path }).sorted()
        let modules = Set(affected.compactMap(\.module)).sorted()
        summary = .init(
            requestedSymbols: selection.requestedSymbolCount,
            requestedFiles: selection.files.count,
            selectedSymbols: selection.selected.count,
            changeScopeSymbols: report.changed.count,
            affectedSymbols: report.affected.count,
            fileCount: files.count, files: Array(files.prefix(limit)),
            moduleCount: modules.count, modules: Array(modules.prefix(limit)),
            testSymbols: tests.count, entryPoints: entryPoints.count, runtimeReviewSymbols: runtimeReview.count,
            runtimeDependencies: runtimeDependencies.count,
            unresolvedInputs: selection.issues.count
        )
    }

    private static let runtimeReasons: Set<RetentionReason> = [
        .objectiveCAccessible, .interfaceBuilder, .dynamicDispatch, .externalConformance, .externalOverride,
        .rawRepresentableEnumCase, .caseIterableEnumCase, .codingKey, .codableProperty, .runtimeManaged,
        .propertyWrapperRequirement, .resultBuilderRequirement, .externalBridge, .preview,
    ]

    private static func runtimeReview(
        _ node: GraphNode, reasons facts: Set<RetentionReason>, external: [ExternalRetention.Evidence],
        contracts: [String], limit: Int, projectPath: String
    ) throws -> ImpactDocument.RuntimeReview? {
        let reasons = facts.intersection(runtimeReasons)
        guard !reasons.isEmpty || !contracts.isEmpty else { return nil }
        let shownEvidence = try external.prefix(limit).map {
            try Self.cappedEvidence($0, limit: limit, projectPath: projectPath)
        }
        let evidenceOmitted = external.count - shownEvidence.count
        let shownContracts = Array(contracts.prefix(limit))
        let contractsOmitted = contracts.count - shownContracts.count
        return .init(
            symbol: SymbolQuery.Subject(node: node),
            reasons: reasons.sorted { $0.rawValue < $1.rawValue },
            externalEvidence: shownEvidence.compactMap { $0 },
            externalEvidenceCount: evidenceOmitted > 0 ? external.count : nil,
            externalEvidenceOmitted: evidenceOmitted > 0 ? evidenceOmitted : nil,
            runtimeContracts: shownContracts,
            runtimeContractsCount: contractsOmitted > 0 ? contracts.count : nil,
            runtimeContractsOmitted: contractsOmitted > 0 ? contractsOmitted : nil
        )
    }

    private static func cappedEvidence(
        _ evidence: ExternalRetention.Evidence, limit: Int, projectPath: String
    ) throws -> ExternalRetention.Evidence {
        let producerOmitted = evidence.callersOmitted ?? 0
        guard producerOmitted >= 0 else {
            throw CartographError.invalidConfiguration(
                path: projectPath,
                reason: "Runtime evidence caller omission count must not be negative."
            )
        }
        guard let callers = evidence.callers, callers.count > limit else { return evidence }
        let (omitted, overflow) = producerOmitted.addingReportingOverflow(callers.count - limit)
        guard !overflow else {
            throw CartographError.invalidConfiguration(
                path: projectPath,
                reason: "Runtime evidence caller omission count exceeds the supported range."
            )
        }
        return .init(
            channel: evidence.channel,
            method: evidence.method,
            caller: evidence.caller,
            callers: Array(callers.prefix(limit)),
            callersOmitted: omitted > 0 ? omitted : nil
        )
    }
}

/// 각 목록에 같은 상한을 적용하고 어느 목록이 잘렸는지 따로 기록한다.
private struct ImpactOutput {
    let changeScope: [NodeID]
    let issues: [ImpactDocument.SelectionIssue]
    let truncatedSections: [String]

    init(report: ImpactReport, selection: ImpactSelection, summaries: ImpactSummaries, limit: Int) {
        // 표시한 소비자의 시드가 다른 시드들에 밀려 생략되면 via 사슬이 끊긴다.
        let scope = Set(report.changed)
        let needed = Set(report.affected.prefix(limit).map(\.via)).intersection(scope)
        changeScope = Array((needed.sorted() + report.changed.filter { !needed.contains($0) }).prefix(limit))
        var remainingCandidates = limit
        var candidatesTruncated = false
        issues = selection.issues.prefix(limit).map { issue in
            let candidates = issue.candidates.map { Array($0.prefix(remainingCandidates)) }
            let omitted = (issue.candidates?.count ?? 0) - (candidates?.count ?? 0)
            remainingCandidates -= candidates?.count ?? 0
            candidatesTruncated = candidatesTruncated || omitted > 0
            return .init(requested: issue.requested, kind: issue.kind, status: issue.status,
                candidates: candidates, candidatesOmitted: omitted > 0 ? omitted : nil)
        }
        let counts = [
            "requestedSymbols": selection.requestedSymbolCount, "requestedFiles": selection.files.count,
            "selected": selection.selected.count, "changeScope": report.changed.count,
            "affected": report.affected.count, "tests": summaries.tests.count,
            "entryPoints": summaries.entryPoints.count, "runtimeReview": summaries.runtimeReview.count,
            "selectionIssues": selection.issues.count, "files": summaries.summary.fileCount,
            "modules": summaries.summary.moduleCount,
            "runtimeDependencies": summaries.runtimeDependencies.count,
        ]
        let affectedContractsTruncated = report.affected.contains { $0.runtimeContracts.count > limit }
        truncatedSections = counts.filter { $0.value > limit }.map(\.key)
            + (candidatesTruncated ? ["candidates"] : [])
            + (summaries.runtimeEvidenceTruncated ? ["runtimeEvidence"] : [])
            + (summaries.runtimeContractsTruncated || affectedContractsTruncated ? ["runtimeContracts"] : [])
    }
}

/// 런타임 계약의 양 끝이 확인된 연결만 보조 관계로 넘긴다. 결합 실패는 결과와 함께 남긴다.
struct ImpactRuntimeInputs {
    let dependencies: [ImpactDependency]
    let documents: [ImpactDocument.RuntimeDependency]
    let contractsByNode: [NodeID: [String]]
    let issues: [ImpactDocument.SelectionIssue]

    init(contracts: RuntimeContractsDocument?, graph: CodeGraph, projectPath: String) throws {
        guard let contracts else {
            dependencies = []; documents = []; contractsByNode = [:]; issues = []
            return
        }
        try RuntimeEvidenceStore.validateContracts(contracts, path: projectPath)
        let report = RuntimeContractValidator().validate(contracts: contracts.contracts, in: graph)
        let byID = Dictionary(contracts.contracts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var dependencies: [ImpactDependency] = []
        var documents: [ImpactDocument.RuntimeDependency] = []
        var contractsByNode: [NodeID: Set<String>] = [:]
        var issues: [ImpactDocument.SelectionIssue] = []
        for result in report.results {
            guard let contract = byID[result.contractID] else { continue }
            if result.status == .declared {
                if let source = result.source, let target = result.target {
                    dependencies.append(.init(source: source.id, target: target.id, contract: contract.id))
                }
                for node in [result.source, result.target].compactMap({ $0 }) {
                    contractsByNode[node.id, default: []].insert(contract.id)
                }
            } else {
                let candidates = SymbolQueryDocument.presenting(result.sourceCandidates + result.targetCandidates, in: graph)
                issues.append(.init(requested: contract.id, kind: "runtimeContract", status: result.status.rawValue,
                    candidates: candidates.isEmpty ? nil : candidates))
            }
            documents.append(.init(contract: contract.id, source: result.source.map(SymbolQuery.Subject.init(node:)),
                target: result.target.map(SymbolQuery.Subject.init(node:)), mechanism: contract.mechanism,
                status: result.status.rawValue, requiredScenarios: contract.requiredScenarios.sorted()))
        }
        self.dependencies = dependencies
        self.documents = documents
        self.contractsByNode = contractsByNode.mapValues { $0.sorted() }
        self.issues = issues
    }
}
