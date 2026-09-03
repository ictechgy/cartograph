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
        let candidates = Self.candidates(of: node)
        return layers.first { $0.matches(candidates: candidates) }?.name
    }

    /// 정점이 어느 레이어에 왜 속하는지.
    ///
    /// 설정을 디버깅할 때 실제로 아픈 지점은 "이 정점이 왜 저 레이어인가"다.
    /// 이름·모듈·경로 중 무엇이 어느 패턴에 맞았는지 보여 주지 않으면, 사용자는
    /// 패턴을 바꿔 가며 결과를 추측하는 수밖에 없다.
    public struct LayerAssignment: Sendable, Equatable {
        /// 실제로 맞은 근거. 어디에도 맞지 않으면 nil.
        public struct Match: Sendable, Equatable {
            public let layer: String
            public let pattern: String
            public let candidate: String
        }

        /// 판정에 쓰인 후보 문자열들. 맞지 않았을 때 무엇을 봤는지 알려 준다.
        public let candidates: [String]
        public let match: Match?

        public var layer: String? { match?.layer }
    }

    /// 정점의 레이어 판정 근거.
    public func assignment(of node: GraphNode) -> LayerAssignment {
        let candidates = Self.candidates(of: node)
        for layer in layers {
            for pattern in layer.patterns {
                if let candidate = candidates.first(where: { pattern.matches($0) }) {
                    return LayerAssignment(
                        candidates: candidates,
                        match: .init(layer: layer.name, pattern: pattern.pattern, candidate: candidate)
                    )
                }
            }
        }
        return LayerAssignment(candidates: candidates, match: nil)
    }

    /// 이 정점을 출발점으로 삼는 규칙들.
    public func rules(from layer: String) -> [LayerRule] {
        rules.filter { $0.from == layer }
    }

    static func candidates(of node: GraphNode) -> [String] {
        // 모듈 정점은 이름·정규화 이름·모듈이 모두 같다. 중복을 그대로 보여 주면
        // 설명이 같은 말을 세 번 하는 꼴이 된다. 순서는 판정 순서 그대로 둔다.
        var seen: Set<String> = []
        return [node.name, node.qualifiedName, node.module, node.location?.path]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
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
