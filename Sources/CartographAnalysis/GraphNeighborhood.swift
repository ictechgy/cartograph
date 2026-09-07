import CartographCore

/// 사용 관계와 포함 관계를 분리해 제한된 범위의 이웃을 계산한다.
/// 응답 직렬화는 Kit 에 두고, 순회 규칙은 다른 분석과 같은 계층에서 검증한다.
public struct GraphNeighborhood: Sendable {
    /// 도달한 정점과 그 단계의 관계를 모두 남겨 출력에서 간선 종류를 잃지 않는다.
    public struct Neighbor: Sendable, Equatable {
        public let node: GraphNode
        public let edges: [EdgeKind]
        public let depth: Int
    }

    private let graph: CodeGraph

    /// 이미 만든 그래프의 인접 목록을 재사용한다.
    public init(graph: CodeGraph) {
        self.graph = graph
    }

    /// 포함 관계만 한 단계 따라가므로 타입의 멤버가 의존자로 오인되지 않는다.
    public func containment(
        of start: NodeID,
        limit: Int,
        incoming: Bool
    ) -> (neighbors: [Neighbor], truncated: Bool) {
        let edges = incoming ? graph.incomingEdges(to: start) : graph.outgoingEdges(from: start)
        let others = edges.filter { $0.kind == .member }
            .map { incoming ? $0.source : $0.target }
        var collected: [Neighbor] = []
        var truncated = false
        for other in Set(others).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let node = graph.node(other) else { continue }
            guard collected.count < max(1, limit) else { truncated = true; break }
            collected.append(Neighbor(node: node, edges: [.member], depth: 1))
        }
        return (collected, truncated)
    }

    /// 사용 의미가 있는 간선만 따라 이웃을 모은다.
    ///
    /// 깊이와 개수를 모두 제한한다. 전이 의존자 수천 개는 결국 또 하나의 덤프이고,
    /// 이 명령이 존재하는 이유가 덤프를 만들지 않는 것이다.
    ///
    /// 따라가는 간선의 조건(`impliesUsage`)은 도달 가능성 분석이 쓰는 것과 같다.
    /// 두 집합이 어긋나면 "아무도 안 쓰는데 도달은 가능"처럼 서로 모순된 두 사실이
    /// 한 응답에 실린다.
    public func usage(
        of start: NodeID,
        depth: Int,
        limit: Int,
        incoming: Bool
    ) -> (neighbors: [Neighbor], truncated: Bool) {
        var collected: [Neighbor] = []
        var visited: Set<NodeID> = [start]
        var frontier: [NodeID] = [start]
        var truncated = false

        for level in 1...max(1, depth) {
            // 같은 이웃으로 가는 간선이 여럿일 수 있다(호출이면서 오버라이드처럼).
            // 하나만 골라 담으면 나머지 관계가 응답에서 사라지고, 무엇을 고를지도
            // 정렬 타이에 따라 실행마다 달라진다. 종류를 모아 함께 보고한다.
            var kindsByNeighbor: [NodeID: Set<EdgeKind>] = [:]
            for current in frontier {
                let edges = incoming ? graph.incomingEdges(to: current) : graph.outgoingEdges(from: current)
                for edge in edges where edge.kind.impliesUsage {
                    let other = incoming ? edge.source : edge.target
                    guard !visited.contains(other) else { continue }
                    kindsByNeighbor[other, default: []].insert(edge.kind)
                }
            }

            var next: [NodeID] = []
            for other in kindsByNeighbor.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                visited.insert(other)
                guard let node = graph.node(other), let kinds = kindsByNeighbor[other] else { continue }
                guard collected.count < max(1, limit) else { truncated = true; continue }
                collected.append(Neighbor(node: node, edges: kinds.sorted(), depth: level))
                next.append(other)
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return (collected, truncated)
    }

}
