import CartographAnalysis
import CartographCore
@testable import CartographKit
import CryptoKit
import Foundation
import Testing

/// language-traversal 의 `graphRevision` 은 isthmus 가 불투명 문자열로 비교하는 교환 값이다.
///
/// 값은 정렬한 `[[[String]]]` 을 `JSONEncoder.cartographDefault(prettyPrinted: false)` 로 인코딩한 바이트의
/// SHA-256 이다. 큰 그래프에서 그 배열과 인코딩을 통째로 만들지 않고 같은 바이트를 조각으로 흘리므로,
/// 수정 전 구현(`referenceBytes`)과 값이 같은지와 실제로 조각으로 해시하는지를 함께 고정한다.
@Suite("그래프 지문 스트리밍")
struct GraphRevisionDigestTests {
    @Test("모든 ASCII 와 비ASCII 경계 문자가 든 그래프의 지문이 수정 전 인코딩과 같고 고정 값과 같다")
    func matchesPreviousEncodingOnEscapingGraph() throws {
        let graph = Self.escapingGraph()
        let runtime = Self.runtime(graph, pairs: [(0, 1), (0, 1), (5, 3), (130, 2)])

        let revision = CartographService.graphRevision(graph: graph, runtime: runtime, closedWorld: true)

        #expect(revision == Self.reference(graph: graph, runtime: runtime, closedWorld: true))
        // 수정 전 구현이 이 그래프에 낸 값. 직렬화 규칙이 바뀌면 isthmus 가 같은 그래프를 다른 그래프로 읽는다.
        #expect(revision == "sha256:6fc13bee85306c04f85eef287f1eec1ea0d9f4b28d1c2d08d083f27affb57d6e")
    }

    @Test("빈 그래프·열린 세계·런타임 연결 유무에서도 수정 전 인코딩과 같은 값을 낸다")
    func matchesPreviousEncodingOnEdgeShapes() throws {
        let empty = CodeGraph(level: .symbol, nodes: [], edges: [])
        let graph = Self.escapingGraph()
        let cases: [(CodeGraph, [ImpactDependency], Bool)] = [
            (empty, [], false), (empty, [], true), (graph, [], false),
            (graph, Self.runtime(graph, pairs: [(7, 7), (2, 9), (9, 2)]), false),
        ]
        for (graph, runtime, closedWorld) in cases {
            let revision = CartographService.graphRevision(graph: graph, runtime: runtime, closedWorld: closedWorld)
            #expect(revision == Self.reference(graph: graph, runtime: runtime, closedWorld: closedWorld))
        }
    }

    @Test("큰 그래프의 지문은 인코딩 전체를 만들지 않고 64 KiB 안팎 조각으로 같은 바이트를 해시한다")
    func hashesLargeGraphInChunks() throws {
        let graph = Self.largeGraph(nodeCount: 6_000)
        var chunks: [Int] = []

        let revision = CartographService.graphRevision(graph: graph, runtime: [], closedWorld: false) {
            chunks.append($0)
        }

        let encoded = Self.referenceBytes(graph: graph, runtime: [], closedWorld: false)
        #expect(encoded.count > 16 * 65_536)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0 <= 2 * 65_536 })
        #expect(chunks.reduce(0, +) == encoded.count)
        #expect(revision == Self.hexDigest(encoded))
    }

    // MARK: - 기준 구현과 그래프

    /// 수정 전 `graphRevision` 그대로: 행을 UTF-8 바이트 사전순으로 정렬해 JSONEncoder 로 인코딩한다.
    private static func referenceBytes(graph: CodeGraph, runtime: [ImpactDependency], closedWorld: Bool) -> Data {
        let lexicographic: ([String], [String]) -> Bool = { lhs, rhs in
            lhs.lexicographicallyPrecedes(rhs) { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        }
        let nodes = graph.sortedNodes.map { [$0.id.rawValue, $0.kind.rawValue] }
        let edges = graph.edges.map { [$0.source.rawValue, $0.target.rawValue, $0.kind.rawValue] }
        let connections = Set(runtime.map { [$0.source.rawValue, $0.target.rawValue] })
        let content: [[[String]]] = [nodes.sorted(by: lexicographic), edges.sorted(by: lexicographic),
            connections.sorted(by: lexicographic), [[closedWorld ? "closed-world" : "open-world"]]]
        do {
            return try JSONEncoder.cartographDefault(prettyPrinted: false).encode(content)
        } catch {
            Issue.record("기준 인코딩이 실패했다: \(error)")
            return Data()
        }
    }

    private static func reference(graph: CodeGraph, runtime: [ImpactDependency], closedWorld: Bool) -> String {
        hexDigest(referenceBytes(graph: graph, runtime: runtime, closedWorld: closedWorld))
    }

    private static func hexDigest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 이스케이프와 정렬의 경계를 모두 담은 그래프.
    ///
    /// U+0000–U+007F 를 하나씩 품은 id 마다 JSONEncoder 의 이스케이프(`"`·`\`·제어 문자)와 그대로 쓰는 문자
    /// (`/`·DEL)가 갈린다. 결합 문자 `e` + U+0301 은 `f` 보다 문자열 `<` 로는 뒤지만 UTF-8 로는 앞서고,
    /// 같은 두 정점 사이의 `reference`·`member`, `inheritance`·`import` 는 순위 순서와 rawValue 순서가 반대다.
    /// 소스에 이스케이프를 쓰지 않고 스칼라 값으로 만든다 — 편집 도구가 이스케이프를 글자로 바꾸는 일이 있다.
    private static func escapingGraph() -> CodeGraph {
        let ascii = (0..<0x80).map { "s:a" + scalarText($0) + "z" }
        let wide = [0x80, 0x9F, 0xA0, 0xE9, 0x2028, 0x2029, 0xFEFF, 0xFFFD, 0xD55C, 0x1F642]
            .map { "s:" + scalarText($0) }
        let ids = ascii + wide + ["e" + scalarText(0x301), "f", ""]
        let kinds = SymbolKind.allCases
        let nodes = ids.enumerated().map { offset, id in
            GraphNode(id: NodeID(id), name: "n\(offset)", kind: kinds[offset % kinds.count])
        }
        let pairs: [[EdgeKind]] = [[.reference, .member], [.inheritance, .importDeclaration], [.call, .conformance]]
        let edges = ids.indices.flatMap { offset in
            pairs[offset % pairs.count].map { kind in
                GraphEdge(source: NodeID(ids[offset]), target: NodeID(ids[(offset * 7 + 3) % ids.count]), kind: kind)
            }
        }
        return CodeGraph(level: .symbol, nodes: nodes, edges: edges)
    }

    /// 인코딩이 1 MiB 를 넘는 그래프. 50번째 id 마다 따옴표를 넣어 조각 경계 근처의 이스케이프도 지난다.
    private static func largeGraph(nodeCount: Int) -> CodeGraph {
        let ids = (0..<nodeCount).map { "s:5Synth\($0)V3run4mode5labelSiAA4ModeO_SStF" + ($0 % 50 == 0 ? "\"q" : "") }
        let nodes = ids.map { GraphNode(id: NodeID($0), name: "run", kind: .method) }
        let edges = ids.indices.flatMap { offset in
            [(offset * 31 + 7, EdgeKind.call), (offset * 17 + 3, .reference), (offset * 13 + 1, .member),
             (offset * 13 + 1, .reference)].map { target, kind in
                GraphEdge(source: NodeID(ids[offset]), target: NodeID(ids[target % nodeCount]), kind: kind)
            }
        }
        return CodeGraph(level: .symbol, nodes: nodes, edges: edges)
    }

    private static func runtime(_ graph: CodeGraph, pairs: [(Int, Int)]) -> [ImpactDependency] {
        let ids = graph.nodeIDs
        return pairs.map {
            ImpactDependency(source: ids[$0.0 % ids.count], target: ids[$0.1 % ids.count], contract: "c")
        }
    }

    private static func scalarText(_ value: Int) -> String {
        guard let scalar = Unicode.Scalar(value) else {
            Issue.record("스칼라가 아니다: \(value)")
            return ""
        }
        return String(Character(scalar))
    }
}
