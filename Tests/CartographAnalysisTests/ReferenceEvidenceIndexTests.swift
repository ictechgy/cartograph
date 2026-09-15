import CartographAnalysis
import CartographCore
import Testing

@Suite("그래프 참조 근거 색인")
struct ReferenceEvidenceIndexTests {
    @Test("스냅샷에 없는 관계는 컴파일러 위치를 만들어내지 않는다")
    func missingOccurrenceIsGraphEvidence() {
        let graph = makeGraph(["A", "B"], edges: [GraphEdge(source: "A", target: "B", kind: .call)])
        let hops = GraphNeighborhood(graph: graph).usage(of: "B", depth: 1, limit: 10, incoming: true)
            .neighbors[0].hops
        let result = ReferenceEvidenceIndex(snapshot: .init()).evidence(for: hops, limit: 20)
        #expect(result.totalCount == 1 && result.omittedCount == 0)
        #expect(result.items.first?.origin == .graph)
        #expect(result.items.first?.location == nil)
        #expect(result.items.first?.sourceUSR == "A" && result.items.first?.targetUSR == "B")
    }

    @Test("다른 출처를 보존하고 표시 예산이 0이어도 전체 개수를 유지한다")
    func preservesOriginsAndCountsWithoutDisplaying() {
        let graph = makeGraph(["A", "B"], edges: [GraphEdge(source: "A", target: "B", kind: .call)])
        let location = SourceLocation(path: "/p/A.swift", line: 5, column: 9)
        let snapshot = IndexSnapshot(references: [
            IndexedReference(sourceUSR: "A", targetUSR: "B", kind: .call, location: location, origin: .compiler),
            IndexedReference(sourceUSR: "A", targetUSR: "B", kind: .call, location: location, origin: .inferred),
        ])
        let hops = GraphNeighborhood(graph: graph).usage(of: "B", depth: 1, limit: 10, incoming: true)
            .neighbors[0].hops
        let index = ReferenceEvidenceIndex(snapshot: snapshot, graph: graph)
        let full = index.evidence(for: hops + hops, limit: 20)
        #expect(full.totalCount == 2)
        #expect(Set(full.items.map(\.origin)) == [.compiler, .inferred])
        let capped = index.evidence(for: hops, limit: 0)
        #expect(capped.items.isEmpty && capped.totalCount == 2 && capped.omittedCount == 2)
    }

    private func makeGraph(_ ids: [String], edges: [GraphEdge]) -> CodeGraph {
        CodeGraph(level: .symbol, nodes: ids.map { GraphNode(id: NodeID($0), name: $0, kind: .function) }, edges: edges)
    }
}
