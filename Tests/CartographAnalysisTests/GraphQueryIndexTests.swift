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

    @Test("notFound 추천은 오타와 비슷한 이름을 거리 순으로 돌려준다")
    func similarCandidatesRankByDistance() {
        let error = GraphNode(id: "usr:e", name: "CartographError()", kind: .structType, module: "Core")
        let home = GraphNode(id: "usr:h", name: "HomeView", kind: .structType, module: "App")
        let lookup = GraphQueryIndex(
            graph: CodeGraph(level: .symbol, nodes: [home, error], edges: [])
        )
        let suggestions = lookup.similarCandidates(to: "CartographErros")
        #expect(suggestions.first == error)
        #expect(!suggestions.contains(home))
    }

    @Test("추천 거리가 같으면 이름 순으로 세워 실행마다 같은 순서를 보장한다")
    func similarCandidatesAreDeterministic() {
        let second = GraphNode(id: "usr:b", name: "Abcf", kind: .structType)
        let first = GraphNode(id: "usr:a", name: "Abce", kind: .structType)
        let lookup = GraphQueryIndex(
            graph: CodeGraph(level: .symbol, nodes: [second, first], edges: [])
        )
        #expect(lookup.similarCandidates(to: "Abcd").map(\.name) == ["Abce", "Abcf"])
    }

    @Test("한 정점이 이름과 한정 이름으로 같이 걸려도 한 번만 추천된다")
    func similarCandidatesDoNotDuplicateANode() {
        // 같은 정점의 별칭 키(name·qualifiedName)가 모두 한도 안에 들면 같은
        // 정점이 목록을 두 배로 채운다. 추천은 정점을 주는 것이지 키를 주는 것이 아니다.
        let node = GraphNode(id: "usr:r", name: "UserRepX()", kind: .classType, module: "A")
        let lookup = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: [node], edges: []))
        #expect(lookup.similarCandidates(to: "UserRepX") == [node])
    }

    @Test("추천은 전혀 다른 이름과 빈 이름 앞에서 조용해진다")
    func similarCandidatesStayQuiet() {
        let node = GraphNode(id: "usr:a", name: "UserService", kind: .classType, module: "Domain")
        let lookup = GraphQueryIndex(
            graph: CodeGraph(level: .symbol, nodes: [node], edges: [])
        )
        // USR 로 직접 물었을 때는 "혹시 이것?"이 아니라 "그런 USR 은 없다"가 맞는 답이다.
        #expect(lookup.similarCandidates(to: "c:objc(cs)NSObject(im)someSelector").isEmpty)
        #expect(lookup.similarCandidates(to: "").isEmpty)
    }
}
