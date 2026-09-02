import CartographCore

/// 인접 목록 표기로 그래프를 빠르게 만드는 헬퍼.
///
/// 알고리즘 테스트는 심볼의 세부 정보가 필요 없고 위상만 중요하므로,
/// `["A": ["B", "C"]]` 같은 표기로 의도를 그대로 드러내는 편이 낫다.
public enum TestGraph {
    /// 인접 목록으로 그래프를 만든다. 등장하는 모든 이름이 정점이 된다.
    public static func make(
        level: GraphLevel = .module,
        kind: EdgeKind = .reference,
        _ adjacency: [String: [String]]
    ) -> CodeGraph {
        var names = Set(adjacency.keys)
        for targets in adjacency.values {
            names.formUnion(targets)
        }
        let nodes = names.sorted().map { name in
            GraphNode(id: NodeID(name), name: name, kind: level == .module ? .module : .structType, module: name)
        }
        let edges = adjacency
            .sorted { $0.key < $1.key }
            .flatMap { source, targets in
                targets.map { GraphEdge(source: NodeID(source), target: NodeID($0), kind: kind) }
            }
        return CodeGraph(level: level, nodes: nodes, edges: edges)
    }

    /// 정점 하나짜리 그래프.
    public static func single(_ name: String, level: GraphLevel = .module) -> CodeGraph {
        make(level: level, [name: []])
    }
}
