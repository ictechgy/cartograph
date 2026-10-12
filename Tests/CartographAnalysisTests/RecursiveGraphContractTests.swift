import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("재귀 호출을 보존한 그래프의 순회 계약")
struct RecursiveGraphContractTests {
    private func fixture() -> (IndexSnapshot, CodeGraph) {
        var builder = SnapshotBuilder()
        builder.symbol("entry", kind: .function, attributes: [.entryPoint])
        builder.symbol("recurse", kind: .function)
        builder.symbol("dead", kind: .function)
        builder.reference(from: "entry", to: "recurse", kind: .call)
        builder.reference(from: "recurse", to: "recurse", kind: .call)
        builder.reference(from: "dead", to: "dead", kind: .call)
        let snapshot = builder.build()
        return (snapshot, GraphBuilder(options: .init(level: .symbol, dropSelfLoops: false)).build(from: snapshot))
    }

    @Test("재귀 자기 간선은 직접·전이 이웃에서 시작점을 되돌려주지 않는다")
    func excludesSeedFromDirectAndTransitiveQueries() {
        let (_, graph) = fixture()
        let neighborhood = GraphNeighborhood(graph: graph)
        for depth in [1, 8, 128] {
            let callers = neighborhood.usage(of: "recurse", depth: depth, limit: 100, incoming: true)
            #expect(callers.neighbors.map(\.node.id) == [NodeID("entry")])
            #expect(!callers.truncated)
            let dependencies = neighborhood.usage(of: "recurse", depth: depth, limit: 100, incoming: false)
            #expect(dependencies.neighbors.isEmpty)
            #expect(!dependencies.truncated)
        }
    }

    @Test("재귀는 기본 아키텍처 순환이 아니며 명시적 길이 1 검사에서만 보고된다")
    func keepsCycleProjectionExplicit() {
        let (_, graph) = fixture()
        #expect(CycleDetector().detectCycles(in: graph).isEmpty)
        let loops = CycleDetector(options: .init(includeSelfLoops: true, minimumLength: 1)).detectCycles(in: graph)
        #expect(loops.map(\.path) == [[NodeID("dead")], [NodeID("recurse")]])
        #expect(
            CycleDetector(options: .init(includeSelfLoops: true, minimumLength: 2))
                .detectCycles(in: graph).isEmpty)
    }

    @Test("자기 호출은 죽은 함수를 살리지 않고 영향 순회도 종료한다")
    func preservesDeadAndImpactTermination() {
        let (snapshot, graph) = fixture()
        let unused = ReachabilityAnalyzer().analyze(graph: graph, snapshot: snapshot)
        #expect(unused.unused.map(\.usr) == ["dead"])
        let impact = ImpactAnalyzer().analyze(changing: ["recurse"], in: graph)
        #expect(impact.changed == [NodeID("recurse")])
        #expect(impact.affected.map(\.node) == [NodeID("entry")])
        #expect(!impact.truncatedByDepth)
    }
}
