import CartographCore

/// 발견된 순환 의존성 하나.
public struct DependencyCycle: Sendable, Equatable, Codable {
    /// 순환을 이루는 정점 경로. 첫 정점으로 돌아오는 것은 생략한다.
    ///
    /// 예: `[A, B, C]` 는 A → B → C → A 를 뜻한다.
    public let path: [NodeID]
    /// 경로를 구성하는 간선. `path` 와 같은 길이다.
    public let edges: [GraphEdge]
    /// 이 순환이 속한 강결합 요소 전체. 경로보다 클 수 있다.
    public let component: [NodeID]

    public init(path: [NodeID], edges: [GraphEdge], component: [NodeID]) {
        self.path = path
        self.edges = edges
        self.component = component
    }

    public var length: Int { path.count }

    /// 순환을 끊을 후보 간선.
    ///
    /// 가중치(참조 횟수)가 가장 낮은 간선을 고른다. 실제로 코드에서 가장 적게
    /// 쓰이는 연결이므로 제거 비용이 가장 작을 가능성이 높다. 동률이면
    /// 정렬 순서로 결정해 출력이 흔들리지 않게 한다.
    public var suggestedEdgeToBreak: GraphEdge? {
        edges.min { lhs, rhs in
            lhs.weight != rhs.weight ? lhs.weight < rhs.weight : lhs < rhs
        }
    }

    /// `A → B → C → A` 형태의 사람이 읽는 표현.
    public func description(using graph: CodeGraph) -> String {
        let names = path.map { graph.node($0)?.qualifiedName ?? $0.rawValue }
        guard let first = names.first else { return "" }
        return (names + [first]).joined(separator: " → ")
    }
}

/// 순환 의존성을 찾는다.
///
/// Tarjan 의 강결합 요소(SCC) 알고리즘을 반복문으로 구현했다.
/// 심볼 레벨 그래프는 정점이 수만 개가 되기 쉬워 재귀 구현은 스택을 넘긴다.
public struct CycleDetector: Sendable {
    public struct Options: Sendable, Equatable {
        /// 순환 판정에 사용할 간선 종류. 비어 있으면 `participatesInCycles` 인 간선을 모두 쓴다.
        public var edgeKinds: Set<EdgeKind>
        /// 자기 자신을 가리키는 간선도 순환으로 볼지 여부.
        public var includeSelfLoops: Bool
        /// 보고할 최소 순환 길이.
        ///
        /// 요소마다 대표 순환 하나만 보므로 이 필터는 대표의 길이에 걸린다. 길이 2 순환이 있는 요소의 대표는
        /// 언제나 길이 2 라서, 2 보다 크게 잡으면 그런 요소는 통째로 빠진다. 정점이 `maximumSearchStarts` 를
        /// 넘는 요소도 이제 그렇다 — 전에는 뒤쪽 길이 2 순환을 못 찾아 더 긴 대표가 남을 수 있었다.
        public var minimumLength: Int
        /// 하나의 강결합 요소에서 대표 경로를 찾을 때 시도할 시작 정점 수의 상한.
        ///
        /// 모든 정점에서 너비 우선 탐색을 돌리면 큰 요소에서 O(V·(V+E)) 가 되어
        /// 심볼 레벨 그래프에서 사실상 멈춘다. 대표 경로는 하나면 충분하므로
        /// 시도 횟수를 제한해 최악 비용을 선형에 가깝게 유지한다.
        ///
        /// 길이 2 순환(서로를 곧바로 가리키는 두 정점)은 이 상한과 무관하게 요소 전체에서 찾는다.
        /// 상한은 길이 3 이상 순환의 최단 보장만 포기한다.
        public var maximumSearchStarts: Int

        public init(
            edgeKinds: Set<EdgeKind> = [],
            includeSelfLoops: Bool = false,
            minimumLength: Int = 2,
            maximumSearchStarts: Int = 32
        ) {
            self.edgeKinds = edgeKinds
            self.includeSelfLoops = includeSelfLoops
            self.minimumLength = minimumLength
            self.maximumSearchStarts = maximumSearchStarts
        }
    }

    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// 그래프에서 순환을 찾아 길이가 짧은 순으로 돌려준다.
    public func detectCycles(in graph: CodeGraph) -> [DependencyCycle] {
        let components = stronglyConnectedComponents(in: graph)
        var cycles: [DependencyCycle] = []

        for component in components {
            if component.count == 1 {
                // 자기 순환도 다른 순환과 같은 최소 길이 규칙을 따라야 한다.
                // 예외를 두면 minimumLength 를 올려도 자기 순환만 계속 보고된다.
                guard options.includeSelfLoops,
                      options.minimumLength <= 1,
                      let node = component.first,
                      let selfEdge = edges(from: node, in: graph).first(where: { $0.target == node })
                else { continue }
                cycles.append(DependencyCycle(path: [node], edges: [selfEdge], component: component))
                continue
            }
            guard let cycle = shortestCycle(in: component, graph: graph) else { continue }
            guard cycle.length >= options.minimumLength else { continue }
            cycles.append(cycle)
        }

        return cycles.sorted { lhs, rhs in
            lhs.length != rhs.length ? lhs.length < rhs.length : lhs.path.lexicographicallyPrecedes(rhs.path)
        }
    }

    /// 크기가 2 이상이거나 자기 순환을 가진 강결합 요소를 찾는다.
    ///
    /// 반환되는 각 요소의 정점은 정렬되어 있어 출력이 결정적이다.
    public func stronglyConnectedComponents(in graph: CodeGraph) -> [[NodeID]] {
        var nextIndex = 0
        var indices: [NodeID: Int] = [:]
        var lowLinks: [NodeID: Int] = [:]
        var onStack: Set<NodeID> = []
        var stack: [NodeID] = []
        var components: [[NodeID]] = []

        /// 재귀 대신 명시적으로 관리하는 호출 프레임.
        struct Frame {
            let node: NodeID
            let successors: [NodeID]
            var nextSuccessor: Int
        }

        for root in graph.nodeIDs where indices[root] == nil {
            indices[root] = nextIndex
            lowLinks[root] = nextIndex
            nextIndex += 1
            stack.append(root)
            onStack.insert(root)

            var frames = [Frame(node: root, successors: successors(of: root, in: graph), nextSuccessor: 0)]

            while var frame = frames.popLast() {
                if frame.nextSuccessor < frame.successors.count {
                    let successor = frame.successors[frame.nextSuccessor]
                    frame.nextSuccessor += 1
                    frames.append(frame)

                    if indices[successor] == nil {
                        indices[successor] = nextIndex
                        lowLinks[successor] = nextIndex
                        nextIndex += 1
                        stack.append(successor)
                        onStack.insert(successor)
                        frames.append(
                            Frame(
                                node: successor,
                                successors: successors(of: successor, in: graph),
                                nextSuccessor: 0
                            )
                        )
                    } else if onStack.contains(successor) {
                        lowLinks[frame.node] = min(lowLinks[frame.node] ?? 0, indices[successor] ?? 0)
                    }
                    continue
                }

                // 이 정점의 모든 후속을 다 봤다. 요소의 뿌리인지 확인한다.
                let node = frame.node
                if lowLinks[node] == indices[node] {
                    var component: [NodeID] = []
                    while let popped = stack.popLast() {
                        onStack.remove(popped)
                        component.append(popped)
                        if popped == node { break }
                    }
                    if component.count > 1 || hasSelfLoop(node, in: graph) {
                        components.append(component.sorted())
                    }
                }
                if let parent = frames.last {
                    lowLinks[parent.node] = min(lowLinks[parent.node] ?? 0, lowLinks[node] ?? 0)
                }
            }
        }

        return components.sorted { $0.lexicographicallyPrecedes($1) }
    }

    // MARK: - 내부 구현

    private func edges(from node: NodeID, in graph: CodeGraph) -> [GraphEdge] {
        graph.outgoingEdges(from: node).filter { edge in
            options.edgeKinds.isEmpty ? edge.kind.participatesInCycles : options.edgeKinds.contains(edge.kind)
        }
    }

    private func successors(of node: NodeID, in graph: CodeGraph) -> [NodeID] {
        var seen: Set<NodeID> = []
        return edges(from: node, in: graph).map(\.target).filter { seen.insert($0).inserted }.sorted()
    }

    private func hasSelfLoop(_ node: NodeID, in graph: CodeGraph) -> Bool {
        edges(from: node, in: graph).contains { $0.target == node }
    }

    /// 강결합 요소 안에서 가장 짧은 순환 경로 하나를 찾는다.
    ///
    /// SCC 는 "서로 오갈 수 있는 정점 집합"일 뿐이라 그대로 보여 주면
    /// 무엇을 고쳐야 할지 알기 어렵다. 대표 경로 하나를 뽑아 보여 준다.
    ///
    /// 최단이 보장되는 것은 요소에 길이 2 순환이 있거나 요소 크기가 `maximumSearchStarts`
    /// 이하일 때다. 그보다 큰 요소에서는 식별자 순 앞쪽 시작점에서 찾은 것 중 가장 짧은
    /// 순환이며, 그 밖의 정점만 지나는 더 짧은 순환이 있을 수 있다.
    private func shortestCycle(in component: [NodeID], graph: CodeGraph) -> DependencyCycle? {
        let adjacency = ComponentAdjacency(component: component) { successors(of: $0, in: graph) }
        // 서로를 곧바로 가리키는 쌍은 여러 정점 요소에서 가능한 가장 짧은 순환이고, 간선을
        // 한 번 훑으면 요소 전체에서 찾을 수 있다. 시작점 상한 뒤쪽에만 이 쌍이 있으면 너비
        // 우선 탐색은 앞쪽의 긴 순환을 최단으로 내놓는다 — 가장 흔하고 가장 고치기 쉬운 상호
        // 의존이 긴 경로에 가려진다. 상한 이하 요소에서는 시작점을 전부 도는 탐색과 같은 쌍이다.
        if let pair = adjacency.firstMutualPair(), let cycleEdges = edges(along: pair, in: graph) {
            return DependencyCycle(path: pair, edges: cycleEdges, component: component)
        }
        var search = BreadthFirstScratch(count: component.count)
        var best: [NodeID]?

        for start in component.indices.prefix(max(1, options.maximumSearchStarts)) {
            guard let path = breadthFirstCycle(from: start, in: adjacency, scratch: &search) else { continue }
            // 정점이 둘 이상인 요소에서 길이 1 은 자기 순환이며, 요소가 설명하는
            // 진짜 순환이 아니다. 이것을 최단으로 채택하면 요소 전체가 최소 길이
            // 필터에 걸려 사라진다.
            guard path.count >= 2, best.map({ path.count < $0.count }) ?? true else { continue }
            // 경로를 간선으로 되돌리지 못하면 이 후보는 버리고 다음 시작점을 본다.
            // 여기서 요소 전체를 포기하면 실재하는 순환이 조용히 사라진다. 채택할 후보만
            // 되돌려 본다 — 시작점마다 긴 경로의 간선을 다시 거르면 탐색만큼 비싸다.
            guard edges(along: path, in: graph) != nil else { continue }
            best = path
        }

        guard let path = best, let cycleEdges = self.edges(along: path, in: graph) else { return nil }
        return DependencyCycle(path: path, edges: cycleEdges, component: component)
    }

    /// 강결합 요소 하나를 정수 색인으로 옮긴 요소 안쪽 인접 리스트.
    ///
    /// 시작점마다 너비 우선 탐색이 같은 정점의 후속을 다시 묻는다. 그때마다 간선을 거르고
    /// 정렬하고 문자열 식별자를 해시하면 시작점 수만큼 같은 할당과 해시가 반복된다.
    /// 요소에 들어올 때 한 번만 만들어 모든 시작점이 함께 쓴다.
    private struct ComponentAdjacency {
        /// 색인 → 정점. 정렬된 `component` 순서 그대로다.
        let nodes: [NodeID]
        /// 색인별 요소 안쪽 후속 색인. 요소가 정렬되어 있으므로 색인 순서가 곧 식별자 순서다.
        let successors: [[Int]]

        init(component: [NodeID], successorsOf: (NodeID) -> [NodeID]) {
            var indices: [NodeID: Int] = [:]
            indices.reserveCapacity(component.count)
            for (offset, node) in component.enumerated() {
                indices[node] = offset
            }
            nodes = component
            successors = component.map { node in successorsOf(node).compactMap { indices[$0] } }
        }

        /// 식별자 순으로 처음 나오는 상호 간선 쌍 `[source, target]`.
        ///
        /// 출발점은 상대가 있는 가장 앞선 정점, 도착점은 그 정점의 상대 중 가장 앞선 정점이다.
        /// 정렬된 시작점을 차례로 너비 우선 탐색할 때 처음 길이 2 를 내는 시작점과 그 탐색이
        /// 첫 단계에서 고르는 이웃이 정확히 이 쌍이라, 상한 이하 요소의 대표 경로가 바뀌지 않는다.
        func firstMutualPair() -> [NodeID]? {
            for source in successors.indices {
                for target in successors[source] where target != source && contains(source, in: target) {
                    return [nodes[source], nodes[target]]
                }
            }
            return nil
        }

        /// 정렬된 후속 목록을 이진 탐색한다. 간선 하나마다 상대의 목록 전체를 훑지 않는다.
        private func contains(_ node: Int, in owner: Int) -> Bool {
            let list = successors[owner]
            var low = 0
            var high = list.count
            while low < high {
                let middle = (low + high) / 2
                if list[middle] < node { low = middle + 1 } else { high = middle }
            }
            return low < list.count && list[low] == node
        }
    }

    /// 시작점마다 다시 쓰는 너비 우선 탐색 상태.
    ///
    /// 방문 표시는 시작점 색인을 도장으로 남긴다. 시작점마다 배열 전체를 지우지 않아도
    /// 이전 탐색의 표시가 이번 탐색의 방문으로 읽히지 않는다.
    private struct BreadthFirstScratch {
        var visitedBy: [Int]
        var predecessors: [Int]
        var queue: [Int] = []

        init(count: Int) {
            visitedBy = Array(repeating: -1, count: count)
            predecessors = Array(repeating: -1, count: count)
        }
    }

    /// 시작 정점으로 되돌아오는 최단 경로를 너비 우선으로 찾는다.
    ///
    /// 경로를 통째로 큐에 넣으면 배열 복사 때문에 O(V²) 가 된다.
    /// 선행 정점만 기록하고 마지막에 한 번 되짚어 O(V+E) 를 유지한다.
    private func breadthFirstCycle(
        from start: Int,
        in adjacency: ComponentAdjacency,
        scratch: inout BreadthFirstScratch
    ) -> [NodeID]? {
        scratch.visitedBy[start] = start
        scratch.queue.removeAll(keepingCapacity: true)
        scratch.queue.append(start)
        var head = 0

        while head < scratch.queue.count {
            let current = scratch.queue[head]
            head += 1
            for successor in adjacency.successors[current] {
                // 시작 정점의 자기 순환은 여기서 답이 아니다. 정점 하나짜리 요소는
                // 위쪽 분기가 따로 처리하고, 여러 정점 요소에서는 자기 순환이
                // 요소를 설명하지 못한다.
                if successor == start, current != start {
                    return reconstructPath(to: current, from: start, predecessors: scratch.predecessors)
                        .map { adjacency.nodes[$0] }
                }
                if scratch.visitedBy[successor] != start {
                    scratch.visitedBy[successor] = start
                    scratch.predecessors[successor] = current
                    scratch.queue.append(successor)
                }
            }
        }
        return nil
    }

    /// 경로의 이웃한 정점 쌍을 잇는 간선들. 하나라도 없으면 nil.
    ///
    /// 같은 방향에 여러 간선이 있으면 가중치가 큰 것을 대표로 쓴다.
    private func edges(along path: [NodeID], in graph: CodeGraph) -> [GraphEdge]? {
        var result: [GraphEdge] = []
        for offset in path.indices {
            let source = path[offset]
            let target = path[(offset + 1) % path.count]
            guard let edge = edges(from: source, in: graph)
                .filter({ $0.target == target })
                .max(by: { $0.weight < $1.weight })
            else { return nil }
            result.append(edge)
        }
        return result
    }

    /// 선행 정점 색인을 거슬러 올라가 start → ... → end 경로를 복원한다.
    ///
    /// 이번 탐색에서 방문한 정점만 거치므로 선행 정점은 모두 이번 탐색이 기록한 값이다.
    /// 그 불변식이 깨져 선행 정점이 없으면(-1) 색인 -1 로 넘어가 멈추는 대신 거기서 끊는다. 끊긴 경로는
    /// 시작점에서 출발하지 않으므로 `edges(along:)` 가 후보에서 거른다.
    private func reconstructPath(to end: Int, from start: Int, predecessors: [Int]) -> [Int] {
        var path = [end]
        var current = end
        while current != start {
            let previous = predecessors[current]
            guard previous >= 0 else { break }
            path.append(previous)
            current = previous
        }
        return path.reversed()
    }
}
