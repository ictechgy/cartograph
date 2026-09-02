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
        public var minimumLength: Int
        /// 하나의 강결합 요소에서 대표 경로를 찾을 때 시도할 시작 정점 수의 상한.
        ///
        /// 모든 정점에서 너비 우선 탐색을 돌리면 큰 요소에서 O(V·(V+E)) 가 되어
        /// 심볼 레벨 그래프에서 사실상 멈춘다. 대표 경로는 하나면 충분하므로
        /// 시도 횟수를 제한해 최악 비용을 선형에 가깝게 유지한다.
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
    private func shortestCycle(in component: [NodeID], graph: CodeGraph) -> DependencyCycle? {
        let members = Set(component)
        var best: [NodeID]?

        for start in component.prefix(max(1, options.maximumSearchStarts)) {
            guard let path = breadthFirstCycle(from: start, within: members, graph: graph) else { continue }
            // 정점이 둘 이상인 요소에서 길이 1 은 자기 순환이며, 요소가 설명하는
            // 진짜 순환이 아니다. 이것을 최단으로 채택하면 요소 전체가 최소 길이
            // 필터에 걸려 사라진다.
            guard path.count >= 2 else { continue }
            if best == nil || path.count < best.unsafelyUnwrapped.count {
                best = path
            }
            // 길이 2 는 이 알고리즘이 찾을 수 있는 최소이므로 더 볼 필요가 없다.
            if best?.count == 2 { break }
        }

        guard let path = best else { return nil }
        var cycleEdges: [GraphEdge] = []
        for offset in path.indices {
            let source = path[offset]
            let target = path[(offset + 1) % path.count]
            guard let edge = edges(from: source, in: graph)
                .filter({ $0.target == target })
                .max(by: { $0.weight < $1.weight })
            else { return nil }
            cycleEdges.append(edge)
        }
        return DependencyCycle(path: path, edges: cycleEdges, component: component)
    }

    /// 시작 정점으로 되돌아오는 최단 경로를 너비 우선으로 찾는다.
    ///
    /// 경로를 통째로 큐에 넣으면 배열 복사 때문에 O(V²) 가 된다.
    /// 선행 정점만 기록하고 마지막에 한 번 되짚어 O(V+E) 를 유지한다.
    private func breadthFirstCycle(
        from start: NodeID,
        within members: Set<NodeID>,
        graph: CodeGraph
    ) -> [NodeID]? {
        var predecessors: [NodeID: NodeID] = [:]
        var visited: Set<NodeID> = [start]
        var queue: [NodeID] = [start]
        var head = 0

        while head < queue.count {
            let current = queue[head]
            head += 1
            for successor in successors(of: current, in: graph) where members.contains(successor) {
                // 시작 정점의 자기 순환은 여기서 답이 아니다. 정점 하나짜리 요소는
                // 위쪽 분기가 따로 처리하고, 여러 정점 요소에서는 자기 순환이
                // 요소를 설명하지 못한다.
                if successor == start, current != start {
                    return reconstructPath(to: current, from: start, predecessors: predecessors)
                }
                if visited.insert(successor).inserted {
                    predecessors[successor] = current
                    queue.append(successor)
                }
            }
        }
        return nil
    }

    /// 선행 정점 사전을 거슬러 올라가 start → ... → end 경로를 복원한다.
    private func reconstructPath(
        to end: NodeID,
        from start: NodeID,
        predecessors: [NodeID: NodeID]
    ) -> [NodeID] {
        var path: [NodeID] = [end]
        var current = end
        while current != start, let previous = predecessors[current] {
            path.append(previous)
            current = previous
        }
        return path.reversed()
    }
}
