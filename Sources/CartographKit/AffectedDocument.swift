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
    public let summary: Summary
    public let selectionIssues: [ImpactDocument.SelectionIssue]
    public let limitations: [String]
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
        /// `xcodebuild -only-testing:` 에 그대로 넘길 수 있다고 증명한 XCTest 식별자.
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
        summary: Summary,
        selectionIssues: [ImpactDocument.SelectionIssue],
        limitations: [String],
        truncated: ImpactDocument.Truncation
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
        self.summary = summary
        self.selectionIssues = selectionIssues
        self.limitations = limitations
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
        guard (1...10_000).contains(limit), maxDepth.map({ (1...128).contains($0) }) ?? true else {
            throw CartographError.invalidConfiguration(
                path: projectPath, reason: "Affected limits require 1...10000 results and an optional depth of 1...128."
            )
        }
        let context = try existingContext ?? loadContext()
        let graph = context.buildGraph(level: .symbol).graph
        let selection = ImpactSelection(symbols: symbols, files: files, projectPath: projectPath, graph: graph)
        let report = ImpactAnalyzer().analyze(changing: selection.nodes, in: graph, maxDepth: maxDepth)
        let reasons = context.impactReviewReasons()

        func isTest(_ id: NodeID) -> Bool {
            reasons[id]?.contains(where: \.isTestTargetRoot) == true
        }
        let canProveHierarchy = XCTestIdentifier.canProveClassHierarchy(
            edgeKinds: configuration.edgeKinds, narrowsPaths: configuration.narrowsPathsBeyondDefaults
        )
        func identifier(_ id: NodeID) -> String? {
            XCTestIdentifier.identifier(for: id, in: graph, canProveClassHierarchy: canProveHierarchy)
        }
        var tests: [AffectedDocument.Test] = []
        for id in report.changed where isTest(id) {
            guard let node = graph.node(id) else { continue }
            tests.append(AffectedDocument.Test(
                symbol: Self.describe(node), depth: 0, via: nil,
                relationship: "changed", edges: [], dispatchContract: nil,
                xcodebuildIdentifier: identifier(id)
            ))
        }
        for visit in report.affected where isTest(visit.node) {
            guard let node = graph.node(visit.node) else { continue }
            tests.append(AffectedDocument.Test(
                symbol: Self.describe(node), depth: visit.depth,
                via: graph.node(visit.via).map(Self.describe),
                relationship: visit.relationship.rawValue,
                edges: visit.edges.map(\.rawValue),
                dispatchContract: visit.dispatchContract.flatMap { graph.node($0) }.map(Self.describe),
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
            return lhs.symbol.qualifiedName < rhs.symbol.qualifiedName
        }
        let testFiles = Set(tests.compactMap(\.symbol.location?.path)).sorted()
        let modules = Set(tests.compactMap(\.symbol.module)).sorted()
        let limitations = analysisLimitations(context: context, symbolGraph: graph) + selectionLimitations
        let truncatedTests = tests.count > limit
        return AffectedDocument(
            status: selection.status,
            requestedSymbols: Array(symbols.prefix(limit)),
            requestedFiles: Array(selection.files.prefix(limit)),
            selected: selection.selected.sorted().prefix(limit).compactMap { graph.node($0) }.map(Self.describe),
            changeScope: report.changed.prefix(limit).compactMap { graph.node($0) }.map(Self.describe),
            tests: Array(tests.prefix(limit)),
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
            selectionIssues: selection.issues,
            limitations: limitations,
            truncated: .init(depth: report.truncatedByDepth, sections: truncatedTests ? ["tests"] : [])
        )
    }

    /// 명령과 세션이 같은 문서를 쓴다. 미확인 입력은 부분 결과를 출력한 뒤 사용 오류로 알린다.
    public func affected(
        symbols: [String] = [], files: [String] = [], maxDepth: Int? = nil, limit: Int = 200,
        format: String = "text", fileSelectionIsDerived: Bool = false,
        selectionLimitations: [String] = []
    ) throws -> CommandOutcome {
        guard ["text", "json", "xcodebuild"].contains(format) else {
            throw CartographError.invalidConfiguration(
                path: projectPath, reason: "Affected format must be text, json or xcodebuild."
            )
        }
        let document = try affectedDocument(
            symbols: symbols, files: files, maxDepth: maxDepth, limit: limit,
            selectionLimitations: selectionLimitations
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
        } else if truncated.output {
            lines.append("tests truncated: counts are uncapped; increase --limit")
        }
        if truncated.depth {
            lines.append("Truncated: consumer depth reached; increase --depth or omit it.")
        }
        for issue in selectionIssues {
            lines.append("Unresolved \(issue.kind): \(issue.requested) (\(issue.status))")
        }
        for limitation in limitations { lines.append("Limitation: \(limitation)") }
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
        // 빈 모듈 이름은 `-only-testing:` 빈 선택자가 되어 아무것도 고르지 못한다.
        if tests.contains(where: { $0.xcodebuildIdentifier == nil && ($0.symbol.module ?? "").isEmpty }) {
            return "A reached test declaration has no module to select." + fallback
        }
        return nil
    }
}
