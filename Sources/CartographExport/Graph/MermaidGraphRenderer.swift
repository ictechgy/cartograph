import CartographCore

/// Mermaid flowchart 형식.
///
/// GitHub 마크다운과 노션에 그대로 붙일 수 있어 리뷰·문서화에 강하다.
/// 다만 렌더러가 브라우저에서 동작하므로 정점이 많으면 실용성이 급격히 떨어진다.
/// 기본 상한을 두고, 넘으면 잘라 낸 사실을 주석으로 남긴다.
public struct MermaidGraphRenderer: GraphRendering {
    /// 렌더링할 최대 정점 수.
    public static let defaultNodeLimit = 200

    private let nodeLimit: Int

    public init(nodeLimit: Int = MermaidGraphRenderer.defaultNodeLimit) {
        self.nodeLimit = nodeLimit
    }

    public func render(_ graph: CodeGraph) -> String {
        let (nodes, truncated) = limitedNodes(of: graph)
        let keptIDs = Set(nodes.map(\.id))
        var lines = ["flowchart LR"]

        if truncated {
            lines.append(
                "%% truncated: showing \(nodes.count) of \(graph.nodeCount) nodes,"
                    + " ranked by connectivity. Use --format dot for the full graph."
            )
        }

        var identifiers: [NodeID: String] = [:]
        for (offset, node) in nodes.enumerated() {
            let identifier = "n\(offset)"
            identifiers[node.id] = identifier
            lines.append("    \(identifier)\(shape(node.kind, label: node.name))")
        }

        for edge in graph.edges {
            guard keptIDs.contains(edge.source), keptIDs.contains(edge.target),
                  let source = identifiers[edge.source], let target = identifiers[edge.target]
            else { continue }
            lines.append("    \(source) \(EdgeStyle.mermaidArrow(for: edge.kind)) \(target)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// 상한을 넘으면 연결이 많은 정점부터 남긴다.
    ///
    /// 임의로 자르면 그림이 의미를 잃는다. 연결이 많은 정점이 구조를 가장 잘 설명한다.
    private func limitedNodes(of graph: CodeGraph) -> (nodes: [GraphNode], truncated: Bool) {
        let all = graph.sortedNodes
        guard all.count > nodeLimit else { return (all, false) }
        let ranked = all.sorted { lhs, rhs in
            let lhsDegree = graph.inDegree(of: lhs.id) + graph.outDegree(of: lhs.id)
            let rhsDegree = graph.inDegree(of: rhs.id) + graph.outDegree(of: rhs.id)
            return lhsDegree != rhsDegree ? lhsDegree > rhsDegree : lhs.id < rhs.id
        }
        return (Array(ranked.prefix(nodeLimit)).sorted { $0.id < $1.id }, true)
    }

    /// 종류에 따라 다른 괄호를 써서 모양을 구분한다.
    private func shape(_ kind: SymbolKind, label: String) -> String {
        let escaped = escape(label)
        switch kind {
        case .module: return "[[\"\(escaped)\"]]"
        case .protocolType: return "([\"\(escaped)\"])"
        case .enumType: return "{{\"\(escaped)\"}}"
        case .file: return "[/\"\(escaped)\"/]"
        default: return "[\"\(escaped)\"]"
        }
    }

    /// Mermaid 라벨에서 문제를 일으키는 문자를 정리한다.
    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "#quot;")
            .replacingOccurrences(of: "<", with: "#lt;")
            .replacingOccurrences(of: ">", with: "#gt;")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
