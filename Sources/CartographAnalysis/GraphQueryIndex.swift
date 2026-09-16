import CartographCore

/// 이름이나 USR 로 정점을 찾은 결과.
public enum GraphNodeLookup: Sendable, Equatable {
    case found(GraphNode)
    /// 같은 이름의 정점이 여럿이다. 어느 것을 뜻하는지 사용자가 골라야 한다.
    case ambiguous([GraphNode])
    case notFound
}

/// 배치 질문이 그래프 전체 정렬과 문자열 비교를 되풀이하지 않도록 만든 이름 색인.
public struct GraphQueryIndex: Sendable {
    private let graph: CodeGraph
    private let nodesByName: [String: [NodeID]]

    /// 추천 후보의 기본 개수. 후보 목록은 고르는 도구이지 읽는 도구가 아니다.
    public static let similarCandidateLimit = 5

    /// 한 그래프의 이름들을 한 번만 색인한다. 같은 정점의 동명 별칭은 중복 후보가 아니다.
    public init(graph: CodeGraph) {
        self.graph = graph
        var names: [String: [NodeID]] = [:]
        for node in graph.sortedNodes {
            for name in Set([node.name, node.baseName, node.qualifiedName]) {
                names[name, default: []].append(node.id)
            }
        }
        nodesByName = names
    }

    /// 정확한 USR 이 이름보다 우선하며, 동명 선언은 전부 후보로 돌려준다.
    public func resolve(_ subject: String) -> GraphNodeLookup {
        if let exact = graph.node(NodeID(subject)) { return .found(exact) }
        let matches = (nodesByName[subject] ?? []).compactMap { graph.node($0) }
        switch matches.count {
        case 0: return resolveQualifiedMember(subject)
        case 1: return .found(matches[0])
        default: return .ambiguous(matches)
        }
    }

    /// notFound 에 곁들일, 철자가 비슷한 이름의 대표 정점들.
    ///
    /// notFound 의 가장 흔한 원인은 오타와 낡은 인덱스다. 그때 필요한 답은 "없다"가
    /// 아니라 "이것인가?"이다. 이름 색인이 이미 들고 있는 키와의 편집 거리만 보면
    /// 그 답을 공짜로 줄 수 있다. 이름만 돌려주면 다시 물을 때 또 맞지 않으므로
    /// 정점을 돌려준다 — 부르는 쪽은 `qualifiedName` 이나 USR 로 바로 되묻는다.
    ///
    /// 거리 한도는 이름 길이에 비례한다. 고정 한도는 긴 한정 이름을 하나도 못
    /// 잡는다 — 조각 하나만 달라도 수십 자가 떨어져 있기 때문이다. 대소문자는
    /// 무시한다. 한 키에 정점이 여럿이면 첫 정점을 대표로 삼는다. 결과는 (거리,
    /// 이름) 순으로 세워 실행마다 같은 순서를 보장한다.
    public func similarCandidates(
        to subject: String,
        limit: Int = Self.similarCandidateLimit
    ) -> [GraphNode] {
        guard !subject.isEmpty else { return [] }
        let needle = subject.lowercased()
        let needleLength = needle.count
        // 매우 긴 USR은 정확 조회로만 찾는다. 추천용 편집 거리로 이차 비용을 만들지 않는다.
        guard needleLength <= 256 else { return [] }
        let threshold = max(2, needleLength / 3)
        var scored: [(distance: Int, name: String, node: GraphNode)] = []
        var seen: Set<NodeID> = []
        for (name, ids) in nodesByName {
            // 거리는 편집 횟수 이상일 수 없다. 길이 차가 한도를 넘으면 DP 를
            // 돌릴 필요도 없고, 그런 이름은 추천으로도 가치가 없다.
            guard abs(name.count - needleLength) <= threshold else { continue }
            let distance = Self.editDistance(needle, name.lowercased())
            guard distance <= threshold, let node = ids.compactMap({ graph.node($0) }).first,
                  seen.insert(node.id).inserted
            else { continue }
            scored.append((distance, name, node))
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                return lhs.name < rhs.name
            }
            .prefix(limit)
            .map(\.node)
    }

    /// 두 문자열의 편집 거리(Levenshtein). 후보 추천 전용이라 두 행 DP 로 충분하다.
    private static func editDistance(_ lhs: [Unicode.Scalar], _ rhs: [Unicode.Scalar]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let substitution = previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    /// 두 문자열의 편집 거리(Levenshtein).
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        editDistance(Array(lhs.unicodeScalars), Array(rhs.unicodeScalars))
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
    private func resolveQualifiedMember(_ subject: String) -> GraphNodeLookup {
        let parts = subject.components(separatedBy: ".")
        guard parts.count >= 2, !parts.contains(where: \.isEmpty) else { return .notFound }
        let member = parts[parts.count - 1]
        let containers = Array(parts[0..<(parts.count - 1)])

        let candidates = (nodesByName[member] ?? []).compactMap { graph.node($0) }
        let matches = candidates.filter { node in
            guard node.name == member || node.baseName == member else { return false }
            return Self.isContained(node, in: containers, of: graph)
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
