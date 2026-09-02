import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("아키텍처 지표")
struct ArchitectureMetricsTests {
    @Test("구심/원심 결합도를 센다")
    func couplingCounts() {
        let graph = TestGraph.make(["A": ["B", "C"], "D": ["B"]])
        let metrics = ArchitectureMetricsCalculator().calculate(graph: graph, compositions: [:])
        let b = try! #require(metrics.first { $0.node == "B" })
        #expect(b.afferentCoupling == 2)
        #expect(b.efferentCoupling == 0)
        let a = try! #require(metrics.first { $0.node == "A" })
        #expect(a.afferentCoupling == 0)
        #expect(a.efferentCoupling == 2)
    }

    @Test("불안정도는 I = Ce / (Ca + Ce) 이다")
    func instabilityFormula() {
        let metrics = NodeMetrics(
            node: "A",
            name: "A",
            afferentCoupling: 1,
            efferentCoupling: 3,
            composition: TypeComposition(total: 0, abstract: 0)
        )
        #expect(metrics.instability == 0.75)
    }

    @Test("고립 정점의 불안정도는 1이 아니라 0이다")
    func isolatedNodeIsStable() {
        // 아무 관계도 없는 정점을 가장 불안정하다고 보고하면
        // 지표 상위가 고립 모듈로 채워져 실제 신호를 가린다.
        let metrics = NodeMetrics(
            node: "A",
            name: "A",
            afferentCoupling: 0,
            efferentCoupling: 0,
            composition: TypeComposition(total: 1, abstract: 0)
        )
        #expect(metrics.instability == 0)
    }

    @Test("추상도는 추상 타입 비율이며 타입이 없으면 0이다")
    func abstractnessFormula() {
        #expect(TypeComposition(total: 4, abstract: 1).abstractness == 0.25)
        #expect(TypeComposition(total: 0, abstract: 0).abstractness == 0)
    }

    @Test("주계열 거리는 |A + I - 1| 이다")
    func distanceFormula() {
        let balanced = NodeMetrics(
            node: "A", name: "A", afferentCoupling: 1, efferentCoupling: 1,
            composition: TypeComposition(total: 2, abstract: 1)
        )
        #expect(balanced.distanceFromMainSequence == 0)
        #expect(balanced.zone(tolerance: 0.3) == .mainSequence)
    }

    @Test("구체적이면서 많이 의존받으면 고통의 영역이다")
    func zoneOfPain() {
        let painful = NodeMetrics(
            node: "A", name: "A", afferentCoupling: 10, efferentCoupling: 0,
            composition: TypeComposition(total: 5, abstract: 0)
        )
        #expect(painful.instability == 0)
        #expect(painful.abstractness == 0)
        #expect(painful.distanceFromMainSequence == 1)
        #expect(painful.zone(tolerance: 0.3) == .zoneOfPain)
    }

    @Test("추상적인데 아무도 의존하지 않으면 무용의 영역이다")
    func zoneOfUselessness() {
        let useless = NodeMetrics(
            node: "A", name: "A", afferentCoupling: 0, efferentCoupling: 5,
            composition: TypeComposition(total: 2, abstract: 2)
        )
        #expect(useless.instability == 1)
        #expect(useless.abstractness == 1)
        #expect(useless.zone(tolerance: 0.3) == .zoneOfUselessness)
    }

    @Test("결과는 주계열에서 먼 순으로 정렬된다")
    func sortedByDistanceDescending() {
        let graph = TestGraph.make(["A": ["B"], "B": []])
        let metrics = ArchitectureMetricsCalculator().calculate(
            graph: graph,
            compositions: [
                NodeID("A"): TypeComposition(total: 1, abstract: 0),
                NodeID("B"): TypeComposition(total: 2, abstract: 1),
            ]
        )
        #expect(metrics.count == 2)
        #expect(metrics[0].distanceFromMainSequence >= metrics[1].distanceFromMainSequence)
    }

    @Test("스냅샷에서 타입 구성을 세어 지표를 만든다")
    func computesCompositionFromSnapshot() {
        var builder = SnapshotBuilder()
        builder.symbol("Repo", kind: .protocolType, module: "Domain", path: "/p/Domain/Repo.swift")
        builder.symbol("User", kind: .structType, module: "Domain", path: "/p/Domain/User.swift")
        builder.symbol("Client", kind: .classType, module: "App", path: "/p/App/Client.swift")
        builder.reference(from: "Client", to: "Repo", kind: .conformance)

        let result = GraphBuilder(options: .init(level: .module)).buildResult(from: builder.build())
        let metrics = ArchitectureMetricsCalculator().calculate(result: result, snapshot: builder.build())

        let domain = try! #require(metrics.first { $0.node == "Domain" })
        #expect(domain.composition == TypeComposition(total: 2, abstract: 1))
        #expect(domain.abstractness == 0.5)
        #expect(domain.afferentCoupling == 1)
    }

    @Test("익스텐션은 타입 수에 포함하지 않는다")
    func extensionsAreNotCountedAsTypes() {
        var builder = SnapshotBuilder()
        builder.symbol("User", kind: .structType, module: "Domain")
        builder.symbol("ext1", name: "User", kind: .extensionDeclaration, module: "Domain")
        builder.symbol("ext2", name: "User", kind: .extensionDeclaration, module: "Domain")
        let snapshot = builder.build()
        let result = GraphBuilder(options: .init(level: .module)).buildResult(from: snapshot)
        let compositions = ArchitectureMetricsCalculator.typeCompositions(result: result, snapshot: snapshot)
        #expect(compositions[NodeID("Domain")] == TypeComposition(total: 1, abstract: 0))
    }

    @Test("구성이 없는 정점은 추상도 0으로 다룬다")
    func missingCompositionDefaultsToZero() {
        let graph = TestGraph.make(["A": []])
        let metrics = ArchitectureMetricsCalculator().calculate(graph: graph, compositions: [:])
        #expect(metrics[0].composition == TypeComposition(total: 0, abstract: 0))
        #expect(ArchitectureMetricsCalculator().tolerance == 0.3)
    }
}

@Suite("고립 정점 지표")
struct IsolatedNodeMetricsTests {
    private func isolatedConcrete() -> NodeMetrics {
        NodeMetrics(
            node: "Alone", name: "Alone", afferentCoupling: 0, efferentCoupling: 0,
            composition: TypeComposition(total: 3, abstract: 0)
        )
    }

    @Test("고립 정점은 별도 영역으로 분류한다")
    func isolatedNodesGetTheirOwnZone() {
        // 고립 + 구체는 I=0, A=0 이라 D=1 이 되어 "고통의 영역" 1위를 차지한다.
        // 실제로는 아무와도 얽혀 있지 않아 정반대 상황이다.
        let metrics = isolatedConcrete()
        #expect(metrics.isIsolated)
        #expect(metrics.distanceFromMainSequence == 1)
        #expect(metrics.zone(tolerance: 0.3) == .isolated)
    }

    @Test("고립 정점은 순위 맨 아래로 간다")
    func isolatedNodesRankLast() {
        let graph = CodeGraph(
            level: .module,
            nodes: [
                GraphNode(id: "Alone", name: "Alone", kind: .module),
                GraphNode(id: "A", name: "A", kind: .module),
                GraphNode(id: "B", name: "B", kind: .module),
            ],
            edges: [GraphEdge(source: "A", target: "B", kind: .call)]
        )
        let metrics = ArchitectureMetricsCalculator().calculate(
            graph: graph,
            compositions: [
                NodeID("Alone"): TypeComposition(total: 3, abstract: 0),
                NodeID("A"): TypeComposition(total: 1, abstract: 0),
                NodeID("B"): TypeComposition(total: 1, abstract: 0),
            ]
        )
        #expect(metrics.last?.node == NodeID("Alone"))
    }

    @Test("고립 정점은 임계값 판정에서 제외된다")
    func isolatedNodesAreExemptFromThresholds() {
        let diagnostics = AnalysisDiagnostics.diagnostics(
            for: [isolatedConcrete()],
            thresholds: Thresholds(maxInstability: 0.0, maxDistanceFromMainSequence: 0.1)
        )
        #expect(diagnostics.isEmpty)
    }
}
