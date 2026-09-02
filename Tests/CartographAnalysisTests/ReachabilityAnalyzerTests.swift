import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("데드코드 분석")
struct ReachabilityAnalyzerTests {
    /// 스냅샷을 심볼 레벨 그래프로 만들고 분석한다.
    private func analyze(
        _ snapshot: IndexSnapshot,
        retention: RetentionOptions = .default,
        options: ReachabilityAnalyzer.Options = .init()
    ) -> (report: UnusedCodeReport, graph: CodeGraph) {
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let analyzer = ReachabilityAnalyzer(policy: RetentionPolicy(options: retention), options: options)
        return (analyzer.analyze(graph: graph, snapshot: snapshot), graph)
    }

    private func unusedNames(_ report: UnusedCodeReport) -> [String] {
        report.unused.map(\.name).sorted()
    }

    @Test("진입점에서 도달할 수 없는 선언을 보고한다")
    func reportsUnreachableDeclarations() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Used", kind: .structType)
        builder.symbol("Dead", kind: .structType)
        builder.reference(from: "App", to: "Used", kind: .reference)

        let (report, _) = analyze(builder.build())
        #expect(unusedNames(report) == ["Dead"])
        #expect(report.reachableCount == 2)
        #expect(report.totalCount == 3)
    }

    @Test("서로만 참조하는 죽은 덩어리도 찾아낸다")
    func findsIsolatedDeadCluster() {
        // 참조 개수만 세는 방식으로는 절대 못 찾는 경우다.
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("DeadA", kind: .structType)
        builder.symbol("DeadB", kind: .structType)
        builder.reference(from: "DeadA", to: "DeadB", kind: .reference)
        builder.reference(from: "DeadB", to: "DeadA", kind: .reference)

        let (report, _) = analyze(builder.build())
        #expect(unusedNames(report) == ["DeadA", "DeadB"])
    }

    @Test("미사용 타입의 멤버는 따로 보고하지 않는다")
    func doesNotReportMembersOfUnusedTypes() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Dead", kind: .classType)
        builder.symbol("Dead.method", name: "method", kind: .method, parent: "Dead")
        builder.symbol("Dead.value", name: "value", kind: .property, parent: "Dead")

        let (report, _) = analyze(builder.build())
        #expect(unusedNames(report) == ["Dead"])

        let (verbose, _) = analyze(builder.build(), options: .init(reportMembersOfUnusedTypes: true))
        #expect(unusedNames(verbose) == ["Dead", "method", "value"])
    }

    @Test("보존된 멤버의 조상 타입도 함께 살린다")
    func retainedMemberKeepsItsAncestors() {
        var builder = SnapshotBuilder()
        builder.symbol("ViewController", kind: .classType)
        builder.symbol(
            "ViewController.tap", name: "tap", kind: .method,
            parent: "ViewController", attributes: [.interfaceBuilderAction]
        )
        let (report, _) = analyze(builder.build())
        #expect(report.unused.isEmpty)
    }

    @Test("컴파일러 합성 선언은 보고하지 않는다")
    func implicitDeclarationsAreNeverReported() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Synth", kind: .initializer, attributes: [.implicit])
        let (report, _) = analyze(builder.build())
        #expect(report.unused.isEmpty)
    }

    @Test("파라미터와 익스텐션 선언은 보고 대상이 아니다")
    func parametersAndExtensionsAreExcluded() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("param", kind: .parameter)
        builder.symbol("ext", kind: .extensionDeclaration)
        let (report, _) = analyze(builder.build())
        #expect(report.unused.isEmpty)
    }

    @Test("도달 비율을 계산한다")
    func reachableRatio() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Dead", kind: .structType)
        let (report, _) = analyze(builder.build())
        #expect(report.reachableRatio == 0.5)
        #expect(UnusedCodeReport(unused: [], retentions: [:], reachableCount: 0, totalCount: 0)
            .reachableRatio == 1)
    }

    @Test("살아 있는 이유를 되짚을 수 있다")
    func explainsWhyDeclarationsSurvive() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Service", kind: .classType)
        builder.symbol("Model", kind: .structType)
        builder.symbol("Dead", kind: .structType)
        builder.reference(from: "App", to: "Service", kind: .reference)
        builder.reference(from: "Service", to: "Model", kind: .reference)

        let (report, graph) = analyze(builder.build())
        #expect(report.explain("App", in: graph) == .retained(.entryPoint))
        #expect(report.explain("Model", in: graph) == .reachable(path: ["App", "Service", "Model"]))
        #expect(report.explain("Dead", in: graph) == .unreachable)
        #expect(report.explain("없음", in: graph) == .unknown)
    }

    @Test("포함 관계만으로는 멤버가 살아나지 않는다")
    func containmentDoesNotImplyUsage() {
        // 타입이 쓰인다고 해서 모든 멤버가 쓰이는 것은 아니다.
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Service", kind: .classType)
        builder.symbol("Service.used", name: "used", kind: .method, parent: "Service")
        builder.symbol("Service.unused", name: "unused", kind: .method, parent: "Service")
        builder.reference(from: "App", to: "Service", kind: .reference)
        builder.reference(from: "App", to: "Service.used", kind: .call)

        let (report, _) = analyze(builder.build())
        #expect(unusedNames(report) == ["unused"])
    }
}

@Suite("프로토콜 구현 도달성")
struct ProtocolWitnessReachabilityTests {
    /// 프로토콜을 통해 호출되는 구현.
    ///
    /// 인덱스는 `provider.load()` 호출을 요구사항 심볼에 대한 참조로만 기록한다.
    /// 구현체 메서드로 향하는 참조는 어디에도 없다.
    private func makeSnapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Providing", kind: .protocolType)
        builder.symbol("Providing.load", name: "load", kind: .method, parent: "Providing")
        builder.symbol("Impl", kind: .structType)
        builder.symbol("Impl.load", name: "load", kind: .method, parent: "Impl")
        builder.symbol("Impl.helper", name: "helper", kind: .method, parent: "Impl")

        builder.reference(from: "App", to: "Providing", kind: .reference)
        builder.reference(from: "App", to: "Providing.load", kind: .call)
        builder.reference(from: "App", to: "Impl", kind: .reference)
        builder.reference(from: "Impl", to: "Providing", kind: .conformance)
        builder.reference(from: "Impl.load", to: "Providing.load", kind: .overrides)
        builder.reference(from: "Impl.load", to: "Impl.helper", kind: .call)
        return builder.build()
    }

    private func analyze(followOverridesInReverse: Bool) -> UnusedCodeReport {
        let snapshot = makeSnapshot()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        return ReachabilityAnalyzer(options: .init(followOverridesInReverse: followOverridesInReverse))
            .analyze(graph: graph, snapshot: snapshot)
    }

    @Test("프로토콜 요구사항이 쓰이면 구현도 쓰인 것으로 본다")
    func requirementUsageReachesImplementation() {
        let report = analyze(followOverridesInReverse: true)
        #expect(report.unused.isEmpty)
    }

    @Test("구현에서 이어지는 호출까지 함께 살아난다")
    func cascadesThroughImplementation() {
        // 구현이 살아나야 그 안에서 호출하는 것들도 살아난다.
        // 이 연쇄가 끊기면 미사용 보고가 눈덩이처럼 불어난다.
        let withInversion = analyze(followOverridesInReverse: true)
        #expect(!withInversion.unused.contains { $0.name == "helper" })

        let without = analyze(followOverridesInReverse: false)
        #expect(without.unused.map(\.name).sorted() == ["helper", "load"])
    }
}
