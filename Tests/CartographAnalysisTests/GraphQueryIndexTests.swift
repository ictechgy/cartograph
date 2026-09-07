import CartographAnalysis
import CartographCore
import Foundation
import Testing

@Suite("그래프 질의 색인")
struct GraphQueryIndexTests {
    @Test("같은 정점의 별칭은 중복하지 않고 동명 정점은 정렬된 후보로 남긴다")
    func aliasesAndAmbiguity() {
        let first = GraphNode(id: "a", name: "run()", kind: .function, module: "App")
        let second = GraphNode(id: "b", name: "run()", kind: .function, module: "Other")
        let graph = CodeGraph(level: .symbol, nodes: [second, first], edges: [])
        let lookup = GraphQueryIndex(graph: graph)
        #expect(lookup.resolve("run") == .ambiguous([first, second]))
        #expect(lookup.resolve("run()") == .ambiguous([first, second]))
        #expect(lookup.resolve("App.run()") == .found(first))
        #expect(lookup.resolve("a") == .found(first))
        #expect(lookup.resolve("Run") == .notFound)
        #expect(lookup.resolve("") == .notFound)
    }

    @Test("USR 정확 일치는 다른 정점의 이름보다 우선한다")
    func exactIdentifierWins() {
        let first = GraphNode(id: "usr:a", name: "Thing", kind: .structType)
        let second = GraphNode(id: "b", name: "usr:a", kind: .function)
        let lookup = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: [second, first], edges: []))
        #expect(lookup.resolve("usr:a") == .found(first))
        #expect(lookup.resolve("Thing") == .found(first))
    }

    @Test("이름 1000건을 물어도 2만 정점을 매번 정렬하지 않는다")
    func largeBatchReusesIndex() {
        let nodes = (0..<20_000).map {
            GraphNode(id: NodeID("usr:\($0)"), name: "symbol\($0)", kind: .function)
        }
        let lookup = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: nodes, edges: []))
        let clock = ContinuousClock()
        let start = clock.now
        for index in 0..<1_000 {
            #expect(lookup.resolve("symbol\(index)") == .found(nodes[index]))
        }
        // 이전 코드는 최적화 빌드에서도 8초 이상이었다. 색인 후 조회는 수 밀리초다.
        #expect(clock.now - start < .seconds(3))
    }
}
