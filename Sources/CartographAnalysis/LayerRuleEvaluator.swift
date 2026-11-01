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
    private let projectPaths: [String]
    private let referenceLocations: [GraphEdge: SourceLocation]

    public init(layers: [LayerDefinition], rules: [LayerRule]) {
        self.init(layers: layers, rules: rules, projectPaths: [])
    }

    /// 명시한 루트에 대한 상대 경로 패턴을 적용한다. 파일 시스템을 읽지 않는다.
    ///
    /// 별칭을 해석하지 않는 순수 초기화다. 실제 동등성을 확인한 별칭이 있으면
    /// `projectPaths` 형태로 함께 전달한다.
    public init(layers: [LayerDefinition], rules: [LayerRule], projectPath: String) {
        self.init(layers: layers, rules: rules, projectPaths: [projectPath])
    }

    /// 호출자가 준비한 루트와 확인된 별칭으로만 상대 경로 후보를 만든다.
    ///
    /// 실제 경로 확인은 Kit 또는 임베더의 환경 경계가 담당한다. 판정 자체는
    /// 전달받은 문자열에만 의존하므로 메모리 그래프와 실제 실행이 같은 규칙을 쓴다.
    public init(layers: [LayerDefinition], rules: [LayerRule], projectPaths: [String],
                referenceLocations: [GraphEdge: SourceLocation] = [:]) {
        self.layers = layers
        self.rules = rules
        self.projectPaths = projectPaths
        self.referenceLocations = referenceLocations
    }

    /// 정점이 속한 레이어 이름. 어디에도 속하지 않으면 nil.
    ///
    /// 정점 이름, 모듈 이름, 파일 경로를 모두 후보로 본다. 사용자는 레이어를
    /// 때로는 디렉터리로, 때로는 타입 이름 규칙으로 정의하기 때문이다.
    /// 레이어가 `matchTargets` 를 지정했으면 그 대상의 후보만 본다.
    /// 먼저 정의된 레이어가 이긴다.
    public func layer(of node: GraphNode) -> String? {
        let candidates = candidates(of: node)
        return layers.first { $0.matches(candidates: candidates.values(for: $0.matchTargets)) }?.name
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
            /// 맞은 레이어가 대조 대상을 좁혔으면 그 대상. 좁히지 않았으면 nil.
            public var matchTargets: [LayerMatchTarget]? = nil
        }

        /// 판정에 쓰인 후보 문자열들. 맞지 않았을 때 무엇을 봤는지 알려 준다.
        public let candidates: [String]
        public let match: Match?

        public var layer: String? { match?.layer }
    }

    /// 정점의 레이어 판정 근거.
    public func assignment(of node: GraphNode) -> LayerAssignment {
        let candidates = candidates(of: node)
        for layer in layers {
            let values = candidates.values(for: layer.matchTargets)
            for pattern in layer.patterns {
                if let candidate = values.first(where: { pattern.matches($0) }) {
                    return LayerAssignment(
                        candidates: candidates.all,
                        match: .init(
                            layer: layer.name, pattern: pattern.pattern, candidate: candidate,
                            matchTargets: layer.matchTargets
                        )
                    )
                }
            }
        }
        return LayerAssignment(candidates: candidates.all, match: nil)
    }

    /// 판정 후보와 각 후보가 나온 대상.
    ///
    /// 모듈 정점은 이름·정규화 이름·모듈이 모두 같은 문자열이다. 문자열 하나가 여러 대상에서 나올 수
    /// 있으므로 대상은 집합으로 둔다 — 첫 출처만 남기면 `match_on: module` 레이어가 모듈 정점을
    /// 놓친다.
    private struct Candidates {
        /// 판정 순서 그대로, 중복 없이. 대상을 지정하지 않은 레이어와 설명이 이 목록을 쓴다.
        let all: [String]
        let targets: [String: Set<LayerMatchTarget>]

        /// 지정한 대상에서 나온 후보만, 판정 순서 그대로.
        func values(for selected: [LayerMatchTarget]?) -> [String] {
            guard let selected else { return all }
            return all.filter { !(targets[$0] ?? []).isDisjoint(with: selected) }
        }
    }

    /// 이 정점을 출발점으로 삼는 규칙들.
    public func rules(from layer: String) -> [LayerRule] {
        rules.filter { $0.from == layer }
    }

    private func candidates(of node: GraphNode) -> Candidates {
        // 모듈 정점은 이름·정규화 이름·모듈이 모두 같다. 중복을 그대로 보여 주면
        // 설명이 같은 말을 세 번 하는 꼴이 된다. 순서는 판정 순서 그대로 둔다.
        let paths = node.location.map { location in
            [location.path] + projectPaths.flatMap {
                PathFilter.matchCandidates(for: location.path, relativeTo: $0)
            }
        } ?? []
        let sourced: [(String, LayerMatchTarget)] = [(node.name, .name), (node.qualifiedName, .name)]
            + (node.module.map { [($0, .module)] } ?? [])
            + paths.map { ($0, .path) }
        var all: [String] = []
        var targets: [String: Set<LayerMatchTarget>] = [:]
        for (value, target) in sourced {
            if targets[value] == nil { all.append(value) }
            targets[value, default: []].insert(target)
        }
        return Candidates(all: all, targets: targets)
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
        violations(in: graph, assignments: layerAssignments(in: graph))
    }

    /// 위반과 규칙이 덮지 않는 정점을 배정 맵 한 번으로 같이 낸다.
    ///
    /// `evaluate` 와 `unassignedNodes` 를 나눠 부르면, 정점마다 글롭 대조를 품는
    /// 배정 맵이 두 번 만들어진다. 두 답은 명령 경로에서 항상 함께 쓰인다.
    public func assess(graph: CodeGraph) -> (violations: [LayerViolation], unassigned: [NodeID]) {
        guard !layers.isEmpty, !rules.isEmpty else { return ([], []) }
        let assignments = layerAssignments(in: graph)
        return (
            violations(in: graph, assignments: assignments),
            graph.nodeIDs.filter { assignments[$0] == nil }
        )
    }

    private func violations(in graph: CodeGraph, assignments: [NodeID: String]) -> [LayerViolation] {
        guard !rules.isEmpty else { return [] }
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
                        location: referenceLocations[edge.withWeight(1)]
                    )
                )
            }
        }
        return violations
    }
}
