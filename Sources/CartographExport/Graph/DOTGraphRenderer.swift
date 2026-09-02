import CartographCore

/// Graphviz DOT 형식.
///
/// `dot -Tsvg graph.dot -o graph.svg` 로 어디서나 그림이 된다.
/// 대규모 그래프에서 유일하게 쓸 만한 자동 배치 도구이기도 하다.
public struct DOTGraphRenderer: GraphRendering {
    /// 모듈 단위로 클러스터를 묶을지 여부. 타입/심볼 레벨에서 읽기가 크게 좋아진다.
    private let clustersByModule: Bool

    public init(clustersByModule: Bool = true) {
        self.clustersByModule = clustersByModule
    }

    public func render(_ graph: CodeGraph) -> String {
        var lines = [
            "digraph Cartograph {",
            "  graph [rankdir=LR, splines=spline, overlap=false, fontname=\"Helvetica\"];",
            "  node [shape=box, style=rounded, fontname=\"Helvetica\", fontsize=10];",
            "  edge [fontname=\"Helvetica\", fontsize=8];",
        ]

        if clustersByModule, graph.level > .module {
            lines.append(contentsOf: clusterLines(graph))
        } else {
            lines.append(contentsOf: graph.sortedNodes.map { "  \(nodeLine($0))" })
        }

        for edge in graph.edges {
            let attributes = [
                EdgeStyle.dotStyle(for: edge.kind),
                edge.weight > 1 ? "label=\"\(edge.weight)\"" : nil,
            ].compactMap { $0 }.joined(separator: ", ")
            lines.append("  \(quote(edge.source.rawValue)) -> \(quote(edge.target.rawValue)) [\(attributes)];")
        }

        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 모듈별 subgraph 블록.
    private func clusterLines(_ graph: CodeGraph) -> [String] {
        let grouped = Dictionary(grouping: graph.sortedNodes) { $0.module ?? "" }
        return grouped.keys.sorted().flatMap { module -> [String] in
            let nodes = (grouped[module] ?? []).map { "    \(nodeLine($0))" }
            guard !module.isEmpty else { return nodes }
            return ["  subgraph \"cluster_\(module)\" {", "    label=\(quote(module));"] + nodes + ["  }"]
        }
    }

    private func nodeLine(_ node: GraphNode) -> String {
        "\(quote(node.id.rawValue)) [label=\(quote(node.name)), shape=\(shape(for: node.kind))];"
    }

    private func shape(for kind: SymbolKind) -> String {
        switch kind {
        case .module: "box3d"
        case .file: "note"
        case .protocolType: "ellipse"
        case .enumType: "diamond"
        default: "box"
        }
    }

    /// DOT 문자열 리터럴로 감싼다. 큰따옴표와 역슬래시만 이스케이프하면 된다.
    private func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
