import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

/// 반복형 Tarjan 구현을 독립적인 오라클과 대조한다.
///
/// 강결합 요소의 정의는 "서로 오갈 수 있는 정점들"이다. 작은 그래프에서는
/// 도달 가능성 폐포를 직접 계산해 그 정의를 그대로 확인할 수 있다.
/// 알고리즘을 다시 읽어 보는 것보다 이쪽이 훨씬 강한 보증이다.
@Suite("순환 탐지 속성 검증")
struct CycleDetectorPropertyTests {
    /// 도달 가능성 폐포로 강결합 요소를 구한다. 정의를 그대로 옮긴 느린 구현이다.
    private func componentsByReachability(_ graph: CodeGraph) -> [[NodeID]] {
        let nodes = graph.nodeIDs
        var reachable: [NodeID: Set<NodeID>] = [:]

        for start in nodes {
            var visited: Set<NodeID> = []
            var stack = graph.successors(of: start)
            while let current = stack.popLast() {
                guard visited.insert(current).inserted else { continue }
                stack.append(contentsOf: graph.successors(of: current))
            }
            reachable[start] = visited
        }

        var assigned: Set<NodeID> = []
        var components: [[NodeID]] = []
        for node in nodes where !assigned.contains(node) {
            let group = nodes.filter { other in
                reachable[node]?.contains(other) == true && reachable[other]?.contains(node) == true
            }
            let component = group.isEmpty ? [node] : group
            assigned.formUnion(component)

            let hasSelfLoop = reachable[node]?.contains(node) == true
            if component.count > 1 || (component.count == 1 && hasSelfLoop && graph.successors(of: node).contains(node)) {
                components.append(component.sorted())
            }
        }
        return components.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// 정점 수와 간선 확률로 무작위 방향 그래프를 만든다.
    private func randomGraph(
        nodeCount: Int,
        edgeProbability: Double,
        using generator: inout SeededRandomNumberGenerator
    ) -> CodeGraph {
        let names = (0..<nodeCount).map { "n\($0)" }
        let nodes = names.map { GraphNode(id: NodeID($0), name: $0, kind: .module, module: $0) }
        var edges: [GraphEdge] = []
        for source in names {
            for target in names where Double.random(in: 0..<1, using: &generator) < edgeProbability {
                edges.append(GraphEdge(source: NodeID(source), target: NodeID(target), kind: .reference))
            }
        }
        return CodeGraph(level: .module, nodes: nodes, edges: edges)
    }

    @Test("무작위 그래프에서 강결합 요소가 상호 도달 가능 집합과 일치한다")
    func matchesReachabilityDefinition() {
        var generator = SeededRandomNumberGenerator(seed: 20_260_902)
        let detector = CycleDetector(options: .init(includeSelfLoops: true, minimumLength: 1))

        for iteration in 0..<300 {
            let nodeCount = 2 + iteration % 7
            let probability = 0.15 + Double(iteration % 5) * 0.15
            let graph = randomGraph(
                nodeCount: nodeCount,
                edgeProbability: probability,
                using: &generator
            )
            #expect(
                detector.stronglyConnectedComponents(in: graph) == componentsByReachability(graph),
                "그래프 \(iteration): \(graph.edges.map { "\($0.source)->\($0.target)" })"
            )
        }
    }

    @Test("보고된 순환 경로는 실제로 그래프에 존재한다")
    func reportedCyclesAreRealPaths() {
        var generator = SeededRandomNumberGenerator(seed: 7)
        let detector = CycleDetector()

        for _ in 0..<200 {
            let graph = randomGraph(nodeCount: 6, edgeProbability: 0.35, using: &generator)
            for cycle in detector.detectCycles(in: graph) {
                // 경로의 모든 이웃 쌍 사이에 간선이 있어야 하고, 마지막은 처음으로 돌아와야 한다.
                for offset in cycle.path.indices {
                    let source = cycle.path[offset]
                    let target = cycle.path[(offset + 1) % cycle.path.count]
                    #expect(graph.successors(of: source).contains(target))
                }
                #expect(Set(cycle.path).count == cycle.path.count)
                #expect(Set(cycle.path).isSubset(of: Set(cycle.component)))
            }
        }
    }

    @Test("순환이 보고되지 않으면 위상 정렬이 가능하다")
    func absenceOfCyclesMeansGraphIsAcyclic() {
        var generator = SeededRandomNumberGenerator(seed: 99)
        // 기본 옵션은 자기 순환을 일부러 무시한다. "순환 없음"이 곧 "비순환"이 되려면
        // 자기 순환까지 세는 설정으로 물어봐야 한다.
        let detector = CycleDetector(options: .init(includeSelfLoops: true, minimumLength: 1))

        for _ in 0..<200 {
            let graph = randomGraph(nodeCount: 6, edgeProbability: 0.2, using: &generator)
            guard detector.detectCycles(in: graph).isEmpty else { continue }
            #expect(topologicalOrder(of: graph) != nil)
        }
    }

    /// 칸 알고리즘. 자기 순환이 없고 위상 정렬이 되면 비순환이다.
    private func topologicalOrder(of graph: CodeGraph) -> [NodeID]? {
        var remaining = Dictionary(uniqueKeysWithValues: graph.nodeIDs.map { ($0, graph.inDegree(of: $0)) })
        if graph.edges.contains(where: \.isSelfLoop) { return nil }

        var queue = remaining.filter { $0.value == 0 }.keys.sorted()
        var order: [NodeID] = []
        var head = 0

        while head < queue.count {
            let current = queue[head]
            head += 1
            order.append(current)
            for target in Set(graph.successors(of: current)) {
                remaining[target, default: 0] -= 1
                if remaining[target] == 0 { queue.append(target) }
            }
        }
        return order.count == graph.nodeCount ? order : nil
    }
}
