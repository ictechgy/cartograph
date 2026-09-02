import CartographCore

/// 레이어 규칙 위반 하나.
public struct LayerViolation: Sendable, Equatable, Codable {
    public let rule: LayerRule
    public let edge: GraphEdge
    public let sourceLayer: String
    public let targetLayer: String
    public let sourceName: String
    public let targetName: String
    public let location: SourceLocation?

    public init(
        rule: LayerRule,
        edge: GraphEdge,
        sourceLayer: String,
        targetLayer: String,
        sourceName: String,
        targetName: String,
        location: SourceLocation? = nil
    ) {
        self.rule = rule
        self.edge = edge
        self.sourceLayer = sourceLayer
        self.targetLayer = targetLayer
        self.sourceName = sourceName
        self.targetName = targetName
        self.location = location
    }

    public var message: String {
        "\(sourceName) (\(sourceLayer)) depends on \(targetName) (\(targetLayer)) — \(rule.displayName)"
    }
}

/// 정점이 어느 레이어에 속하는지 판단하고, 레이어 규칙 위반을 찾는다.
///
/// ArchUnit 과 dependency-cruiser 에서 검증된 모델이다.
/// 아키텍처 결정을 문서가 아니라 CI 에서 강제할 수 있게 해 준다.
public struct LayerRuleEvaluator: Sendable {
    private let layers: [LayerDefinition]
    private let rules: [LayerRule]

    public init(layers: [LayerDefinition], rules: [LayerRule]) {
        self.layers = layers
        self.rules = rules
    }

    /// 정점이 속한 레이어 이름. 어디에도 속하지 않으면 nil.
    ///
    /// 정점 이름, 모듈 이름, 파일 경로를 모두 후보로 본다. 사용자는 레이어를
    /// 때로는 디렉터리로, 때로는 타입 이름 규칙으로 정의하기 때문이다.
    /// 먼저 정의된 레이어가 이긴다.
    public func layer(of node: GraphNode) -> String? {
        let candidates = [node.name, node.qualifiedName, node.module, node.location?.path].compactMap { $0 }
        return layers.first { $0.matches(candidates: candidates) }?.name
    }

    /// 정점 → 레이어 매핑 전체.
    public func layerAssignments(in graph: CodeGraph) -> [NodeID: String] {
        graph.sortedNodes.reduce(into: [:]) { result, node in
            result[node.id] = layer(of: node)
        }
    }

    /// 어떤 레이어에도 속하지 않은 정점들. 규칙이 실제로 덮고 있는 범위를 보여 준다.
    public func unassignedNodes(in graph: CodeGraph) -> [NodeID] {
        guard !layers.isEmpty else { return [] }
        let assignments = layerAssignments(in: graph)
        return graph.nodeIDs.filter { assignments[$0] == nil }
    }

    /// 규칙 위반 목록. 출력 순서가 고정되도록 간선 순으로 정렬된다.
    public func evaluate(graph: CodeGraph) -> [LayerViolation] {
        guard !layers.isEmpty, !rules.isEmpty else { return [] }
        let assignments = layerAssignments(in: graph)
        var violations: [LayerViolation] = []

        for edge in graph.edges {
            guard edge.kind.impliesUsage,
                  let sourceLayer = assignments[edge.source] ?? nil,
                  let targetLayer = assignments[edge.target] ?? nil
            else { continue }

            for rule in rules where rule.isViolated(from: sourceLayer, to: targetLayer) {
                violations.append(
                    LayerViolation(
                        rule: rule,
                        edge: edge,
                        sourceLayer: sourceLayer,
                        targetLayer: targetLayer,
                        sourceName: graph.node(edge.source)?.qualifiedName ?? edge.source.rawValue,
                        targetName: graph.node(edge.target)?.qualifiedName ?? edge.target.rawValue,
                        location: graph.node(edge.source)?.location
                    )
                )
            }
        }
        return violations
    }
}
