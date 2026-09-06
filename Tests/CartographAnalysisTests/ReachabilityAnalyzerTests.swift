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

    @Test("생산 모듈의 프리뷰가 그 모듈을 통째로 떨어뜨리지 않는다")
    func previewsDoNotMarkTheirModuleAsATestTarget() {
        // `#Preview` 와 `PreviewProvider` 는 정의상 생산 모듈 안에, 미리 보는 뷰와
        // 같은 파일에 산다. 프리뷰를 근거로 모듈을 테스트 타깃으로 보면 프리뷰
        // 하나가 앱 모듈 전체를 분석에서 떨어뜨려, 이 기능이 겨냥하는 바로 그
        // 프로젝트가 조용히 빈 결과를 받는다.
        var builder = SnapshotBuilder()
        builder.symbol("Preview", kind: .structType, module: "App", attributes: [.preview])
        builder.symbol("View", kind: .structType, module: "App")
        builder.symbol("TestedOnly", kind: .structType, module: "App")
        builder.symbol("Spec", kind: .structType, module: "AppTests", attributes: [.testSuite])
        builder.reference(from: "Preview", to: "View", kind: .call)
        builder.reference(from: "Spec", to: "TestedOnly", kind: .call)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)

        let names = ReachabilityAnalyzer(options: .init(findsTestOnlyCode: true))
            .analyze(graph: graph, snapshot: snapshot).testOnly.map(\.name)
        #expect(names.contains("TestedOnly"))
        // 프리뷰만 붙잡고 있는 뷰도 같은 범주다.
        #expect(names.contains("View"))
        // 프리뷰 선언 자신은 보고하지 않는다.
        #expect(!names.contains("Preview"))
    }

    @Test("합성 선언은 후보로 새어 들어오지 않는다")
    func doesNotReportCompilerSynthesizedDeclarations() {
        // 합성 선언을 생산 씨앗에서 뺐기 때문에 후보로 들어올 수 있다.
        // 사용자가 손댈 수 있는 것이 아니므로 알려 줄 이유가 없다.
        var builder = SnapshotBuilder()
        builder.symbol("Spec", kind: .structType, module: "AppTests", attributes: [.testSuite])
        builder.symbol("Synthesized", kind: .structType, module: "App", attributes: [.implicit])
        builder.symbol("Real", kind: .structType, module: "App")
        builder.reference(from: "Spec", to: "Synthesized", kind: .call)
        builder.reference(from: "Spec", to: "Real", kind: .call)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)

        let names = ReachabilityAnalyzer(options: .init(findsTestOnlyCode: true))
            .analyze(graph: graph, snapshot: snapshot).testOnly.map(\.name)
        #expect(names.contains("Real"))
        #expect(!names.contains("Synthesized"))
    }

    @Test("합성된 멤버가 살려 둔 타입은 테스트 전용으로 보고하지 않는다")
    func synthesizedMemberDoesNotMakeTypeTestOnly() {
        // 아무도 쓰지 않는 구조체. memberwise init 은 합성 선언이라 뿌리가 되지만,
        // 그 보존은 감싸는 타입까지 올라가지 않는다. 그래서 구조체는 미사용으로 보고되고,
        // 테스트가 닿은 적은 없으므로 테스트 전용도 아니다.
        var builder = SnapshotBuilder()
        builder.symbol("Spec", kind: .structType, module: "AppTests", attributes: [.testSuite])
        builder.symbol("Payload", kind: .structType, module: "App")
        builder.symbol("Payload.init", kind: .initializer, module: "App", parent: "Payload", attributes: [.implicit])
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)

        let report = ReachabilityAnalyzer(options: .init(findsTestOnlyCode: true)).analyze(graph: graph, snapshot: snapshot)
        #expect(report.testOnly.isEmpty)
        #expect(report.unused.map(\.name) == ["Payload"])
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

@Suite("증인 보존은 소유 타입이 살아 있을 때만")
struct ConditionalWitnessRetentionTests {
    /// 외부 프로토콜을 만족시키는 멤버 하나를 가진 타입.
    private func snapshot(typeIsUsed: Bool) -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol("Entry", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Card", kind: .structType)
        builder.symbol("Card.body", kind: .property, parent: "Card", attributes: [.overrideDeclaration])
        builder.reference(from: "Card.body", to: "s:SwiftUI4ViewP4bodyQrvp", kind: .overrides)
        if typeIsUsed { builder.reference(from: "Entry", to: "Card", kind: .reference) }
        return builder.build()
    }

    private func report(_ snapshot: IndexSnapshot) -> UnusedCodeReport {
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        return ReachabilityAnalyzer().analyze(graph: graph, snapshot: snapshot)
    }

    @Test("아무도 만들지 않는 타입의 증인은 보존 근거를 갖지 않는다")
    func witnessOfAnUnusedTypeIsNotRetained() {
        // "프레임워크가 부른다" 는 그 타입을 누군가 만들 때만 참이다. 무조건 뿌리로 두면
        // 타입은 "미사용" 인데 그 멤버는 "보존됨" 이라고 답해, 한 답 안에서 모순이 된다.
        let result = report(snapshot(typeIsUsed: false))
        #expect(result.retentions["Card.body"] == nil)
        #expect(result.unused.map(\.name).contains("Card"))
        // 멤버는 따로 보고하지 않는다. 조상이 도달 불가라 껍데기만 남기는 삭제를 부른다.
        #expect(!result.unused.map(\.name).contains("body"))
    }

    @Test("살아 있는 타입의 증인은 그대로 보존된다")
    func witnessOfAUsedTypeStaysRetained() {
        // 프레임워크가 부르는 것을 지우면 앱이 깨진다. 이 방향은 바뀌면 안 된다.
        let result = report(snapshot(typeIsUsed: true))
        #expect(result.retentions["Card.body"] == .externalOverride)
        #expect(result.unused.isEmpty)
    }

    @Test("소유 타입이 없는 최상위 선언은 조건 없이 보존된다")
    func topLevelWitnessesHaveNoOwnerToWaitFor() {
        // 조건이 붙을 자리가 없다. 여기서 기다리게 하면 영영 살아나지 못한다.
        var builder = SnapshotBuilder()
        builder.symbol("handler", kind: .function, attributes: [.overrideDeclaration])
        builder.reference(from: "handler", to: "c:objc(cs)NSObject(im)handle", kind: .overrides)
        let result = report(builder.build())
        #expect(result.retentions["handler"] == .externalOverride)
    }

    @Test("살아나지 못한 증인은 도달 수에도 들어가지 않는다")
    func anUnactivatedWitnessIsNotCounted() {
        // 근거만 지우고 도달 표시를 남기면 `explain` 이 보고서와 다른 답을 한다.
        // 진입점 하나만 도달 가능해야 한다 — 타입도 그 증인도 아니다.
        #expect(report(snapshot(typeIsUsed: false)).reachableCount == 1)
        // 타입이 쓰이면 셋 다 살아난다.
        #expect(report(snapshot(typeIsUsed: true)).reachableCount == 3)
    }

    @Test("외부 타입의 익스텐션에 있는 증인은 기다릴 소유자가 없어 그대로 보존된다")
    func witnessesInExtensionsOfExternalTypesStayUnconditional() {
        // `extension UIImage: LocalProtocol` 의 증인은 소유 타입이 그래프에 없다.
        // 여기서 기다리게 하면 영영 살아나지 못하고, 프레임워크가 부르는 것을 지우게 된다.
        var builder = SnapshotBuilder()
        builder.symbol("draw", kind: .method, attributes: [.overrideDeclaration])
        builder.reference(from: "draw", to: "c:objc(cs)UIImage(im)draw", kind: .overrides)
        let result = report(builder.build())
        #expect(result.retentions["draw"] == .externalOverride)
        #expect(result.unused.isEmpty)
    }

    @Test("소유 타입이 나중에 살아나도 증인이 함께 살아난다")
    func aWitnessActivatesWhenItsOwnerBecomesReachableLater() {
        // 소유 타입이 진입점에서 여러 홉 뒤에 살아나는 경우다. 씨앗을 뿌릴 때 이미
        // 도달 가능한 경우만 처리하면 이 경로가 빠진다.
        var builder = SnapshotBuilder()
        builder.symbol("Entry", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Factory", kind: .structType)
        builder.symbol("Card", kind: .structType)
        builder.symbol("Card.body", kind: .property, parent: "Card", attributes: [.overrideDeclaration])
        builder.symbol("Card.helper", kind: .method, parent: "Card")
        builder.reference(from: "Entry", to: "Factory", kind: .call)
        builder.reference(from: "Factory", to: "Card", kind: .reference)
        builder.reference(from: "Card.body", to: "s:SwiftUI4ViewP4bodyQrvp", kind: .overrides)
        builder.reference(from: "Card.body", to: "Card.helper", kind: .call)

        let result = report(builder.build())
        #expect(result.retentions["Card.body"] == .externalOverride)
        // 증인이 살아나면 그것이 부르는 것도 함께 살아난다.
        #expect(!result.unused.map(\.name).contains("helper"))
    }

    @Test("소유 타입이 자기 증인으로만 도달 가능하면 둘 다 죽는다")
    func aTypeReachableOnlyThroughItsOwnWitnessStaysDead() {
        // 프로토콜 증인 디스패치는 인스턴스가 있어야 일어난다. 자기 증인만이 자신을
        // 가리키는 무리는 아무도 만들지 않는 무리이고, 통째로 죽은 것이 맞다.
        var builder = SnapshotBuilder()
        builder.symbol("Entry", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Card", kind: .structType)
        builder.symbol("Card.body", kind: .property, parent: "Card", attributes: [.overrideDeclaration])
        builder.reference(from: "Card.body", to: "s:SwiftUI4ViewP4bodyQrvp", kind: .overrides)
        builder.reference(from: "Card.body", to: "Card", kind: .reference)

        let result = report(builder.build())
        #expect(result.retentions["Card.body"] == nil)
        #expect(result.unused.map(\.name).contains("Card"))
    }
}
