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
