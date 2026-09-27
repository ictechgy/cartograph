import CartographCore

/// 다중 root 순회가 도달한 정점 하나.
public struct TraversalVisit: Sendable, Equatable {
    /// 도달한 정점. root 가 다른 root 에서 닿았다면 그 root 자신이다.
    public let node: NodeID
    /// 가장 가까운 root 까지의 걸음 수. root 항목은 **다른** root 기준이다.
    public let depth: Int
    /// 가장 짧은 경로 하나의 직전 정점(root 또는 다른 도달 정점). 경로의 목격이다.
    public let via: NodeID
    /// `via` 에서 이 정점으로 온 대표 근거.
    public let hop: TraversalHop
    /// 이 정점에 닿는 모든 root 의 입력 인덱스(오름차순, 자기 인덱스 제외, 상한 없음).
    public let roots: [Int]
    /// 나열된 root 각각의 최강 등급 중 가장 약한 것. root 마다 성립하는 하한이다.
    public let evidence: TraversalEvidence
}

/// 다중 root 순회 결과.
public struct TraversalResult: Sendable, Equatable {
    /// 입력 root 중 그래프에 있는 것. 입력 순서 그대로다.
    public let roots: [NodeID]
    /// (depth, 정점 UTF-16) 순으로 정렬한 도달 정점.
    public let reached: [TraversalVisit]
    /// 깊이 상한 너머에 아직 보고하지 않은 정점이 있는지.
    public let truncatedByDepth: Bool
    /// 도달 폐포(깊이 무관) 안의 dispatch 투영 중 닫힌 세계 가정만 없었다면 `bound` 였을 수.
    public let boundBlockedByOpenWorld: Int
}

/// 여러 root 에서 한 번에 순회하고 정점마다 닿은 root 를 모두 보존한다.
///
/// root 별로 BFS 를 돌리면 root 수에 비례해 느려지고 결과가 root 마다 중복된다. 여기서는
/// 폐포를 한 번 만들고, 그 위에서 (1) 서로 다른 두 가장 가까운 root 를 싣는 다중 출발 BFS로
/// depth 와 via 를, (2) 비트 집합 전파로 정점별 root 집합을 등급(direct·bound·candidate)마다
/// 계산한다. 두 번째 가까운 root 가 있어야 root 항목의 depth("다른 root 기준")를 root 마다
/// BFS 없이 낼 수 있다.
///
/// 이 타입은 파일을 읽지 않는다. 호출자가 준비한 그래프와 파생 간선 생성기만 쓴다.
public struct MultiRootTraversal: Sendable {
    let generator: TraversalHopGenerator

    /// - Parameter generator: 방향·등급 규칙을 담은 파생 간선 생성기.
    public init(generator: TraversalHopGenerator) {
        self.generator = generator
    }

    /// root 들에서 순회한다.
    ///
    /// - Parameters:
    ///   - roots: root 정점. 입력 순서가 인덱스가 된다. 중복·그래프 밖 정점은 호출자가 걸러야 한다.
    ///   - maxDepth: 보고할 최대 depth(1...128).
    /// - Returns: 정렬된 도달 정점과 깊이 잘림 여부.
    public func traverse(roots: [NodeID], maxDepth: Int) -> TraversalResult {
        let closure = TraversalClosure(roots: roots, generator: generator)
        let labels = NearestRootLabels(closure: closure, horizon: maxDepth + 1)
        let sets = RootSetPropagation(closure: closure)
        var visits: [TraversalVisit] = []
        var truncated = false
        for vertex in closure.vertices.indices {
            switch Self.visit(vertex, closure: closure, labels: labels, sets: sets, maxDepth: maxDepth) {
            case let .reported(visit): visits.append(visit)
            case .beyondDepth: truncated = true
            case .unreached: break
            }
        }
        visits.sort(by: Self.precedes)
        return TraversalResult(roots: roots, reached: visits, truncatedByDepth: truncated,
            boundBlockedByOpenWorld: closure.boundBlockedByOpenWorld)
    }

    private enum Outcome {
        case reported(TraversalVisit)
        case beyondDepth
        case unreached
    }

    /// 정점 하나의 보고 여부. root 는 다른 root 에서 닿았을 때만 싣는다.
    private static func visit(
        _ vertex: Int, closure: TraversalClosure, labels: NearestRootLabels, sets: RootSetPropagation, maxDepth: Int
    ) -> Outcome {
        let own = closure.rootIndex[vertex]
        let roots = sets.roots(of: vertex, excluding: own)
        guard !roots.isEmpty else { return .unreached }
        guard let depth = labels.distance(of: vertex, excluding: own), depth <= maxDepth,
              let parent = bestParent(of: vertex, depth: depth, closure: closure, labels: labels, excluding: own)
        else { return .beyondDepth }
        return .reported(TraversalVisit(
            node: closure.vertices[vertex], depth: depth, via: closure.vertices[parent.source], hop: parent.hop,
            roots: roots, evidence: sets.evidence(of: vertex, excluding: own)
        ))
    }

    /// 목격 부모: 이 정점보다 한 걸음 가까운 선행 정점 중 usr 가 가장 작은 것.
    ///
    /// `change-impact` 와 같은 결정 규칙이다(같은 층의 후보는 선행 정점 순). 같은 두 정점 사이
    /// 근거는 생성기가 이미 하나로 합쳤으므로 선행 정점마다 후보는 하나다. root 항목이면
    /// 자기 root 를 뺀 거리로 본다 — root 항목의 depth 가 다른 root 기준이기 때문이다.
    ///
    /// 폐포와 BFS 표지를 함께 읽으므로 둘 중 어느 쪽에도 두지 않는다(두 타입이 서로를 참조하게 된다).
    private static func bestParent(
        of vertex: Int, depth: Int, closure: TraversalClosure, labels: NearestRootLabels, excluding own: Int?
    ) -> (source: Int, hop: TraversalHop)? {
        closure.incoming[vertex].filter { parent in
            parent.source != vertex && labels.distance(of: parent.source, excluding: own) == depth - 1
        }.min { closure.vertices[$0.source] < closure.vertices[$1.source] }
    }

    /// 계약의 정렬: depth, 그다음 usr 의 UTF-16 코드 단위(locale 무관).
    static func precedes(_ lhs: TraversalVisit, _ rhs: TraversalVisit) -> Bool {
        if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
        return lhs.node.rawValue.utf16.lexicographicallyPrecedes(rhs.node.rawValue.utf16)
    }
}

// MARK: - 폐포

/// root 에서 닿는 모든 정점과 그 사이의 파생 간선을 정수 색인으로 붙잡아 둔다.
///
/// 깊이 상한과 무관하게 폐포 전체를 만든다. 정점의 root 집합은 "이 정점에 닿는 모든 root"
/// 라서 상한 밖 경로로 닿는 root 도 포함해야 하기 때문이다.
struct TraversalClosure {
    private(set) var vertices: [NodeID] = []
    private(set) var outgoing: [[(target: Int, hop: TraversalHop)]] = []
    private(set) var incoming: [[(source: Int, hop: TraversalHop)]] = []
    /// 정점 → root 인덱스. root 가 아니면 nil.
    private(set) var rootIndex: [Int?] = []
    private(set) var rootVertices: [Int] = []
    private(set) var boundBlockedByOpenWorld = 0
    private var indexOf: [NodeID: Int] = [:]

    init(roots: [NodeID], generator: TraversalHopGenerator) {
        for (position, root) in roots.enumerated() {
            let vertex = intern(root)
            rootIndex[vertex] = position
            rootVertices.append(vertex)
        }
        var head = 0
        while head < vertices.count {
            expand(head, generator: generator)
            head += 1
        }
    }

    private mutating func intern(_ node: NodeID) -> Int {
        if let existing = indexOf[node] { return existing }
        indexOf[node] = vertices.count
        vertices.append(node)
        outgoing.append([])
        incoming.append([])
        rootIndex.append(nil)
        return vertices.count - 1
    }

    private mutating func expand(_ vertex: Int, generator: TraversalHopGenerator) {
        let source = vertices[vertex]
        for hop in generator.hops(from: source) {
            let target = intern(hop.target)
            outgoing[vertex].append((target, hop))
            incoming[target].append((vertex, hop))
            if let contract = hop.dispatchContract,
               generator.isBoundBlockedByOpenWorld(contract: contract, implementation: implementation(of: hop, from: source)) {
                boundBlockedByOpenWorld += 1
            }
        }
    }

    /// dispatch 한 걸음에서 구현 쪽 정점. 역방향은 출발점, 정방향은 도착점이다.
    private func implementation(of hop: TraversalHop, from source: NodeID) -> NodeID {
        hop.relationship == "dispatchCaller" ? source : hop.target
    }
}

// MARK: - 가장 가까운 두 root

/// 정점마다 서로 다른 root 에서 온 가장 가까운 거리 두 개를 싣는 다중 출발 BFS.
///
/// 한 정점 v 에 대해 가장 가까운 root s1 과, s1 이 아닌 가장 가까운 root s2 를 함께 알면
/// "자기 root 를 뺀 가장 가까운 root" 를 모든 정점에서 답할 수 있다. s2 로 가는 최단 경로의
/// 중간 정점 u 가 s2 를 싣지 못했다면, u 는 s2 보다 가까운 서로 다른 root 둘을 싣고 있고 그중
/// 하나는 s1 이 아니므로 v 에 s2 보다 가까운 s1 아닌 root 가 있게 되어 모순이다.
struct NearestRootLabels {
    private(set) var labels: [[(distance: Int, root: Int)]]

    init(closure: TraversalClosure, horizon: Int) {
        labels = Array(repeating: [], count: closure.vertices.count)
        var frontier: [(vertex: Int, root: Int)] = []
        for vertex in closure.rootVertices {
            guard let root = closure.rootIndex[vertex] else { continue }
            labels[vertex].append((0, root))
            frontier.append((vertex, root))
        }
        var distance = 0
        while !frontier.isEmpty, distance < horizon {
            distance += 1
            frontier = advance(frontier, closure: closure, distance: distance)
        }
    }

    /// 한 층 나아간다. 같은 층의 후보는 (정점, root 인덱스) 순으로 받아 결정적이다.
    private mutating func advance(
        _ frontier: [(vertex: Int, root: Int)], closure: TraversalClosure, distance: Int
    ) -> [(vertex: Int, root: Int)] {
        var proposals: [(vertex: Int, root: Int)] = []
        for item in frontier {
            for edge in closure.outgoing[item.vertex] where accepts(edge.target, root: item.root) {
                proposals.append((edge.target, item.root))
            }
        }
        proposals.sort { $0.vertex != $1.vertex ? $0.vertex < $1.vertex : $0.root < $1.root }
        var next: [(vertex: Int, root: Int)] = []
        for proposal in proposals where accepts(proposal.vertex, root: proposal.root) {
            labels[proposal.vertex].append((distance, proposal.root))
            next.append(proposal)
        }
        return next
    }

    private func accepts(_ vertex: Int, root: Int) -> Bool {
        labels[vertex].count < 2 && !labels[vertex].contains { $0.root == root }
    }

    /// `own` 을 뺀 가장 가까운 root 까지의 거리. BFS 지평선 안에서 없으면 nil.
    func distance(of vertex: Int, excluding own: Int?) -> Int? {
        labels[vertex].first { $0.root != own }?.distance
    }
}

// MARK: - root 집합

/// 등급별로 정점에 닿는 root 집합을 비트 집합으로 전파한다.
///
/// 간선 집합이 `direct ⊂ bound ⊂ candidate` 로 포개지므로, root r 에서 정점 v 에 닿는 가장
/// 강한 등급은 "r 이 v 에 닿는 가장 좁은 간선 집합"이다. 정점 등급은 그 root 별 등급 중
/// 가장 약한 것이므로, 세 집합이 같은지만 비교하면 된다. 가능성 간선이 없으면 좁은 두 전파를
/// 건너뛴다.
struct RootSetPropagation {
    private let words: Int
    private let candidate: [UInt64]
    private let bound: [UInt64]?
    private let direct: [UInt64]?

    init(closure: TraversalClosure) {
        words = max(1, (closure.rootVertices.count + 63) / 64)
        let tiers = Set(closure.outgoing.flatMap { $0.map(\.hop.evidence) })
        candidate = Self.propagate(closure, words: words) { _ in true }
        bound = tiers.contains(.candidate) ? Self.propagate(closure, words: words) { $0 != .candidate } : nil
        direct = tiers.subtracting([.direct]).isEmpty ? nil
            : Self.propagate(closure, words: words) { $0 == .direct }
    }

    /// 자기 인덱스를 뺀 root 인덱스(오름차순).
    func roots(of vertex: Int, excluding own: Int?) -> [Int] {
        var result: [Int] = []
        for word in 0..<words {
            var bits = candidate[vertex * words + word]
            while bits != 0 {
                let index = word * 64 + bits.trailingZeroBitCount
                if index != own { result.append(index) }
                bits &= bits - 1
            }
        }
        return result
    }

    /// root 별 최강 등급 중 가장 약한 것. 좁은 집합이 넓은 집합과 같으면 그 등급이다.
    ///
    /// 좁은 전파를 건너뛴 경우(nil)는 그 등급 밖의 간선이 폐포에 없다는 뜻이라 넓은 집합과 같다.
    func evidence(of vertex: Int, excluding own: Int?) -> TraversalEvidence {
        guard let direct, !sameRoots(direct, candidate, vertex: vertex, excluding: own) else { return .direct }
        guard let bound, !sameRoots(bound, candidate, vertex: vertex, excluding: own) else { return .bound }
        return .candidate
    }

    private func sameRoots(_ lhs: [UInt64], _ rhs: [UInt64], vertex: Int, excluding own: Int?) -> Bool {
        (0..<words).allSatisfy { word in
            var mask = UInt64.max
            if let own, own / 64 == word { mask &= ~(UInt64(1) << UInt64(own % 64)) }
            return lhs[vertex * words + word] & mask == rhs[vertex * words + word] & mask
        }
    }

    /// 허용한 등급의 간선만 따라 root 비트를 고정점까지 전파한다.
    private static func propagate(
        _ closure: TraversalClosure, words: Int, allows: (TraversalEvidence) -> Bool
    ) -> [UInt64] {
        var bits = [UInt64](repeating: 0, count: closure.vertices.count * words)
        var queued = [Bool](repeating: false, count: closure.vertices.count)
        var queue: [Int] = []
        for vertex in closure.rootVertices {
            guard let root = closure.rootIndex[vertex] else { continue }
            bits[vertex * words + root / 64] |= UInt64(1) << UInt64(root % 64)
            if !queued[vertex] { queued[vertex] = true; queue.append(vertex) }
        }
        var head = 0
        while head < queue.count {
            let vertex = queue[head]
            head += 1
            queued[vertex] = false
            for edge in closure.outgoing[vertex] where allows(edge.hop.evidence) {
                guard merge(&bits, from: vertex, into: edge.target, words: words), !queued[edge.target] else { continue }
                queued[edge.target] = true
                queue.append(edge.target)
            }
        }
        return bits
    }

    /// 비트를 합치고 바뀌었는지 돌려준다.
    private static func merge(_ bits: inout [UInt64], from source: Int, into target: Int, words: Int) -> Bool {
        var changed = false
        for word in 0..<words {
            let merged = bits[target * words + word] | bits[source * words + word]
            if merged != bits[target * words + word] {
                bits[target * words + word] = merged
                changed = true
            }
        }
        return changed
    }
}
