import CartographCore
@testable import CartographExport
import CartographTestSupport
import Foundation
import Testing

@Suite("그래프 렌더러")
struct GraphRendererTests {
    private func sampleGraph() -> CodeGraph {
        CodeGraph(
            level: .type,
            nodes: [
                GraphNode(id: "u:App", name: "App", kind: .structType, module: "App"),
                GraphNode(id: "u:Repo", name: "Repository", kind: .protocolType, module: "Domain"),
            ],
            edges: [GraphEdge(source: "u:App", target: "u:Repo", kind: .conformance, weight: 3)]
        )
    }

    @Test("DOT 은 모듈별 클러스터로 묶는다")
    func dotClustersByModule() throws {
        let output = try DOTGraphRenderer().render(sampleGraph())
        #expect(output.hasPrefix("digraph Cartograph {"))
        #expect(output.contains("subgraph \"cluster_App\""))
        #expect(output.contains("subgraph \"cluster_Domain\""))
        #expect(output.contains("\"u:App\" -> \"u:Repo\""))
        #expect(output.contains("label=\"3\""))
        #expect(output.hasSuffix("}\n"))
    }

    @Test("DOT 은 따옴표와 역슬래시를 이스케이프한다")
    func dotEscapesQuotes() throws {
        let graph = CodeGraph(
            level: .symbol,
            nodes: [GraphNode(id: "a\"b", name: "back\\slash", kind: .structType)],
            edges: []
        )
        let output = try DOTGraphRenderer().render(graph)
        #expect(output.contains("\"a\\\"b\""))
        #expect(output.contains("back\\\\slash"))
    }

    @Test("클러스터를 끄면 평평한 목록이 된다")
    func dotWithoutClusters() throws {
        let output = try DOTGraphRenderer(clustersByModule: false).render(sampleGraph())
        #expect(!output.contains("subgraph"))
    }

    @Test("Mermaid 는 붙여 넣을 수 있는 flowchart 를 만든다")
    func mermaidFlowchart() throws {
        let output = try MermaidGraphRenderer().render(sampleGraph())
        #expect(output.hasPrefix("flowchart LR"))
        #expect(output.contains("n0[\"App\"]"))
        #expect(output.contains("([\"Repository\"])"))
        #expect(output.contains("-.->"))
    }

    @Test("Mermaid 는 라벨의 특수문자를 정리한다")
    func mermaidEscapesLabels() throws {
        let graph = CodeGraph(
            level: .symbol,
            nodes: [GraphNode(id: "a", name: "Array<\"T\">", kind: .structType)],
            edges: []
        )
        let output = try MermaidGraphRenderer().render(graph)
        #expect(output.contains("#lt;"))
        #expect(output.contains("#quot;"))
        #expect(!output.contains("Array<\"T\">"))
    }

    @Test("Mermaid 는 같은 모양으로 그려지는 중복 간선을 합친다")
    func mermaidDeduplicatesEdges() throws {
        // call 과 reference 는 화살표 모양이 같아 그대로 두면 같은 줄이 두 번 나온다.
        let graph = CodeGraph(
            level: .module,
            nodes: [
                GraphNode(id: "a", name: "A", kind: .module),
                GraphNode(id: "b", name: "B", kind: .module),
            ],
            edges: [
                GraphEdge(source: "a", target: "b", kind: .call),
                GraphEdge(source: "a", target: "b", kind: .reference),
            ]
        )
        let lines = try MermaidGraphRenderer().render(graph).split(separator: "\n")
        #expect(lines.filter { $0.contains("-->") }.count == 1)
    }

    @Test("Mermaid 는 상한을 넘으면 연결이 많은 정점부터 남긴다")
    func mermaidTruncatesByConnectivity() throws {
        var adjacency: [String: [String]] = ["hub": []]
        for index in 0..<10 {
            adjacency["leaf\(index)"] = ["hub"]
        }
        let graph = TestGraph.make(adjacency)
        let output = try MermaidGraphRenderer(nodeLimit: 3).render(graph)
        #expect(output.contains("%% truncated: showing 3 of 11 nodes"))
        #expect(output.contains("\"hub\""))
    }

    @Test("JSON 은 키가 정렬되어 결정적으로 출력된다")
    func jsonIsDeterministic() throws {
        let renderer = JSONGraphRenderer()
        let first = try renderer.render(sampleGraph())
        let second = try renderer.render(sampleGraph())
        #expect(first == second)
        #expect(first.contains("\"nodeCount\" : 2"))
        #expect(first.contains("\"level\" : \"type\""))
        #expect(first.contains("\"tool\" : \"cartograph\""))
    }

    @Test("JSON 은 다시 읽을 수 있다")
    func jsonRoundTrips() throws {
        let output = try JSONGraphRenderer(prettyPrinted: false).render(sampleGraph())
        let decoded = try JSONDecoder().decode(CodeGraph.self, from: Data(output.utf8))
        #expect(decoded == sampleGraph())
    }

    @Test("HTML 은 외부 리소스를 불러오지 않는다")
    func htmlIsSelfContained() throws {
        let output = try HTMLGraphRenderer().render(sampleGraph())
        #expect(output.hasPrefix("<!DOCTYPE html>"))
        #expect(!output.contains("src=\"http"))
        #expect(!output.contains("href=\"http"))
        #expect(!output.contains("cdn."))
        #expect(output.contains("<canvas id=\"canvas\">"))
        #expect(output.contains("\"nodeCount\":2"))
    }

    @Test("HTML 도 상한을 넘으면 연결이 많은 정점부터 남긴다")
    func htmlTruncatesLargeGraphs() throws {
        // 힘 기반 배치는 정점 수의 제곱에 비례한다. 심볼 그래프를 그대로 넘기면
        // 브라우저가 멈춘다.
        var adjacency: [String: [String]] = ["hub": []]
        for index in 0..<12 {
            adjacency["leaf\(index)"] = ["hub"]
        }
        let graph = TestGraph.make(adjacency)
        let output = try HTMLGraphRenderer(nodeLimit: 4).render(graph)
        #expect(output.contains("truncated from 13 nodes"))
        #expect(output.contains("\"nodeCount\":4"))
        #expect(output.contains("hub"))
    }

    @Test("상한 안에서는 잘라 냈다는 표시가 없다")
    func htmlWithinLimitHasNoNotice() throws {
        let output = try HTMLGraphRenderer().render(sampleGraph())
        #expect(!output.contains("truncated from"))
    }

    @Test("HTML 은 데이터 안의 스크립트 종료 태그를 무력화한다")
    func htmlEscapesClosingScriptTag() {
        let escaped = HTMLGraphRenderer.escapeForScriptTag("{\"name\":\"</script><script>alert(1)</script>\"}")
        #expect(!escaped.contains("</script>"))
        #expect(escaped.contains("<\\/script>"))
    }

    @Test("팩토리가 형식에 맞는 렌더러를 만든다")
    func factoryProducesRenderers() throws {
        for format in GraphFormat.allCases {
            let output = try GraphRendererFactory.make(format).render(sampleGraph())
            #expect(!output.isEmpty)
        }
    }

    @Test("빈 그래프도 유효한 출력을 만든다")
    func emptyGraphRendersCleanly() throws {
        let empty = CodeGraph(level: .module, nodes: [], edges: [])
        for format in GraphFormat.allCases {
            #expect(!(try GraphRendererFactory.make(format).render(empty)).isEmpty)
        }
    }
}
