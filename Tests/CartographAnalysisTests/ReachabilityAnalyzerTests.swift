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

@Suite("증인 도달성의 경계")
struct WitnessReachabilityBoundaryTests {
    private func analyze(_ snapshot: IndexSnapshot) -> (report: UnusedCodeReport, graph: CodeGraph) {
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        return (ReachabilityAnalyzer().analyze(graph: graph, snapshot: snapshot), graph)
    }

    @Test("한 번도 만들어지지 않는 타입의 구현은 바깥 심볼을 되살리지 않는다")
    func deadWitnessDoesNotReviveOutsideSymbols() {
        // protocol P { func f() }
        // struct Live: P { func f() {} }
        // struct NeverBuilt: P { func f() { actuallyDead() } }
        // 요구사항이 쓰였다고 NeverBuilt.f 까지 살리면 actuallyDead 가 조용히 되살아난다.
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("P", kind: .protocolType)
        builder.symbol("P.f", name: "f()", kind: .method, parent: "P")
        builder.symbol("Live", kind: .structType)
        builder.symbol("Live.f", name: "f()", kind: .method, parent: "Live")
        builder.symbol("NeverBuilt", kind: .structType)
        builder.symbol("NeverBuilt.f", name: "f()", kind: .method, parent: "NeverBuilt")
        builder.symbol("actuallyDead", name: "actuallyDead()", kind: .function)

        builder.reference(from: "App", to: "P", kind: .reference)
        builder.reference(from: "App", to: "P.f", kind: .call)
        builder.reference(from: "App", to: "Live", kind: .reference)
        builder.reference(from: "Live.f", to: "P.f", kind: .overrides)
        builder.reference(from: "NeverBuilt.f", to: "P.f", kind: .overrides)
        builder.reference(from: "NeverBuilt.f", to: "actuallyDead", kind: .call)

        let (report, _) = analyze(builder.build())
        let unused = report.unused.map(\.name).sorted()
        #expect(unused.contains("actuallyDead()"))
        #expect(unused.contains("NeverBuilt"))
        // 살아 있는 타입의 구현은 그대로 살아 있어야 한다.
        #expect(!unused.contains("f()"))
    }

    @Test("소유 타입이 나중에 살아나면 그 구현도 함께 살아난다")
    func witnessRevivesWhenItsTypeBecomesReachable() {
        // 탐색 순서에 따라 타입이 요구사항보다 늦게 도달할 수 있다.
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("P", kind: .protocolType)
        builder.symbol("P.f", name: "f()", kind: .method, parent: "P")
        builder.symbol("Impl", kind: .structType)
        builder.symbol("Impl.f", name: "f()", kind: .method, parent: "Impl")
        builder.symbol("Helper", kind: .structType)

        builder.reference(from: "App", to: "P", kind: .reference)
        builder.reference(from: "App", to: "P.f", kind: .call)
        builder.reference(from: "Impl.f", to: "P.f", kind: .overrides)
        builder.reference(from: "Impl.f", to: "Helper", kind: .reference)
        // 타입은 요구사항보다 뒤에 도달한다.
        builder.reference(from: "P.f", to: "Impl", kind: .reference)

        let (report, _) = analyze(builder.build())
        #expect(report.unused.isEmpty)
    }

    @Test("살아 있는 타입의 deinit 은 런타임이 부르므로 보존된다")
    func deinitOfReachableTypeIsRetained() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Box", kind: .classType)
        builder.symbol("Box.deinit", name: "deinit", kind: .deinitializer, parent: "Box")
        builder.symbol("Dead", kind: .classType)
        builder.symbol("Dead.deinit", name: "deinit", kind: .deinitializer, parent: "Dead")
        builder.reference(from: "App", to: "Box", kind: .reference)

        let (report, _) = analyze(builder.build())
        // 살아 있는 타입의 deinit 은 보고되지 않고, 죽은 타입은 타입 한 줄로만 남는다.
        #expect(report.unused.map(\.name) == ["Dead"])
    }

    @Test("멤버 때문에 살아난 타입은 그 사실을 설명한다")
    func inheritedRetentionIsExplained() {
        // 조상은 보존 목록에도, 도달 경로에도 없다. 근거를 남기지 않으면
        // explain 이 "도달 불가"라고 답해 보고 결과와 어긋난다.
        var builder = SnapshotBuilder()
        builder.symbol("ViewController", kind: .classType)
        builder.symbol(
            "ViewController.tap", name: "tap()", kind: .method,
            parent: "ViewController", attributes: [.interfaceBuilderAction]
        )
        let (report, graph) = analyze(builder.build())
        #expect(report.unused.isEmpty)

        let explanation = report.explain("ViewController", in: graph)
        #expect(explanation == .retainedByMember(
            InheritedRetention(member: "ViewController.tap", reason: .interfaceBuilder)
        ))
    }
}

@Suite("익스텐션 소유 관계")
struct ExtensionOwnershipTests {
    private func analyze(_ snapshot: IndexSnapshot) -> (report: UnusedCodeReport, graph: CodeGraph) {
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        return (ReachabilityAnalyzer().analyze(graph: graph, snapshot: snapshot), graph)
    }

    /// `extension T { … }` 안의 선언들. T 는 앱에서 쓰인다.
    private func makeSnapshot(extensionMembers: [(usr: String, name: String, kind: SymbolKind)])
        -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("T", kind: .structType)
        builder.symbol("ext", name: "T", kind: .extensionDeclaration)
        builder.reference(from: "App", to: "T", kind: .reference)
        builder.reference(from: "ext", to: "T", kind: .extends)
        for member in extensionMembers {
            builder.symbol(member.usr, name: member.name, kind: member.kind, parent: "ext")
        }
        return builder.build()
    }

    @Test("살아 있는 타입의 익스텐션 안 미사용 메서드를 보고한다")
    func uncalledMethodInExtensionIsReported() {
        // 익스텐션 정점을 소유자로 보면 아무도 익스텐션을 "사용"하지 않으므로,
        // 살아 있는 타입의 익스텐션 멤버가 통째로 조상 필터에 가려 사라졌다.
        // Swift 에서 익스텐션은 어디에나 있으므로 데드코드 상당수가 조용히 묻힌다.
        let (report, _) = analyze(
            makeSnapshot(extensionMembers: [("ext.f", "neverCalled()", .method)])
        )
        #expect(report.unused.map(\.name) == ["neverCalled()"])
    }

    @Test("익스텐션 안 프로토콜 구현도 타입이 살아 있으면 함께 살아난다")
    func witnessInExtensionRevivesWithItsType() {
        // 증인의 소유자를 익스텐션으로 보면 타입이 살아나도 증인이 되살아나지 못한다.
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("P", kind: .protocolType)
        builder.symbol("P.f", name: "f()", kind: .method, parent: "P")
        builder.symbol("T", kind: .structType)
        builder.symbol("ext", name: "T", kind: .extensionDeclaration)
        builder.symbol("ext.f", name: "f()", kind: .method, parent: "ext")
        builder.symbol("Helper", kind: .structType)

        builder.reference(from: "App", to: "P", kind: .reference)
        builder.reference(from: "App", to: "P.f", kind: .call)
        builder.reference(from: "App", to: "T", kind: .reference)
        builder.reference(from: "ext", to: "T", kind: .extends)
        builder.reference(from: "ext.f", to: "P.f", kind: .overrides)
        builder.reference(from: "ext.f", to: "Helper", kind: .reference)

        let (report, _) = analyze(builder.build())
        #expect(report.unused.isEmpty)
    }

    @Test("익스텐션 안 열거형 케이스도 본체의 성질을 따른다")
    func enumCaseInExtensionFollowsItsEnum() {
        var builder = SnapshotBuilder()
        builder.symbol("Status", kind: .enumType, attributes: [.rawRepresentable])
        builder.symbol("ext", name: "Status", kind: .extensionDeclaration)
        builder.symbol("ext.active", name: "active", kind: .enumCase, parent: "ext")
        builder.reference(from: "ext", to: "Status", kind: .extends)
        let snapshot = builder.build()

        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let retained = RetentionPolicy().retainedNodes(in: graph, snapshot: snapshot)
        #expect(retained["ext.active"] == .rawRepresentableEnumCase)
    }
    @Test("테스트만 붙잡고 있는 생산 코드를 따로 알린다")
    func separatesTestOnlyReachability() {
        // 죽은 코드는 아니지만 테스트가 유일한 사용자라는 사실은 팀이 알아야 한다.
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, module: "App", attributes: [.entryPoint])
        builder.symbol("Calc", kind: .structType, module: "App")
        builder.symbol("Calc.prod", name: "prod", kind: .method, module: "App", parent: "Calc")
        builder.symbol("Calc.testish", name: "testish", kind: .method, module: "App", parent: "Calc")
        builder.symbol("Spec", kind: .structType, module: "AppTests", attributes: [.testSuite])
        builder.symbol(
            "Spec.check", name: "check", kind: .method, module: "AppTests",
            parent: "Spec", attributes: [.testFunction]
        )
        builder.reference(from: "App", to: "Calc.prod", kind: .call)
        builder.reference(from: "Spec.check", to: "Calc.testish", kind: .call)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)

        let report = ReachabilityAnalyzer(options: .init(findsTestOnlyCode: true))
            .analyze(graph: graph, snapshot: snapshot)
        let names = report.testOnly.map(\.name)
        #expect(names.contains("testish"))
        // 생산 코드에서 닿는 것은 테스트 전용이 아니다.
        #expect(!names.contains("prod"))
        // 테스트 선언 자신은 당연히 테스트에서만 닿는다. 그것까지 보고하면
        // 목록이 자명한 사실로 가득 찬다.
        #expect(!names.contains("check"))
        #expect(!names.contains("Spec"))
        // 미사용 판정은 그대로다. 테스트가 쓰는 것은 죽은 코드가 아니다.
        #expect(!report.unused.map(\.name).contains("testish"))
    }

    @Test("요청하지 않으면 테스트 전용을 계산하지 않는다")
    func skipsTestOnlyAnalysisByDefault() {
        var builder = SnapshotBuilder()
        builder.symbol("Spec", kind: .structType, module: "AppTests", attributes: [.testSuite])
        builder.symbol("Helper", kind: .structType, module: "App")
        builder.reference(from: "Spec", to: "Helper", kind: .call)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)

        #expect(ReachabilityAnalyzer().analyze(graph: graph, snapshot: snapshot).testOnly.isEmpty)
    }

    @Test("테스트 타깃 안의 선언은 보고하지 않는다")
    func ignoresDeclarationsInsideTestModules() {
        // 실측에서 408건 중 318건이 테스트 타깃 내부의 도우미였다. 그것까지 보고하면
        // 정작 알고 싶은 생산 코드가 묻힌다.
        var builder = SnapshotBuilder()
        builder.symbol("Spec", kind: .structType, module: "AppTests", attributes: [.testSuite])
        builder.symbol("Fixture", kind: .structType, module: "AppTests")
        builder.symbol("Prod", kind: .structType, module: "App")
        builder.reference(from: "Spec", to: "Fixture", kind: .call)
        builder.reference(from: "Spec", to: "Prod", kind: .call)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)

        let names = ReachabilityAnalyzer(options: .init(findsTestOnlyCode: true))
            .analyze(graph: graph, snapshot: snapshot).testOnly.map(\.name)
        #expect(names.contains("Prod"))
        #expect(!names.contains("Fixture"))
    }

}
