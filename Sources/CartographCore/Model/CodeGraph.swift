/// 코드 의존성 그래프.
///
/// 생성 시점에 인접 리스트를 한 번만 만들어 두고 이후에는 읽기만 한다.
/// 분석 알고리즘들이 `successors(of:)` 를 반복 호출하므로,
/// 매번 간선 배열을 훑으면 O(V*E) 가 되는 것을 막기 위함이다.
public struct CodeGraph: Sendable {
    public let level: GraphLevel
    /// 정점 사전. 키는 정점 식별자.
    public let nodes: [NodeID: GraphNode]
    /// 중복이 합쳐지고 정렬된 간선 목록.
    public let edges: [GraphEdge]

    private let outgoing: [NodeID: [GraphEdge]]
    private let incoming: [NodeID: [GraphEdge]]

    /// 정점과 간선으로 그래프를 만든다.
    ///
    /// - 같은 (source, target, kind) 간선은 가중치를 더해 하나로 합친다.
    /// - 양쪽 끝 정점이 모두 등록된 간선만 남긴다. 외부 심볼로 향하는 간선을
    ///   흘리지 않기 위해서다.
    public init(level: GraphLevel, nodes: [GraphNode], edges: [GraphEdge]) {
        self.level = level
        self.nodes = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var merged: [EdgeSignature: Int] = [:]
        for edge in edges {
            guard self.nodes[edge.source] != nil, self.nodes[edge.target] != nil else { continue }
            let signature = EdgeSignature(source: edge.source, target: edge.target, kind: edge.kind)
            merged[signature, default: 0] += edge.weight
        }
        self.edges = merged
            .map { GraphEdge(source: $0.key.source, target: $0.key.target, kind: $0.key.kind, weight: $0.value) }
            .sorted()

        var outgoing: [NodeID: [GraphEdge]] = [:]
        var incoming: [NodeID: [GraphEdge]] = [:]
        for edge in self.edges {
            outgoing[edge.source, default: []].append(edge)
            incoming[edge.target, default: []].append(edge)
        }
        self.outgoing = outgoing
        self.incoming = incoming
    }

    /// 간선 중복 제거용 복합 키.
    private struct EdgeSignature: Hashable {
        let source: NodeID
        let target: NodeID
        let kind: EdgeKind
    }

    /// 결정적인 순서로 정렬된 정점 식별자 목록.
    public var nodeIDs: [NodeID] {
        nodes.keys.sorted()
    }

    /// 정렬된 정점 목록.
    public var sortedNodes: [GraphNode] {
        nodeIDs.compactMap { nodes[$0] }
    }

    public var nodeCount: Int { nodes.count }
    public var edgeCount: Int { edges.count }
    public var isEmpty: Bool { nodes.isEmpty }

    public func node(_ id: NodeID) -> GraphNode? { nodes[id] }
    public func contains(_ id: NodeID) -> Bool { nodes[id] != nil }

    /// 해당 정점에서 나가는 간선.
    public func outgoingEdges(from id: NodeID) -> [GraphEdge] { outgoing[id] ?? [] }

    /// 해당 정점으로 들어오는 간선.
    public func incomingEdges(to id: NodeID) -> [GraphEdge] { incoming[id] ?? [] }

    /// 후속 정점. `kinds` 를 주면 해당 종류의 간선만 따라간다.
    public func successors(of id: NodeID, kinds: Set<EdgeKind>? = nil) -> [NodeID] {
        outgoingEdges(from: id)
            .filter { kinds?.contains($0.kind) ?? true }
            .map(\.target)
    }

    /// 선행 정점.
    public func predecessors(of id: NodeID, kinds: Set<EdgeKind>? = nil) -> [NodeID] {
        incomingEdges(to: id)
            .filter { kinds?.contains($0.kind) ?? true }
            .map(\.source)
    }

    /// 나가는 간선의 서로 다른 대상 개수(원심 결합도 Ce 의 기반).
    public func outDegree(of id: NodeID) -> Int {
        Set(outgoingEdges(from: id).filter { !$0.isSelfLoop }.map(\.target)).count
    }

    /// 들어오는 간선의 서로 다른 출발점 개수(구심 결합도 Ca 의 기반).
    public func inDegree(of id: NodeID) -> Int {
        Set(incomingEdges(to: id).filter { !$0.isSelfLoop }.map(\.source)).count
    }

    /// 포함 관계를 거슬러 올라간 의미상의 부모.
    ///
    /// 익스텐션은 그 자체가 소유자가 아니다. `extension T { func f() }` 에서 f 의
    /// 어휘적 부모는 익스텐션이지만 의미상의 소유자는 T 다. 익스텐션 정점을
    /// 그대로 부모로 쓰면, 아무도 익스텐션을 "사용"하지 않으므로 살아 있는 타입의
    /// 익스텐션 멤버가 통째로 죽은 것으로 취급된다.
    public func semanticParent(of id: NodeID) -> NodeID? {
        guard let parent = incomingEdges(to: id).first(where: { $0.kind == .member })?.source else {
            return nil
        }
        guard node(parent)?.kind == .extensionDeclaration else { return parent }
        return outgoingEdges(from: parent).first { $0.kind == .extends }?.target ?? parent
    }

    /// 나가는 간선의 서로 다른 대상 개수. 종류를 주면 그 종류만 센다.
    public func outDegree(of id: NodeID, kinds: Set<EdgeKind>) -> Int {
        Set(
            outgoingEdges(from: id)
                .filter { kinds.contains($0.kind) && !$0.isSelfLoop }
                .map(\.target)
        ).count
    }

    /// 들어오는 간선의 서로 다른 출발점 개수. 종류를 주면 그 종류만 센다.
    public func inDegree(of id: NodeID, kinds: Set<EdgeKind>) -> Int {
        Set(
            incomingEdges(to: id)
                .filter { kinds.contains($0.kind) && !$0.isSelfLoop }
                .map(\.source)
        ).count
    }

    /// 조건에 맞는 정점만 남긴 부분 그래프. 양 끝이 남은 간선만 유지된다.
    public func filteringNodes(_ isIncluded: (GraphNode) -> Bool) -> CodeGraph {
        let keptNodes = sortedNodes.filter(isIncluded)
        let keptIDs = Set(keptNodes.map(\.id))
        let keptEdges = edges.filter { keptIDs.contains($0.source) && keptIDs.contains($0.target) }
        return CodeGraph(level: level, nodes: keptNodes, edges: keptEdges)
    }

    /// 조건에 맞는 간선만 남긴 그래프. 정점은 그대로 유지된다.
    public func filteringEdges(_ isIncluded: (GraphEdge) -> Bool) -> CodeGraph {
        CodeGraph(level: level, nodes: sortedNodes, edges: edges.filter(isIncluded))
    }
}

extension CodeGraph: Codable {
    private enum CodingKeys: String, CodingKey {
        case level, nodes, edges
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let level = try container.decode(GraphLevel.self, forKey: .level)
        let nodes = try container.decode([GraphNode].self, forKey: .nodes)
        let edges = try container.decode([GraphEdge].self, forKey: .edges)
        self.init(level: level, nodes: nodes, edges: edges)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(level, forKey: .level)
        try container.encode(sortedNodes, forKey: .nodes)
        try container.encode(edges, forKey: .edges)
    }
}

extension CodeGraph: Equatable {
    public static func == (lhs: CodeGraph, rhs: CodeGraph) -> Bool {
        lhs.level == rhs.level && lhs.nodes == rhs.nodes && lhs.edges == rhs.edges
    }
}
