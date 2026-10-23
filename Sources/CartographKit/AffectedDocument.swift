import CartographAnalysis
import CartographCore

/// 변경에 도달하는 테스트 선언. "이 변경이 어떤 테스트를 건드리나"의 답이다.
///
/// 정적 도달성이다 — 테스트를 실제로 돌려 본 결과가 아니고, 목록이 비었다고
/// 기존 테스트가 이 동작을 덮지 않는다는 뜻도 아니다. 그 구분을 문서와
/// `limitations`가 함께 진다.
public struct AffectedDocument: Sendable, Equatable, Codable {
    public static let format = "change-affected"
    public static let version = 1

    public let format: String
    public let version: Int
    public let status: String
    public let level: String
    public let requestedSymbols: [String]
    public let requestedFiles: [String]
    public let selected: [SymbolQuery.Subject]
    /// 선택한 타입의 멤버까지 포함한, 수정 대상이 되는 정점.
    public let changeScope: [SymbolQuery.Subject]
    public let tests: [Test]
    /// 테스트처럼 보이는 표식만 있는 선언. 위치와 영향 경로를 남기되 확인한 테스트 수에 섞지 않는다.
    public let uncertainTestCandidates: [Test]?
    public let summary: Summary
    public let selectionIssues: [ImpactDocument.SelectionIssue]
    public let limitations: [String]
    /// 명시 요청한 캡처 소속 진단. 없으면 기존 v1 출력과 같다.
    public let targetScope: TargetScopeDocument?
    public let receiverPrecision: ImpactReceiverPrecision?
    public let truncated: ImpactDocument.Truncation

    /// 테스트 선언 하나와 변경에서의 거리.
    public struct Test: Sendable, Equatable, Codable {
        public let symbol: SymbolQuery.Subject
        /// 변경 자체로 선택된 테스트면 0.
        public let depth: Int
        /// 이 테스트를 처음 발견하게 한 바로 앞 소비자. 변경 자체면 nil.
        public let via: SymbolQuery.Subject?
        /// `dependent`·`dispatchCaller` 같은 영향 관계. 변경 자체면 `changed`.
        public let relationship: String
        public let edges: [String]
        public let dispatchContract: SymbolQuery.Subject?
        /// 컴파일러 간선과 구분한 자동 런타임 연결의 출처. 실행 관측을 뜻하지 않는다.
        public let runtimeEvidence: [RuntimeEvidenceReference]?
        /// 출력 예산 때문에 생략한 근거 수. 없으면 키를 싣지 않는다.
        public let runtimeEvidenceOmitted: Int?
        /// 모듈 이름과 테스트 타깃 이름이 같다는 계약 아래의 XCTest 식별자.
        ///
        /// 증명하지 못하면 키가 빠진다. 그때 이 테스트를 고르는 안전한 방법은 모듈 전체다.
        public let xcodebuildIdentifier: String?
    }

    public struct Summary: Sendable, Equatable, Codable {
        public let testCount: Int
        /// 변경 범위 안에 들어 있는 테스트 수(테스트 파일을 직접 고친 경우).
        public let changedTestCount: Int
        /// 변경 정점 수(컨테이너 확장 포함).
        public let changeScopeSymbols: Int
        /// 소비자로 도달한 정점 수. 테스트가 아닌 것도 포함한다.
        public let affectedSymbols: Int
        public let testFileCount: Int
        public let testFiles: [String]
        public let moduleCount: Int
        public let modules: [String]
        public let unresolvedInputs: Int
    }

    init(
        status: String,
        requestedSymbols: [String],
        requestedFiles: [String],
        selected: [SymbolQuery.Subject],
        changeScope: [SymbolQuery.Subject],
        tests: [Test],
        uncertainTestCandidates: [Test]? = nil,
        summary: Summary,
        selectionIssues: [ImpactDocument.SelectionIssue],
        limitations: [String],
        truncated: ImpactDocument.Truncation,
        targetScope: TargetScopeDocument? = nil, receiverPrecision: ImpactReceiverPrecision? = nil
    ) {
        format = Self.format
        version = Self.version
        level = "symbol"
        self.status = status
        self.requestedSymbols = requestedSymbols
        self.requestedFiles = requestedFiles
        self.selected = selected
        self.changeScope = changeScope
        self.tests = tests
        self.uncertainTestCandidates = uncertainTestCandidates
        self.summary = summary
        self.selectionIssues = selectionIssues
        self.limitations = limitations
        self.targetScope = targetScope
        self.receiverPrecision = receiverPrecision
        self.truncated = truncated
    }
}

extension CartographService {
    /// 변경에 도달하는 테스트를 계산한다.
    ///
    /// 시드 선택과 컨테이너 확장, 소비자 순회는 `impact` 와 같은 배관을 쓴다 —
    /// 답이 갈라지면 같은 변경에 대해 두 명령이 다른 테스트를 말하게 된다.
    /// 다른 점은 답의 모양뿐이다: 테스트 선언과 변경에서의 거리만 남긴다.
    public func affectedDocument(
        symbols: [String] = [], files: [String] = [], maxDepth: Int? = nil, limit: Int = 200,
        selectionLimitations: [String] = [], in existingContext: AnalysisContext? = nil
    ) throws -> AffectedDocument {
        try affectedDocument(symbols: symbols, files: files, maxDepth: maxDepth, limit: limit,
            selectionLimitations: selectionLimitations, in: existingContext, targetScopeEvidencePath: nil)
    }

    /// 명시된 소속 캡처 진단을 추가한다. 기존 호출 및 함수 참조의 서명은 위 overload에 남긴다.
    public func affectedDocument(
        symbols: [String] = [], files: [String] = [], maxDepth: Int? = nil, limit: Int = 200,
        selectionLimitations: [String] = [], in existingContext: AnalysisContext? = nil,
        targetScopeEvidencePath: String?
    ) throws -> AffectedDocument {
        try makeAffectedDocument(symbols: symbols, files: files, maxDepth: maxDepth, limit: limit,
            selectionLimitations: selectionLimitations, in: existingContext,
            targetScopeEvidencePath: targetScopeEvidencePath)
    }

    private func makeAffectedDocument(
        symbols: [String], files: [String], maxDepth: Int?, limit: Int,
        selectionLimitations: [String], in existingContext: AnalysisContext?,
        targetScopeEvidencePath: String?, receiverFallback: ImpactReceiverPrecision? = nil
    ) throws -> AffectedDocument {
        guard (1...10_000).contains(limit), maxDepth.map({ (1...128).contains($0) }) ?? true else {
            throw CartographError.invalidConfiguration(
                path: projectPath, reason: "Affected limits require 1...10000 results and an optional depth of 1...128."
            )
        }
        // 외부 문맥이 언제 읽혔는지 모르면 현재 지문을 과거 그래프에 붙이지 않는다.
        let scopeFingerprint = targetScopeEvidencePath != nil && existingContext == nil
            ? (try? sessionInputFingerprint()) : nil
        let context = try existingContext ?? loadContext()
        let graph = context.buildGraph(level: .symbol).graph
        let automatic = context.runtimeDiscovery()
        // 생명주기·이름 색인·파일별 정점은 `impact` 와 같은 문맥 준비 값을 쓴다. 스냅샷에만 기대는 값이라
        // 편집마다 이어지는 요청이 그래프 전체 정렬과 색인 생성을 되풀이할 이유가 없다.
        let lifecycle = context.impactLifecycle()
        let artifactTargets = ImpactSelection.artifactTargets(in: automatic,
            resourcePaths: context.runtimeFiles?.map(\.path) ?? [])
        let selection = ImpactSelection(symbols: symbols, files: files, projectPath: projectPath,
            graph: graph, artifactTargets: artifactTargets,
            makeQueryIndex: { _ in context.impactQueryIndex() },
            makeRawFileIndex: { _ in context.impactRawNodesByFile() })
        let receiver = impactReceiverEvidence(context: context, historical: receiverFallback != nil,
            changing: selection.nodes, graph: graph)
        let analyzed = ImpactAnalyzer().analyze(changing: selection.nodes, in: graph, maxDepth: maxDepth,
            additionalDependencies: Self.automaticImpactDependencies(automatic) + lifecycle.dependencies,
            receiverEvidence: receiver.evidence)
        let report = ImpactReport(changed: analyzed.changed, affected: analyzed.affected,
            truncatedByDepth: analyzed.truncatedByDepth, receiverPrecision: receiverFallback ?? analyzed.receiverPrecision)
        let testIdentity = context.impactTestIdentity()
        func isTest(_ id: NodeID) -> Bool {
            testIdentity.confirmed.contains(id)
        }
        func isCandidate(_ id: NodeID) -> Bool { isTest(id) || testIdentity.uncertain.contains(id) }
        let canProveHierarchy = XCTestIdentifier.canProveClassHierarchy(
            edgeKinds: configuration.edgeKinds, narrowsPaths: configuration.narrowsPathsBeyondDefaults
        )
        let identity = testIdentity.xctest
        func identifier(_ id: NodeID) -> String? {
            XCTestIdentifier.identifier(for: id, in: graph, canProveClassHierarchy: canProveHierarchy,
                identity: identity)
        }
        var tests: [AffectedDocument.Test] = []
        for id in report.changed where isCandidate(id) {
            guard let node = graph.node(id) else { continue }
            tests.append(AffectedDocument.Test(
                symbol: Self.describe(node), depth: 0, via: nil,
                relationship: "changed", edges: [], dispatchContract: nil,
                runtimeEvidence: nil, runtimeEvidenceOmitted: nil,
                xcodebuildIdentifier: identifier(id)
            ))
        }
        for visit in report.affected where isCandidate(visit.node) {
            guard let node = graph.node(visit.node) else { continue }
            tests.append(AffectedDocument.Test(
                symbol: Self.describe(node), depth: visit.depth,
                via: graph.node(visit.via).map(Self.describe),
                relationship: visit.relationship.rawValue,
                edges: visit.edges.map(\.rawValue),
                dispatchContract: visit.dispatchContract.flatMap { graph.node($0) }.map(Self.describe),
                runtimeEvidence: visit.runtimeEvidence.isEmpty ? nil : Array(visit.runtimeEvidence.prefix(limit)),
                runtimeEvidenceOmitted: visit.runtimeEvidence.count > limit ? visit.runtimeEvidence.count - limit : nil,
                xcodebuildIdentifier: identifier(visit.node)
            ))
        }
        // 사람과 CI 모두 파일·줄 순으로 읽는다. 깊이는 답의 일부라 먼저 본다.
        tests.sort { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            let left = lhs.symbol.location
            let right = rhs.symbol.location
            if let left, let right, left != right { return left < right }
            if (left == nil) != (right == nil) { return right == nil }
            if lhs.symbol.qualifiedName != rhs.symbol.qualifiedName {
                return lhs.symbol.qualifiedName < rhs.symbol.qualifiedName
            }
            return (lhs.symbol.usr ?? "") < (rhs.symbol.usr ?? "")
        }
        let uncertainTests = tests.filter { $0.symbol.usr.map { testIdentity.uncertain.contains(NodeID($0)) } == true }
        tests.removeAll { $0.symbol.usr.map { testIdentity.uncertain.contains(NodeID($0)) } == true }
        let testFiles = Set(tests.compactMap(\.symbol.location?.path)).sorted()
        let modules = Set(tests.compactMap(\.symbol.module)).sorted()
        var limitations = analysisLimitations(context: context, symbolGraph: graph) + selectionLimitations
            + Self.automaticRuntimeLimitations(automatic)
        limitations += testIdentity.limitations(for: report) + receiver.limitations + Self.receiverLimitations(report)
        if !tests.isEmpty {
            limitations.append("test-target-assumption: xcodebuild selection assumes each indexed module name "
                + "matches a test target in the chosen scheme; framework identity does not prove target membership")
        }
        if tests.contains(where: { $0.xcodebuildIdentifier == nil }) {
            limitations.append("uncertain-test-identity: reached candidates without a proved XCTest selector "
                + "are retained and widened to their module; syntax/legacy test markers are not runnable-test proof")
        }
        if let automatic, !automatic.limitations.isEmpty {
            limitations.append("incomplete-runtime-analysis: runtime discovery reported \(automatic.limitations.count) "
                + "limitation(s); unmodeled runtime paths may reach additional tests")
        }
        let output = AffectedOutput(selection: selection, report: report, testCount: tests.count,
            uncertainTestCount: uncertainTests.count,
            testFileCount: testFiles.count, moduleCount: modules.count,
            runtimeEvidenceTruncated: (Array(tests.prefix(limit)) + Array(uncertainTests.prefix(limit)))
                .contains { $0.runtimeEvidenceOmitted != nil }, limit: limit)
        let scope = targetScopeEvidencePath.map { path in
            let current = try? sessionInputFingerprint()
            return targetScope(path: path, fingerprint: current == scopeFingerprint ? scopeFingerprint : nil,
                               context: context, limit: limit)
        }
        limitations += scope?.limitations ?? []
        if let precision = report.receiverPrecision, precision.excludedTransitions > 0,
           let failure = impactReceiverFinalFailure(receiver.files) {
            return try makeAffectedDocument(symbols: symbols, files: files, maxDepth: maxDepth, limit: limit,
                selectionLimitations: selectionLimitations + receiver.limitations + [failure], in: context,
                targetScopeEvidencePath: targetScopeEvidencePath,
                receiverFallback: precision.fallingBack(reason: "receiver-source-final-verification"))
        }
        return AffectedDocument(
            status: selection.status,
            requestedSymbols: Array(symbols.prefix(limit)),
            requestedFiles: Array(selection.files.prefix(limit)),
            selected: selection.selected.sorted().prefix(limit).compactMap { graph.node($0) }.map(Self.describe),
            changeScope: report.changed.prefix(limit).compactMap { graph.node($0) }.map(Self.describe),
            tests: Array(tests.prefix(limit)),
            uncertainTestCandidates: uncertainTests.isEmpty ? nil : Array(uncertainTests.prefix(limit)),
            summary: AffectedDocument.Summary(
                testCount: tests.count,
                changedTestCount: report.changed.count(where: isTest),
                changeScopeSymbols: report.changed.count,
                affectedSymbols: report.affected.count,
                testFileCount: testFiles.count,
                testFiles: Array(testFiles.prefix(limit)),
                moduleCount: modules.count,
                modules: Array(modules.prefix(limit)),
                unresolvedInputs: selection.issues.count
            ),
            selectionIssues: output.issues,
            limitations: limitations,
            truncated: .init(depth: report.truncatedByDepth, sections: output.truncatedSections
                + (report.receiverPrecision?.limited(to: limit).truncated == true ? ["receiverPrecision"] : [])),
            targetScope: scope, receiverPrecision: report.receiverPrecision?.limited(to: limit)
        )
    }

    /// 명령과 세션이 같은 문서를 쓴다. 미확인 입력은 부분 결과를 출력한 뒤 사용 오류로 알린다.
    public func affected(
        symbols: [String] = [], files: [String] = [], maxDepth: Int? = nil, limit: Int = 200,
        format: String = "text", fileSelectionIsDerived: Bool = false,
        selectionLimitations: [String] = []
    ) throws -> CommandOutcome {
        try affected(symbols: symbols, files: files, maxDepth: maxDepth, limit: limit, format: format,
            fileSelectionIsDerived: fileSelectionIsDerived, selectionLimitations: selectionLimitations,
            targetScopeEvidencePath: nil)
    }

    /// 소속 검토를 요청한 명령 경로. scheme 불명확성을 선택 실행 허가로 바꾸지 않는다.
    public func affected(
        symbols: [String] = [], files: [String] = [], maxDepth: Int? = nil, limit: Int = 200,
        format: String = "text", fileSelectionIsDerived: Bool = false,
        selectionLimitations: [String] = [], targetScopeEvidencePath: String?
    ) throws -> CommandOutcome {
        guard ["text", "json", "xcodebuild"].contains(format) else {
            throw CartographError.invalidConfiguration(
                path: projectPath, reason: "Affected format must be text, json or xcodebuild."
            )
        }
        let document = try affectedDocument(
            symbols: symbols, files: files, maxDepth: maxDepth, limit: limit,
            selectionLimitations: selectionLimitations, targetScopeEvidencePath: targetScopeEvidencePath
        )
        let incomplete = !document.selectionIssues.isEmpty
        let explanation = "Some affected inputs could not be resolved. Review selectionIssues and rebuild "
            + "the relevant targets, or inspect the pre-change index for deleted or renamed declarations."
        if format == "xcodebuild" {
            let selection = document.xcodebuildSelection()
            return CommandOutcome(
                output: selection.output,
                subjectNotFound: incomplete && !fileSelectionIsDerived,
                notFoundMessage: explanation,
                // 이름을 못 찾은 사용 오류(64)가 아니면, 거부 자체가 불완전한 분석(2)이다.
                incompleteAnalysis: incomplete && !fileSelectionIsDerived ? nil : selection.refusal,
                notes: selection.notes
            )
        }
        return CommandOutcome(
            output: format == "json" ? try Self.encodeSortedJSON(document) : document.renderAffectedText(),
            subjectNotFound: incomplete && !fileSelectionIsDerived,
            notFoundMessage: explanation,
            incompleteAnalysis: incomplete && fileSelectionIsDerived ? explanation : nil
        )
    }
}

extension AffectedDocument {
    /// 터미널에서는 테스트와 변경에서의 거리만 보여 준다. 전체 영향은 `impact` 가 답한다.
    func renderAffectedText() -> String {
        var lines = [
            "affected: \(summary.testCount) test declaration(s) reach this change"
                + " — \(summary.affectedSymbols) affected symbol(s), \(summary.testFileCount) test file(s),"
                + " \(summary.changeScopeSymbols) in change scope",
        ]
        for test in tests {
            let location = test.symbol.location.map { "\($0.path):\($0.line) " } ?? ""
            let detail: String
            if test.depth == 0 {
                detail = "changed"
            } else {
                let via = test.via.map { " via \($0.qualifiedName)" } ?? ""
                let edges = test.edges.isEmpty ? "" : " [\(test.edges.joined(separator: ", "))]"
                detail = "depth \(test.depth)\(via), \(test.relationship)\(edges)"
            }
            lines.append("  \(location)\(test.symbol.qualifiedName) (\(detail))")
        }
        if summary.testCount == 0 {
            lines.append("no test declaration reaches this change — review the affected declarations manually")
        }
        for candidate in uncertainTestCandidates ?? [] {
            let location = candidate.symbol.location.map { "\($0.path):\($0.line) " } ?? ""
            lines.append("  uncertain test marker: \(location)\(candidate.symbol.qualifiedName) "
                + "(depth \(candidate.depth), \(candidate.relationship)); framework identity not proven")
        }
        if truncated.output {
            lines.append("Truncated sections: \(truncated.sections.joined(separator: ", ")); "
                + "counts are uncapped; increase --limit")
        }
        if truncated.depth {
            lines.append("Truncated: consumer depth reached; increase --depth or omit it.")
        }
        for issue in selectionIssues {
            lines.append("Unresolved \(issue.kind): \(issue.requested) (\(issue.status))")
        }
        for limitation in limitations { lines.append("Limitation: \(limitation)") }
        if let targetScope {
            lines.append("Target scope: \(targetScope.evidenceStatus); Xcode scheme \(targetScope.schemeIdentity)")
            for path in targetScope.paths {
                lines.append("  \(path.path): \(path.classification) [\(path.blockers.joined(separator: ", "))]")
            }
            if targetScope.omittedPaths > 0 { lines.append("  omitted target scope paths: \(targetScope.omittedPaths)") }
        }
        lines.append("Static reachability only: an empty list does not prove existing tests cover this change.")
        return lines.map { PrintableText.printable($0) }.joined(separator: "\n") + "\n"
    }
}

extension AffectedDocument {
    /// `xcodebuild` 형식의 답. 표준 출력에는 인자 줄만 싣고 설명은 따로 둔다.
    struct XcodebuildSelection: Equatable {
        /// `-only-testing:` 인자 한 줄씩. 거부했으면 빈 문자열이다.
        let output: String
        /// 표준 오류로 보낼 범위 확대와 분석 한계.
        let notes: [String]
        /// 일부만 고른 목록을 내지 않은 이유. 내보냈으면 nil.
        let refusal: String?
    }

    /// 테스트마다 `-only-testing:` 인자를 만든다. 식별자를 증명하지 못한 테스트는 모듈 전체로 넓힌다.
    ///
    /// 목록이 잘렸거나 입력을 다 풀지 못했으면 인자를 하나도 내지 않는다. 인자가 없으면
    /// xcodebuild 는 모든 테스트를 돌린다 — 도달한 테스트 일부만 고른 목록보다 그쪽이 안전하다.
    func xcodebuildSelection() -> XcodebuildSelection {
        if let refusal = xcodebuildRefusal() {
            return XcodebuildSelection(output: "", notes: limitations, refusal: refusal)
        }
        let widened = tests.filter { $0.xcodebuildIdentifier == nil }
        let wholeModules = Set(widened.compactMap(\.symbol.module).filter { !$0.isEmpty })
        // 모듈 전체를 고르면 그 안의 개별 식별자는 중복이다.
        let narrowed = tests.compactMap(\.xcodebuildIdentifier).filter { identifier in
            !wholeModules.contains(String(identifier.prefix { $0 != "/" }))
        }
        let selectors = Set(narrowed).union(wholeModules).sorted()
        var notes = limitations
        if !widened.isEmpty {
            notes.insert(
                "\(widened.count) test declaration(s) are selected by their whole test module: only top-level "
                    + "XCTest classes without subclasses, and their test methods, have a provable -only-testing "
                    + "identifier.",
                at: 0
            )
        }
        let output = selectors.map { "-only-testing:" + PrintableText.printable($0) + "\n" }.joined()
        return XcodebuildSelection(output: output, notes: notes, refusal: nil)
    }

    /// 인자 목록을 내면 안 되는 이유. 일부만 고른 목록은 빠진 테스트를 조용히 건너뛴다.
    private func xcodebuildRefusal() -> String? {
        let fallback = " No -only-testing arguments were written, so xcodebuild would run every test."
        if !selectionIssues.isEmpty {
            return "Some affected inputs could not be resolved." + fallback
        }
        if truncated.output || truncated.depth {
            return "The affected test list was truncated; increase --limit or --depth." + fallback
        }
        if targetScope != nil {
            return "Target membership review does not establish the chosen Xcode scheme's test target identity."
                + " Inspect targetScope paths and run the whole suite until scheme coverage is verified." + fallback
        }
        if !(uncertainTestCandidates ?? []).isEmpty
            || limitations.contains(where: { $0.hasPrefix("unverified-test-markers:") }) {
            return "Some reached test-like declarations have no verified test framework identity." + fallback
        }
        if !tests.isEmpty, limitations.contains(where: { $0.hasPrefix("unmodeled-changed-files:") }) {
            return "Some changed files are outside the dependency model; additional tests may depend on them."
                + " Review build scripts, configuration and fixtures before narrowing the run." + fallback
        }
        // 읽지 못한 파일은 런타임 경계 자체를 만들지 못한다. 경계 경고만 확인하면
        // 그런 파일의 테스트를 빠뜨린 채 부분 선택자를 내보내므로 소스 범위도 확인한다.
        // 따라가지 않은 루트 밖 디렉터리 링크 뒤의 테스트도 그래프에 없어 같은 방식으로 빠진다.
        let coverageGaps = [
            "empty-index:", "index-staleness:", "unindexed-sources:", "missing-sources:",
            "unreadable-sources:", "header-projection:", "configured-path-filter:", "configured-edge-kinds:",
            "symlinked-directories-outside-root:", "source-discovery-exclusions:",
            "build-module-coverage:", "build-module-coverage-unknown:",
        ]
        if limitations.contains(where: { limitation in coverageGaps.contains { limitation.hasPrefix($0) } }) {
            return "Source/index coverage is incomplete; additional tests may reach this change."
                + " Restore source access, rebuild relevant targets and remove analysis filters before narrowing the run."
                + fallback
        }
        if limitations.contains(where: {
            $0.hasPrefix("unresolved-runtime-boundaries:") || $0.hasPrefix("incomplete-runtime-analysis:")
        }) {
            return "Runtime analysis is incomplete; additional tests may reach this change."
                + " Review runtime discover and rebuild before narrowing the test run." + fallback
        }
        // 빈 모듈 이름은 `-only-testing:` 빈 선택자가 되어 아무것도 고르지 못한다.
        if tests.contains(where: { $0.xcodebuildIdentifier == nil && ($0.symbol.module ?? "").isEmpty }) {
            return "A reached test declaration has no module to select." + fallback
        }
        return nil
    }
}

/// 모든 제한된 배열을 기록하고 모호한 입력 후보에도 문서 전체 예산을 적용한다.
private struct AffectedOutput {
    let issues: [ImpactDocument.SelectionIssue]
    let truncatedSections: [String]

    init(selection: ImpactSelection, report: ImpactReport, testCount: Int, uncertainTestCount: Int,
         testFileCount: Int, moduleCount: Int, runtimeEvidenceTruncated: Bool, limit: Int) {
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
            "tests": testCount, "testFiles": testFileCount, "modules": moduleCount,
            "uncertainTestCandidates": uncertainTestCount,
            "selectionIssues": selection.issues.count,
        ]
        truncatedSections = counts.filter { $0.value > limit }.map(\.key)
            + (candidatesTruncated ? ["candidates"] : [])
            + (runtimeEvidenceTruncated ? ["runtimeEvidence"] : [])
    }
}
