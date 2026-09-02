import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("베이스라인")
struct BaselineTests {
    private func diagnostic(_ subject: String, line: Int = 1) -> Diagnostic {
        Diagnostic(
            ruleIdentifier: "unused-symbol",
            severity: .warning,
            message: "unused",
            location: SourceLocation(path: "A.swift", line: line, column: 1),
            subject: subject
        )
    }

    @Test("베이스라인에 있는 진단은 걸러진다")
    func filtersKnownDiagnostics() {
        let baseline = Baseline.capturing([diagnostic("A"), diagnostic("B")])
        let filtered = baseline.filtering([diagnostic("A"), diagnostic("C")])
        #expect(filtered.map(\.subject) == ["C"])
    }

    @Test("줄 번호가 바뀌어도 같은 진단으로 본다")
    func lineMovesDoNotBreakBaseline() {
        let baseline = Baseline.capturing([diagnostic("A", line: 10)])
        #expect(baseline.contains(diagnostic("A", line: 480)))
        #expect(baseline.filtering([diagnostic("A", line: 480)]).isEmpty)
    }

    @Test("지문은 중복 없이 정렬되어 저장된다")
    func fingerprintsAreSortedAndUnique() {
        let baseline = Baseline(fingerprints: ["b", "a", "a"])
        #expect(baseline.fingerprints == ["a", "b"])
        #expect(baseline.version == Baseline.currentVersion)
        #expect(!baseline.isEmpty)
        #expect(Baseline(fingerprints: []).isEmpty)
    }

    @Test("캡처는 합집합이 아니라 대체다")
    func capturingReplacesRatherThanUnions() {
        // 합집합으로만 자라면 이미 고쳐진 문제가 영원히 남아
        // 나중에는 무엇이 실제로 남아 있는지 알 수 없게 된다.
        let old = Baseline.capturing([diagnostic("A"), diagnostic("B")])
        let new = Baseline.capturing([diagnostic("B")])
        #expect(new.fingerprints.count == 1)
        #expect(old.merging(new).fingerprints.count == 2)
    }

    @Test("파일로 저장하고 다시 읽을 수 있다")
    func roundTripsThroughFileSystem() throws {
        let fileSystem = InMemoryFileSystem()
        let store = BaselineStore(fileSystem: fileSystem)
        let baseline = Baseline.capturing([diagnostic("A")])

        try store.write(baseline, to: "/p/.cartograph-baseline.json")
        #expect(try store.load(from: "/p/.cartograph-baseline.json") == baseline)
        #expect(try store.loadIfPresent(at: "/p/.cartograph-baseline.json") == baseline)
        #expect(try store.loadIfPresent(at: nil) == nil)
        #expect(try store.loadIfPresent(at: "/p/none.json") == nil)
    }

    @Test("없는 파일이나 깨진 파일은 명확한 오류가 된다")
    func missingOrCorruptBaselineThrows() throws {
        let fileSystem = InMemoryFileSystem(files: ["/p/broken.json": "{ not json"])
        let store = BaselineStore(fileSystem: fileSystem)
        #expect(throws: CartographError.self) { try store.load(from: "/p/missing.json") }
        #expect(throws: CartographError.self) { try store.load(from: "/p/broken.json") }
    }
}

@Suite("분석 결과 → 진단 변환")
struct AnalysisDiagnosticsTests {
    @Test("순환은 끊을 후보와 함께 보고된다")
    func cycleDiagnosticsIncludeWeakestLink() {
        let graph = CodeGraph(
            level: .module,
            nodes: [
                GraphNode(id: "A", name: "A", kind: .module,
                          location: SourceLocation(path: "A.swift", line: 1, column: 1)),
                GraphNode(id: "B", name: "B", kind: .module),
            ],
            edges: [
                GraphEdge(source: "A", target: "B", kind: .call, weight: 9),
                GraphEdge(source: "B", target: "A", kind: .call, weight: 1),
            ]
        )
        let cycles = CycleDetector().detectCycles(in: graph)
        let diagnostics = AnalysisDiagnostics.diagnostics(for: cycles, in: graph)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].ruleIdentifier == "cycle")
        #expect(diagnostics[0].severity == .error)
        #expect(diagnostics[0].message.contains("A → B → A"))
        #expect(diagnostics[0].details.contains { $0.contains("weakest link: B → A") })
        #expect(diagnostics[0].location?.path == "A.swift")
    }

    @Test("순환 지문은 경로 회전에 영향받지 않는다")
    func cycleFingerprintIsRotationStable() {
        let forward = TestGraph.make(["A": ["B"], "B": ["A"]])
        let reversed = TestGraph.make(["B": ["A"], "A": ["B"]])
        let first = AnalysisDiagnostics.diagnostics(
            for: CycleDetector().detectCycles(in: forward), in: forward
        )
        let second = AnalysisDiagnostics.diagnostics(
            for: CycleDetector().detectCycles(in: reversed), in: reversed
        )
        #expect(first[0].fingerprint == second[0].fingerprint)
    }

    @Test("미사용 선언은 종류와 이름을 담아 보고된다")
    func unusedDiagnostics() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Dead", kind: .classType, module: "App")
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let report = ReachabilityAnalyzer().analyze(graph: graph, snapshot: snapshot)

        let diagnostics = AnalysisDiagnostics.diagnostics(for: report)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message == "class 'App.Dead' is never used")
        #expect(diagnostics[0].subject == "Dead")
        #expect(diagnostics[0].severity == .warning)
    }

    @Test("레이어 위반은 규칙 심각도를 따른다")
    func layerViolationSeverityFollowsRule() {
        let layers = [
            LayerDefinition(name: "P", patterns: ["P"]),
            LayerDefinition(name: "D", patterns: ["D"]),
        ]
        let graph = TestGraph.make(["P": ["D"]])
        let violations = LayerRuleEvaluator(
            layers: layers,
            rules: [LayerRule(from: "P", deny: ["D"], severity: .warning)]
        ).evaluate(graph: graph)

        let diagnostics = AnalysisDiagnostics.diagnostics(for: violations)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .warning)
        #expect(diagnostics[0].ruleIdentifier == "layer-violation")
        #expect(diagnostics[0].details.first?.hasPrefix("rule:") == true)
    }

    @Test("레이어 미지정 정점은 정보성으로 보고된다")
    func unassignedLayerDiagnostics() {
        let graph = TestGraph.make(["X": []])
        let diagnostics = AnalysisDiagnostics.unassignedLayerDiagnostics(for: [NodeID("X")], in: graph)
        #expect(diagnostics[0].severity == .info)
        #expect(diagnostics[0].message.contains("does not belong to any layer"))
    }

    @Test("지표 임계값 초과만 진단이 된다")
    func metricThresholds() {
        let metrics = [
            // I = 1.0, A = 1.0 → D = 1.0 (무용의 영역)
            NodeMetrics(node: "A", name: "A", afferentCoupling: 0, efferentCoupling: 4,
                        composition: TypeComposition(total: 1, abstract: 1)),
            // I = 0.5, A = 0.5 → D = 0 (주계열 위)
            NodeMetrics(node: "B", name: "B", afferentCoupling: 2, efferentCoupling: 2,
                        composition: TypeComposition(total: 2, abstract: 1)),
        ]
        let none = AnalysisDiagnostics.diagnostics(for: metrics, thresholds: .disabled)
        #expect(none.isEmpty)

        let strict = AnalysisDiagnostics.diagnostics(
            for: metrics,
            thresholds: Thresholds(maxInstability: 0.9, maxDistanceFromMainSequence: 0.1)
        )
        #expect(strict.contains { $0.ruleIdentifier == "instability" })
        #expect(strict.contains { $0.ruleIdentifier == "main-sequence-distance" })
        #expect(strict.allSatisfy { $0.subject == "A" })
    }

    @Test("개수 임계값은 초과할 때만 오류가 된다")
    func countThreshold() throws {
        try AnalysisDiagnostics.enforceCountThreshold(3, limit: nil, rule: "cycle")
        try AnalysisDiagnostics.enforceCountThreshold(0, limit: 0, rule: "cycle")
        #expect(throws: CartographError.self) {
            try AnalysisDiagnostics.enforceCountThreshold(1, limit: 0, rule: "cycle")
        }
    }
}

@Suite("베이스라인 포맷 버전")
struct BaselineVersionTests {
    @Test("지원하지 않는 포맷 버전은 거부하고 재생성을 안내한다")
    func rejectsUnsupportedVersion() throws {
        // 버전을 기록만 하고 검사하지 않으면, 지문 규칙이 바뀐 뒤 옛 파일이
        // 조용히 엉뚱한 진단을 억제한다. 억제는 침묵이라 아무도 알아채지 못한다.
        let future = """
            {"version": 99, "generatedBy": "cartograph", "fingerprints": ["unused-symbol|s:x"]}
            """
        let fileSystem = InMemoryFileSystem(files: ["/p/baseline.json": future])
        let store = BaselineStore(fileSystem: fileSystem)

        do {
            _ = try store.load(from: "/p/baseline.json")
            Issue.record("오류가 발생해야 한다")
        } catch let error as CartographError {
            let description = try #require(error.errorDescription)
            #expect(description.contains("format version 99"))
            #expect(description.contains("cartograph baseline"))
        }
    }

    @Test("현재 버전으로 쓴 파일은 그대로 읽힌다")
    func acceptsCurrentVersion() throws {
        let fileSystem = InMemoryFileSystem()
        let store = BaselineStore(fileSystem: fileSystem)
        let baseline = Baseline(fingerprints: ["unused-symbol|s:x"])
        try store.write(baseline, to: "/p/baseline.json")
        #expect(try store.load(from: "/p/baseline.json") == baseline)
    }
}
