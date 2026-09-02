/// 그래프의 간선 하나.
///
/// 같은 (source, target, kind) 조합이 여러 번 나타나면 하나로 합치고
/// `weight` 로 발생 횟수를 센다. 시각화에서 굵기로, 순환 끊기에서
/// "가장 약한 고리" 후보 선정에 쓴다.
public struct GraphEdge: Hashable, Sendable, Codable {
    public let source: NodeID
    public let target: NodeID
    public let kind: EdgeKind
    public let weight: Int

    public init(source: NodeID, target: NodeID, kind: EdgeKind, weight: Int = 1) {
        self.source = source
        self.target = target
        self.kind = kind
        self.weight = weight
    }

    /// 가중치만 바꾼 복사본을 만든다.
    public func withWeight(_ weight: Int) -> GraphEdge {
        GraphEdge(source: source, target: target, kind: kind, weight: weight)
    }

    /// 자기 자신을 가리키는 간선인지 여부.
    public var isSelfLoop: Bool { source == target }
}

extension GraphEdge: Comparable {
    /// 출력 결정성을 위한 정렬 순서.
    public static func < (lhs: GraphEdge, rhs: GraphEdge) -> Bool {
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.target != rhs.target { return lhs.target < rhs.target }
        return lhs.kind < rhs.kind
    }
}
