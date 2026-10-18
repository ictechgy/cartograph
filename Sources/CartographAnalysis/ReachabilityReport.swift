import CartographCore

/// 발견 목록을 만들지 않고 질의에 필요한 도달 근거만 보관한다.
///
/// 공개 데드코드 보고서를 빈 발견 목록으로 가장하지 않는다. 패키지 안의 질의 조립만
/// 이 값을 쓰며, 보존 정책과 탐색은 전체 분석과 같은 준비 단계에서 나온다.
package struct ReachabilityReport: Sendable, Equatable {
    package let retentions: [NodeID: RetentionReason]
    package let inheritedRetentions: [NodeID: InheritedRetention]
    private let predecessors: [NodeID: NodeID]

    package init(
        retentions: [NodeID: RetentionReason],
        inheritedRetentions: [NodeID: InheritedRetention],
        predecessors: [NodeID: NodeID]
    ) {
        self.retentions = retentions
        self.inheritedRetentions = inheritedRetentions
        self.predecessors = predecessors
    }

    /// 전체 분석과 질의가 같은 우선순위와 순환 방어로 설명을 복원한다.
    package func explain(_ node: NodeID, in graph: CodeGraph) -> ReachabilityExplanation {
        guard graph.contains(node) else { return .unknown }
        if let reason = retentions[node] { return .retained(reason) }
        if let inherited = inheritedRetentions[node] { return .retainedByMember(inherited) }
        guard predecessors[node] != nil else { return .unreachable }

        var path: [NodeID] = [node]
        var current = node
        var visited: Set<NodeID> = [node]
        while let previous = predecessors[current], visited.insert(previous).inserted {
            path.append(previous)
            current = previous
        }
        return .reachable(path: path.reversed())
    }
}
