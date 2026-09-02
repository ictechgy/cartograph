import CartographCore
import CartographTestSupport
import Foundation
import Testing

@Suite("CodeGraph")
struct CodeGraphTests {
    @Test("중복 간선은 가중치로 합쳐진다")
    func duplicateEdgesAreMerged() {
        let graph = CodeGraph(
            level: .module,
            nodes: [
                GraphNode(id: "A", name: "A", kind: .module),
                GraphNode(id: "B", name: "B", kind: .module),
            ],
            edges: [
                GraphEdge(source: "A", target: "B", kind: .call),
                GraphEdge(source: "A", target: "B", kind: .call, weight: 2),
                GraphEdge(source: "A", target: "B", kind: .reference),
            ]
        )
        #expect(graph.edgeCount == 2)
        let callEdge = graph.edges.first { $0.kind == .call }
        #expect(callEdge?.weight == 3)
    }

    @Test("양 끝 정점이 없는 간선은 버려진다")
    func danglingEdgesAreDropped() {
        let graph = CodeGraph(
            level: .module,
            nodes: [GraphNode(id: "A", name: "A", kind: .module)],
            edges: [GraphEdge(source: "A", target: "Missing", kind: .call)]
        )
        #expect(graph.edgeCount == 0)
        #expect(graph.nodeCount == 1)
    }

    @Test("인접 조회는 방향을 구분한다")
    func adjacency() {
        let graph = TestGraph.make(["A": ["B", "C"], "B": ["C"]])
        #expect(graph.successors(of: "A").sorted() == [NodeID("B"), NodeID("C")])
        #expect(graph.predecessors(of: "C").sorted() == [NodeID("A"), NodeID("B")])
        #expect(graph.successors(of: "C").isEmpty)
    }

    @Test("간선 종류로 이웃을 걸러 낼 수 있다")
    func adjacencyFilteredByKind() {
        let graph = CodeGraph(
            level: .module,
            nodes: [
                GraphNode(id: "A", name: "A", kind: .module),
                GraphNode(id: "B", name: "B", kind: .module),
                GraphNode(id: "C", name: "C", kind: .module),
            ],
            edges: [
                GraphEdge(source: "A", target: "B", kind: .call),
                GraphEdge(source: "A", target: "C", kind: .member),
            ]
        )
        #expect(graph.successors(of: "A", kinds: [.call]) == [NodeID("B")])
        #expect(graph.successors(of: "A", kinds: [.member]) == [NodeID("C")])
    }

    @Test("차수 계산은 자기 순환과 중복을 제외한다")
    func degreeIgnoresSelfLoopsAndDuplicates() {
        let graph = CodeGraph(
            level: .module,
            nodes: [
                GraphNode(id: "A", name: "A", kind: .module),
                GraphNode(id: "B", name: "B", kind: .module),
            ],
            edges: [
                GraphEdge(source: "A", target: "A", kind: .call),
                GraphEdge(source: "A", target: "B", kind: .call),
                GraphEdge(source: "A", target: "B", kind: .reference),
            ]
        )
        #expect(graph.outDegree(of: "A") == 1)
        #expect(graph.inDegree(of: "B") == 1)
        #expect(graph.inDegree(of: "A") == 0)
    }

    @Test("정점 필터는 매달린 간선까지 정리한다")
    func filteringNodesRemovesDanglingEdges() {
        let graph = TestGraph.make(["A": ["B"], "B": ["C"]])
        let filtered = graph.filteringNodes { $0.id != "B" }
        #expect(filtered.nodeCount == 2)
        #expect(filtered.edgeCount == 0)
    }

    @Test("간선 필터는 정점을 유지한다")
    func filteringEdgesKeepsNodes() {
        let graph = TestGraph.make(kind: .call, ["A": ["B"]])
        let filtered = graph.filteringEdges { $0.kind != .call }
        #expect(filtered.nodeCount == 2)
        #expect(filtered.edgeCount == 0)
    }

    @Test("직렬화는 왕복해도 동일하며 순서가 고정된다")
    func codableRoundTripIsDeterministic() throws {
        let graph = TestGraph.make(["B": ["A"], "A": ["C"], "C": []])
        // Darwin Foundation 의 JSONEncoder 는 객체 키 순서를 보장하지 않는다.
        // 리포트 diff 안정성이 목적이므로 인코더 쪽에서 .sortedKeys 를 반드시 켠다.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let first = try encoder.encode(graph)
        let second = try encoder.encode(graph)
        #expect(first == second)
        let decoded = try JSONDecoder().decode(CodeGraph.self, from: first)
        #expect(decoded == graph)
        #expect(decoded.nodeIDs == [NodeID("A"), NodeID("B"), NodeID("C")])
    }

    @Test("빈 그래프를 다룰 수 있다")
    func emptyGraph() {
        let graph = CodeGraph(level: .symbol, nodes: [], edges: [])
        #expect(graph.isEmpty)
        #expect(graph.node("nope") == nil)
        #expect(!graph.contains("nope"))
        #expect(graph.outgoingEdges(from: "nope").isEmpty)
        #expect(graph.incomingEdges(to: "nope").isEmpty)
    }
}
