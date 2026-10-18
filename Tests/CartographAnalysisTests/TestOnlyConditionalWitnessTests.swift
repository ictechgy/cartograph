import CartographCore
import CartographTestSupport
import Testing

import CartographAnalysis

@Suite("테스트 전용 탐색의 조건부 외부 증인")
struct TestOnlyConditionalWitnessTests {
    @Test("테스트나 프리뷰로만 활성화된 증인은 생산 뿌리가 아니다", arguments: [
        SymbolAttribute.testSuite, .unitTest, .preview,
    ])
    func reportsHelpersOfTestOnlyWitnesses(rootAttribute: SymbolAttribute) {
        let snapshot = witnessSnapshot(rootAttribute: rootAttribute)
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let report = analyze(snapshot, graph: graph)

        // 전체 탐색에서는 증인과 호출 대상이 살아 있다. 생산 탐색에서만 소유자를 다시 판단한다.
        #expect(report.testOnly.map(\.id) == ["Card", "helper"])
        #expect(report.retentions["Card.body"] == .externalOverride)
        #expect(report.unused.isEmpty)
        #expect(report.reachableCount == (rootAttribute == .unitTest ? 6 : 5))
        let root: NodeID = rootAttribute == .unitTest ? "Origin.test" : "Origin"
        #expect(report.explain("helper", in: graph) == .reachable(
            path: [root, "Card", "Card.body", "helper"]
        ))
        expectUnchangedFullReachability(report, snapshot: snapshot, graph: graph)
    }

    @Test("생산 경로에서 소유 타입이 나중에 도달하면 증인과 도우미도 생산에서 도달한다")
    func activatesWitnessWhenProductionReachesOwnerLater() {
        var builder = witnessBuilder(rootAttribute: .testSuite)
        builder.symbol("Factory", kind: .function)
        builder.reference(from: "Entry", to: "Factory", kind: .call)
        builder.reference(from: "Factory", to: "Card", kind: .reference)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let report = analyze(snapshot, graph: graph)

        #expect(report.testOnly.isEmpty)
        #expect(report.retentions["Card.body"] == .externalOverride)
        #expect(report.unused.isEmpty)
        #expect(report.reachableCount == 6)
        expectUnchangedFullReachability(report, snapshot: snapshot, graph: graph)
    }

    @Test("생산 코드의 직접 참조는 조건부 증인을 여전히 활성화한다")
    func directProductionReferenceStillReachesWitness() {
        var builder = witnessBuilder(rootAttribute: .testSuite)
        builder.reference(from: "Entry", to: "Card.body", kind: .reference)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let report = analyze(snapshot, graph: graph)

        #expect(report.testOnly.map(\.id) == ["Card"])
        #expect(report.retentions["Card.body"] == .externalOverride)
        #expect(report.unused.isEmpty)
        #expect(report.explain("helper", in: graph) == .reachable(path: ["Entry", "Card.body", "helper"]))
        expectUnchangedFullReachability(report, snapshot: snapshot, graph: graph)
    }

    @Test("최상위 또는 소유자가 범위 밖인 증인은 무조건 생산 뿌리로 남는다", arguments: [false, true])
    func ownerlessWitnessesRemainProductionRoots(inExternalExtension: Bool) {
        var builder = SnapshotBuilder()
        builder.symbol("Entry", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Spec", kind: .structType, module: "AppTests", attributes: [.testSuite])
        if inExternalExtension {
            builder.symbol("ExternalExtension", kind: .extensionDeclaration)
            builder.reference(from: "ExternalExtension", to: "s:external.Type", kind: .extends)
        }
        builder.symbol(
            "handler", kind: .function, parent: inExternalExtension ? "ExternalExtension" : nil,
            attributes: [.overrideDeclaration]
        )
        builder.symbol("helper", kind: .function)
        builder.reference(from: "handler", to: "s:external.required", kind: .overrides)
        builder.reference(from: "handler", to: "helper", kind: .call)
        builder.reference(from: "Spec", to: "helper", kind: .call)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let report = analyze(snapshot, graph: graph)

        #expect(report.testOnly.isEmpty)
        #expect(report.retentions["handler"] == .externalOverride)
        #expect(report.unused.isEmpty)
        #expect(report.explain("helper", in: graph) == .reachable(path: ["Spec", "helper"]))
        expectUnchangedFullReachability(report, snapshot: snapshot, graph: graph)
    }

    @Test("멤버 보고 옵션도 조건부 증인의 테스트 전용 분류를 보존한다")
    func includesWitnessWhenMemberReportingIsRequested() {
        let snapshot = witnessSnapshot(rootAttribute: .testSuite)
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let report = ReachabilityAnalyzer(options: .init(
            reportMembersOfUnusedTypes: true, findsTestOnlyCode: true
        )).analyze(graph: graph, snapshot: snapshot)

        #expect(report.testOnly.map(\.id) == ["Card", "Card.body", "helper"])
        #expect(report.retentions["Card.body"] == .externalOverride)
        #expect(report.unused.isEmpty)
        #expect(report.reachableCount == 5)
    }

    private func witnessSnapshot(rootAttribute: SymbolAttribute) -> IndexSnapshot {
        witnessBuilder(rootAttribute: rootAttribute).build()
    }

    private func witnessBuilder(rootAttribute: SymbolAttribute) -> SnapshotBuilder {
        var builder = SnapshotBuilder()
        builder.symbol("Entry", kind: .structType, attributes: [.entryPoint])
        let root: String
        if rootAttribute == .unitTest {
            builder.symbol("Origin", kind: .classType, module: "AppTests")
            builder.symbol(
                "Origin.test", name: "testCard()", kind: .method, module: "AppTests",
                parent: "Origin", attributes: [.unitTest]
            )
            root = "Origin.test"
        } else {
            builder.symbol(
                "Origin", kind: .structType, module: rootAttribute == .preview ? "App" : "AppTests",
                attributes: [rootAttribute]
            )
            root = "Origin"
        }
        builder.symbol("Card", kind: .structType)
        builder.symbol("Card.body", kind: .property, parent: "Card", attributes: [.overrideDeclaration])
        builder.symbol("helper", kind: .function)
        builder.reference(from: root, to: "Card", kind: .reference)
        builder.reference(from: "Card.body", to: "s:SwiftUI4ViewP4bodyQrvp", kind: .overrides)
        builder.reference(from: "Card.body", to: "helper", kind: .call)
        return builder
    }

    private func analyze(_ snapshot: IndexSnapshot, graph: CodeGraph) -> UnusedCodeReport {
        ReachabilityAnalyzer(options: .init(findsTestOnlyCode: true))
            .analyze(graph: graph, snapshot: snapshot)
    }

    // 테스트 전용 분류를 더해도 전체 보존·도달성이나 다른 진단은 바꾸지 않는다.
    private func expectUnchangedFullReachability(
        _ actual: UnusedCodeReport, snapshot: IndexSnapshot, graph: CodeGraph
    ) {
        let baseline = ReachabilityAnalyzer().analyze(graph: graph, snapshot: snapshot)
        #expect(baseline.testOnly.isEmpty)
        #expect(actual.unused == baseline.unused)
        #expect(actual.retentions == baseline.retentions)
        #expect(actual.inheritedRetentions == baseline.inheritedRetentions)
        #expect(actual.reachableCount == baseline.reachableCount)
        #expect(actual.totalCount == baseline.totalCount)
        #expect(actual.unusedParameters == baseline.unusedParameters)
        #expect(actual.assignOnly == baseline.assignOnly)
        #expect(actual.unusedImports == baseline.unusedImports)
        #expect(actual.superfluousIgnores == baseline.superfluousIgnores)
        #expect(actual.redundantPublic == baseline.redundantPublic)
        for node in graph.nodeIDs {
            #expect(actual.explain(node, in: graph) == baseline.explain(node, in: graph))
        }
    }
}
