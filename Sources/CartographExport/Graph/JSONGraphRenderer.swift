import CartographCore
import Foundation

/// 기계 소비용 JSON 형식.
///
/// 키를 정렬해 출력한다. Foundation 의 JSONEncoder 는 객체 키 순서를 보장하지
/// 않으므로, 정렬하지 않으면 같은 그래프가 실행할 때마다 다른 파일이 되어
/// 리포트 diff 와 캐시가 모두 무의미해진다.
public struct JSONGraphRenderer: GraphRendering {
    private let prettyPrinted: Bool

    public init(prettyPrinted: Bool = true) {
        self.prettyPrinted = prettyPrinted
    }

    public func render(_ graph: CodeGraph) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(GraphDocument(graph: graph)), as: UTF8.self) + "\n"
    }
}

/// JSON 출력의 최상위 스키마.
struct GraphDocument: Encodable {
    let tool: String
    let version: String
    let level: GraphLevel
    let nodeCount: Int
    let edgeCount: Int
    let nodes: [GraphNode]
    let edges: [GraphEdge]

    init(graph: CodeGraph) {
        self.tool = Cartograph.toolName
        self.version = Cartograph.version
        self.level = graph.level
        self.nodeCount = graph.nodeCount
        self.edgeCount = graph.edgeCount
        self.nodes = graph.sortedNodes
        self.edges = graph.edges
    }
}
