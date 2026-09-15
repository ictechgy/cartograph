import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("분석 범위 밖의 기반 계약")
struct FilteredBaseRetentionTests {
    @Test("스냅샷에 있어도 그래프에서 제외한 기반 메서드의 구현은 보존한다")
    func filteredBaseRemainsAnExternalContract() {
        var builder = SnapshotBuilder(path: "/project/Sources/App.swift")
        builder.symbol("Owner", kind: .classType, attributes: [.entryPoint])
        builder.symbol("Owner.callback", name: "callback()", kind: .method, parent: "Owner",
            attributes: [.overrideDeclaration])
        builder.symbol("Base.callback", name: "callback()", kind: .method, path: "/project/Hidden.swift")
        builder.reference(from: "Owner.callback", to: "Base.callback", kind: .overrides)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol,
            pathFilter: PathFilter(exclude: ["Hidden.swift"], basePath: "/project"))).build(from: snapshot)
        let policy = RetentionPolicy()
        #expect(policy.retainedNodes(in: graph, snapshot: snapshot)["Owner.callback"] == .externalOverride)
        let review = policy.reviewReasons(in: graph, snapshot: snapshot)
        #expect(review["Owner.callback"]?.contains(.externalOverride) == true)
        let report = ReachabilityAnalyzer(policy: policy).analyze(graph: graph, snapshot: snapshot)
        #expect(!report.unused.contains { $0.id == "Owner.callback" })
    }

    @Test("그래프 안에 있는 미호출 기반 계약은 외부 보존으로 살리지 않는다")
    func visibleBaseIsNotAnExternalContract() {
        var builder = SnapshotBuilder()
        builder.symbol("P", kind: .protocolType)
        builder.symbol("P.callback", name: "callback()", kind: .method, parent: "P")
        builder.symbol("Impl", kind: .structType)
        builder.symbol("Impl.callback", name: "callback()", kind: .method, parent: "Impl")
        builder.reference(from: "Impl.callback", to: "P.callback", kind: .overrides)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        #expect(RetentionPolicy().retainedNodes(in: graph, snapshot: snapshot)["Impl.callback"] == nil)
    }

    @Test("외부 타입 익스텐션 자체를 보고하지 않아도 미사용 도우미는 숨기지 않는다")
    func unreportedExternalExtensionDoesNotHideUnusedMembers() {
        var builder = SnapshotBuilder()
        builder.symbol("entry", kind: .function, attributes: [.entryPoint])
        builder.symbol("SequenceExtension", kind: .extensionDeclaration)
        builder.symbol("live", name: "live()", kind: .method, parent: "SequenceExtension")
        builder.symbol("unused", name: "unused()", kind: .method, parent: "SequenceExtension")
        builder.reference(from: "SequenceExtension", to: "s:Swift.Sequence", kind: .extends)
        builder.reference(from: "entry", to: "live", kind: .call)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let result = ReachabilityAnalyzer().analyze(graph: graph, snapshot: snapshot)
        #expect(result.unused.map(\.id) == ["unused"])
        #expect(result.explain("unused", in: graph) == .unreachable)
    }

    @Test("기반 정점이 있어도 디스패치 간선을 제외하면 계약을 보수적으로 보존한다")
    func filteredDispatchEdgeRemainsAnExternalContract() {
        var builder = SnapshotBuilder()
        builder.symbol("Owner", kind: .classType, attributes: [.entryPoint])
        builder.symbol("Owner.callback", name: "callback()", kind: .method, parent: "Owner",
            attributes: [.overrideDeclaration])
        builder.symbol("Base.callback", name: "callback()", kind: .method)
        builder.reference(from: "Owner.callback", to: "Base.callback", kind: .overrides)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol, edgeKinds: [.call, .reference, .member]))
            .build(from: snapshot)
        let policy = RetentionPolicy()
        #expect(policy.retainedNodes(in: graph, snapshot: snapshot)["Owner.callback"] == .externalOverride)
        let result = ReachabilityAnalyzer(policy: policy).analyze(graph: graph, snapshot: snapshot)
        #expect(!result.unused.contains { $0.id == "Owner.callback" })
    }
}
