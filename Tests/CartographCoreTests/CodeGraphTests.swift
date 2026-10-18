@testable import CartographCore
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

    @Test("정렬된 정점 목록은 생성 때 한 번 만들어 두고 접근마다 같은 저장소를 돌려준다")
    func sortedViewsAreBuiltOnce() {
        let graph = TestGraph.make(["C": ["A"], "A": ["B"], "B": []])
        // 분석 한 번이 sortedNodes 를 십여 차례 읽는다. 접근마다 정점 전체를 다시 정렬하면 두 번 읽은
        // 결과가 서로 다른 배열이 된다 — 같은 저장소를 돌려주는지로 재정렬이 없음을 확인한다.
        let firstIDs = graph.nodeIDs
        let secondIDs = graph.nodeIDs
        let firstNodes = graph.sortedNodes
        let secondNodes = graph.sortedNodes
        #expect(Self.sharesStorage(firstIDs, secondIDs))
        #expect(Self.sharesStorage(firstNodes, secondNodes))
        #expect(firstIDs == [NodeID("A"), NodeID("B"), NodeID("C")])
    }

    @Test("정점 순서는 넣은 순서와 무관하게 식별자 순이고 필터·직렬화·비교 결과도 그대로다")
    func sortedViewsFollowIdentifierOrder() throws {
        var generator = SeededRandomNumberGenerator(seed: 0xA3)
        let names = (0..<64).map { "s:3App\($0 * 37 % 64)T" }
        let nodes = names.map { GraphNode(id: NodeID($0), name: $0, kind: .structType) }
        let edges = zip(names, names.dropFirst()).map {
            GraphEdge(source: NodeID($0), target: NodeID($1), kind: .call)
        }
        let graph = CodeGraph(level: .symbol, nodes: nodes.shuffled(using: &generator), edges: edges)
        let reordered = CodeGraph(level: .symbol, nodes: nodes.shuffled(using: &generator), edges: edges.reversed())
        let expected = graph.nodes.keys.sorted()
        #expect(graph.nodeIDs == expected)
        #expect(graph.sortedNodes == expected.compactMap { graph.nodes[$0] })
        #expect(reordered == graph)
        #expect(reordered.sortedNodes == graph.sortedNodes)

        let filtered = graph.filteringNodes { !$0.id.rawValue.hasSuffix("1T") }
        #expect(filtered.nodeIDs == expected.filter { !$0.rawValue.hasSuffix("1T") })
        #expect(filtered.sortedNodes.map(\.id) == filtered.nodeIDs)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let decoded = try JSONDecoder().decode(CodeGraph.self, from: encoder.encode(graph))
        #expect(decoded == graph)
        #expect(decoded.sortedNodes == graph.sortedNodes)
    }

    @Test("같은 식별자를 두 번 넣으면 먼저 넣은 정점이 정렬 목록에도 남는다")
    func sortedViewsKeepFirstDuplicate() {
        let graph = CodeGraph(
            level: .symbol,
            nodes: [
                GraphNode(id: "B", name: "first", kind: .structType),
                GraphNode(id: "A", name: "a", kind: .structType),
                GraphNode(id: "B", name: "second", kind: .structType),
            ],
            edges: []
        )
        #expect(graph.sortedNodes.map(\.name) == ["a", "first"])
        #expect(graph.nodeIDs == [NodeID("A"), NodeID("B")])
    }

    @Test("차수 사전은 간선 없는 정점까지 모두 담고 자기 순환과 중복 간선은 세지 않는다")
    func totalDegreesCoverEveryNode() {
        let graph = CodeGraph(
            level: .module,
            nodes: ["A", "B", "C", "D"].map { GraphNode(id: NodeID($0), name: $0, kind: .module) },
            edges: [
                GraphEdge(source: "A", target: "A", kind: .call),
                GraphEdge(source: "A", target: "B", kind: .call),
                GraphEdge(source: "A", target: "B", kind: .reference),
                GraphEdge(source: "C", target: "A", kind: .call),
            ]
        )
        #expect(graph.totalDegrees() == [NodeID("A"): 2, NodeID("B"): 1, NodeID("C"): 1, NodeID("D"): 0])
    }

    /// 두 배열이 같은 원소 저장소를 공유하는지. 접근마다 새로 만든 배열이면 둘이 동시에 살아 있으므로 주소가 다르다.
    private static func sharesStorage<Element>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
        lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
        }
    }
}

@Suite("GraphEdge")
struct GraphEdgeTests {
    @Test("가중치만 바꾼 복사본을 만든다")
    func withWeight() {
        let edge = GraphEdge(source: "a", target: "b", kind: .call)
        let heavier = edge.withWeight(7)
        #expect(heavier.weight == 7)
        #expect(heavier.source == edge.source)
        #expect(heavier.kind == edge.kind)
        #expect(edge.weight == 1)
    }

    @Test("자기 순환을 알아본다")
    func selfLoopDetection() {
        #expect(GraphEdge(source: "a", target: "a", kind: .call).isSelfLoop)
        #expect(!GraphEdge(source: "a", target: "b", kind: .call).isSelfLoop)
    }

    @Test("정렬 순서는 출발점, 도착점, 종류 순이다")
    func ordering() {
        let first = GraphEdge(source: "a", target: "b", kind: .call)
        let second = GraphEdge(source: "a", target: "c", kind: .call)
        let third = GraphEdge(source: "b", target: "a", kind: .call)
        #expect([third, second, first].sorted() == [first, second, third])
        #expect(GraphEdge(source: "a", target: "b", kind: .call)
            < GraphEdge(source: "a", target: "b", kind: .reference))
    }
}
