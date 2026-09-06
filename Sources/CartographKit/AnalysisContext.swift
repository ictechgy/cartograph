import CartographAnalysis
import CartographCore

/// 한 번 읽은 인덱스 스냅샷과, 그 위에서 만든 그래프들.
///
/// 인덱스를 읽는 것이 파이프라인에서 가장 느린 단계다. 명령마다 다시 읽으면
/// `baseline` 처럼 여러 분석을 묶어 돌리는 경로에서 그 비용을 그대로 반복한다.
/// 같은 스냅샷에서 필요한 해상도의 그래프를 그때그때 만들어 쓴다.
public struct AnalysisContext: Sendable {
    public let snapshot: IndexSnapshot
    private let pathFilter: PathFilter
    private let edgeKinds: Set<EdgeKind>
    /// `--external-retentions` 로 읽은 문서. 스냅샷과 함께 한 번만 읽는다.
    ///
    /// 파일 읽기는 실패할 수 있어 던지는 자리(`loadContext`)에서 해야 한다. 질의 API 는
    /// 던지지 않으므로 여기 실어 두면 질의가 그대로 순수하게 남는다.
    public let externalRetentions: ExternalRetentionsDocument?
    /// 보존 규칙이 쓰는 색인. 문서가 없으면 비어 있다. 접근할 때마다 다시 만들지 않는다.
    public let externalRetentionIndex: ExternalRetentionIndex

    public init(
        snapshot: IndexSnapshot,
        pathFilter: PathFilter = .passthrough,
        edgeKinds: Set<EdgeKind> = [],
        externalRetentions: ExternalRetentionsDocument? = nil
    ) {
        self.snapshot = snapshot
        self.pathFilter = pathFilter
        self.edgeKinds = edgeKinds
        self.externalRetentions = externalRetentions
        externalRetentionIndex = externalRetentions.map { ExternalRetentionIndex($0.retentions) } ?? .empty
    }

    /// 지정한 해상도의 그래프를 만든다.
    public func buildGraph(level: GraphLevel, includeExternal: Bool = false) -> GraphBuilder.BuildResult {
        GraphBuilder(
            options: .init(
                level: level,
                pathFilter: pathFilter,
                edgeKinds: edgeKinds,
                includeExternal: includeExternal
            )
        )
        .buildResult(from: snapshot)
    }
}

/// 이름이나 USR 로 정점을 찾은 결과.
public enum NodeLookup: Sendable, Equatable {
    case found(GraphNode)
    /// 같은 이름의 정점이 여럿이다. 어느 것을 뜻하는지 사용자가 골라야 한다.
    case ambiguous([GraphNode])
    case notFound

    /// 후보 중 하나를 고르지 않고 임의로 정하면 사용자는 자기가 물어본 것과 다른
    /// 답을 받고도 알아채지 못한다.
    static func resolve(_ subject: String, in graph: CodeGraph) -> NodeLookup {
        if let exact = graph.node(NodeID(subject)) { return .found(exact) }
        let matches = graph.sortedNodes.filter {
            $0.name == subject || $0.baseName == subject || $0.qualifiedName == subject
        }
        switch matches.count {
        case 0: return resolveQualifiedMember(subject, in: graph)
        case 1: return .found(matches[0])
        default: return .ambiguous(matches)
        }
    }

    /// `Type.member` · `Outer.Inner.member` · `Module.Type.member` 표기를 받는다.
    ///
    /// 모호한 이름의 후보 목록은 소유 타입을 보여 주는데, 정작 그 표기로 되물으면
    /// `notFound` 가 나왔다. 사용자가 답에서 읽은 이름으로 다시 물을 수 없다는 뜻이고,
    /// 남는 길은 USR 을 통째로 복사하는 것뿐이었다.
    ///
    /// 마지막 조각이 멤버이고 앞의 것들은 그것을 감싸는 이름이다. 소유 사슬을 안에서
    /// 바깥으로 훑으며 요구된 이름들을 순서대로 지운다. **중간을 건너뛰어도 맞는 것으로
    /// 본다** — `CodeGraph.source` 처럼 바깥 타입만 아는 채로 묻는 것이 자연스럽고,
    /// 너무 많이 걸리면 하나를 고르는 대신 모호하다고 답하기 때문이다.
    /// 가장 바깥 하나는 모듈 이름으로도 맞춘다.
    ///
    /// 익스텐션에 달린 멤버는 `semanticParent` 가 확장 대상 타입으로 접어 주므로
    /// 선언을 어디에 썼든 같은 이름으로 찾는다.
    ///
    /// 평범한 조회가 **아무것도** 찾지 못했을 때만 돈다. `Detail.body` 라는 이름의
    /// 최상위 선언이 실제로 있다면 그쪽이 이긴다. 있는 것을 못 찾게 만들지 않는다.
    private static func resolveQualifiedMember(_ subject: String, in graph: CodeGraph) -> NodeLookup {
        let parts = subject.components(separatedBy: ".")
        guard parts.count >= 2, !parts.contains(where: \.isEmpty) else { return .notFound }
        let member = parts[parts.count - 1]
        let containers = Array(parts[0..<(parts.count - 1)])

        let matches = graph.sortedNodes.filter { node in
            guard node.name == member || node.baseName == member else { return false }
            return isContained(node, in: containers, of: graph)
        }
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0])
        default: return .ambiguous(matches)
        }
    }

    /// 정점의 소유 사슬이 요구된 이름들을 바깥 순서대로 담고 있는지.
    private static func isContained(
        _ node: GraphNode, in containers: [String], of graph: CodeGraph
    ) -> Bool {
        // 안쪽부터 지운다. 요구된 이름은 바깥이 앞이므로 뒤에서부터 본다.
        var remaining = containers.count - 1
        var current = node
        // 부모 관계가 순환할 수 있다. 그래프가 만들어 준 것을 믿지 않는다.
        var visited: Set<NodeID> = [node.id]
        while remaining >= 0,
              let parentID = graph.semanticParent(of: current.id),
              visited.insert(parentID).inserted,
              let parent = graph.node(parentID) {
            let wanted = containers[remaining]
            if parent.name == wanted || parent.baseName == wanted { remaining -= 1 }
            current = parent
        }
        // 남은 하나는 모듈일 수 있다. `Module.Type.member` 로 물을 수 있어야 한다.
        if remaining == 0, node.module == containers[0] { remaining -= 1 }
        return remaining < 0
    }
}
