import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("다중 root 순회")
struct MultiRootTraversalTests {
    // MARK: - 계약 예시

    @Test("다른 root 에서 닿은 root 는 자기 인덱스 없이 싣고, via 가 root 면 depth 1 이다")
    func listsRootReachedFromAnotherRoot() throws {
        // 계약 예: root A(0)·B(1), B 는 A 의 의존자, C 는 B 의 의존자.
        let graph = makeGraph(["A", "B", "C"], [edge("B", "A", .call), edge("C", "B", .call)])
        let result = traverse(graph, roots: ["A", "B"])
        #expect(result.reached.map(\.node) == ["B", "C"])
        let rootB = try #require(result.reached.first { $0.node == "B" })
        #expect((rootB.via, rootB.depth, rootB.roots) == ("A", 1, [0]))
        let caller = try #require(result.reached.first { $0.node == "C" })
        #expect((caller.via, caller.depth, caller.roots) == ("B", 1, [0, 1]))
    }

    @Test("root 항목의 depth 는 다른 root 기준이고 via 는 그 root 를 거쳐 돌아올 수 있는 목격이다")
    func rootEntryDepthUsesOtherRoots() throws {
        // 계약 예: root A(0)·R(1), 순회 간선 A→W→V→R 과 R→V (역방향이라 그래프 간선은 반대).
        let graph = makeGraph(["A", "W", "V", "R"], [
            edge("W", "A", .call), edge("V", "W", .call), edge("R", "V", .call), edge("V", "R", .call),
        ])
        let result = traverse(graph, roots: ["A", "R"])
        let middle = try #require(result.reached.first { $0.node == "V" })
        #expect((middle.via, middle.depth, middle.roots) == ("R", 1, [0, 1]))
        let rootR = try #require(result.reached.first { $0.node == "R" })
        #expect((rootR.via, rootR.depth, rootR.roots) == ("V", 3, [0]))
    }

    @Test("자기 자신에서만 닿는 순환 root 는 싣지 않는다")
    func omitsRootReachedOnlyFromItself() {
        let graph = makeGraph(["A", "B"], [edge("A", "B", .call), edge("B", "A", .call)])
        let result = traverse(graph, roots: ["A"])
        #expect(result.reached.map(\.node) == ["B"])
    }

    // MARK: - 근거 등급

    @Test("dispatch 투영은 기본이 candidate 이고 root 마다 성립하는 하한을 싣는다")
    func evidenceIsPerRootLowerBound() throws {
        // Direct 는 Caller 를 직접 부르고, Impl 은 계약 호출로만 Caller 에 닿는다.
        let graph = CodeGraph(level: .symbol, nodes: [
            GraphNode(id: "P", name: "P", kind: .protocolType),
            GraphNode(id: "P.f", name: "f()", kind: .method),
            GraphNode(id: "Impl.f", name: "f()", kind: .method),
            GraphNode(id: "Direct", name: "Direct", kind: .function),
            GraphNode(id: "Caller", name: "Caller", kind: .function),
        ], edges: [
            edge("P", "P.f", .member), edge("Impl.f", "P.f", .overrides),
            edge("Caller", "P.f", .call), edge("Caller", "Direct", .call),
        ])
        let alone = traverse(graph, roots: ["Direct"])
        #expect(alone.reached.first?.evidence == .direct)
        let both = traverse(graph, roots: ["Direct", "Impl.f"])
        let caller = try #require(both.reached.first { $0.node == "Caller" })
        #expect(caller.roots == [0, 1])
        #expect(caller.evidence == .candidate)
        #expect(caller.hop.relationship == "dependent")
    }

    @Test("구현이 하나뿐인 프로토콜 요구사항은 닫힌 세계에서만 bound 로 올린다")
    func boundRequiresClosedWorldAndUniqueImplementation() throws {
        let graph = protocolGraph(extraConformer: false)
        let closed = traverse(graph, roots: ["Live.f"], closedWorld: true)
        #expect(closed.reached.first?.evidence == .bound)
        #expect(closed.boundBlockedByOpenWorld == 0)
        let open = traverse(graph, roots: ["Live.f"], closedWorld: false)
        #expect(open.reached.first?.evidence == .candidate)
        #expect(open.boundBlockedByOpenWorld == 1)
        let shared = traverse(protocolGraph(extraConformer: true), roots: ["Live.f"], closedWorld: true)
        #expect(shared.reached.first?.evidence == .candidate)
    }

    @Test("정방향은 호출자에서 계약을 건너뛰어 구현으로 가고 형제 구현의 호출자로 번지지 않는다")
    func forwardProjectsCallerToImplementations() {
        let graph = CodeGraph(level: .symbol, nodes: [
            GraphNode(id: "P", name: "P", kind: .protocolType),
            GraphNode(id: "P.f", name: "f()", kind: .method),
            GraphNode(id: "A.f", name: "f()", kind: .method),
            GraphNode(id: "B.f", name: "f()", kind: .method),
            GraphNode(id: "Caller", name: "Caller", kind: .function),
        ], edges: [
            edge("P", "P.f", .member), edge("P", "P.f", .call),
            edge("A.f", "P.f", .overrides), edge("B.f", "P.f", .overrides), edge("Caller", "P.f", .call),
        ])
        let forward = traverse(graph, roots: ["Caller"], direction: .dependencies)
        #expect(forward.reached.map(\.node) == ["A.f", "B.f", "P.f"])
        #expect(forward.reached.first { $0.node == "A.f" }?.hop.relationship == "dispatchTarget")
        #expect(forward.reached.first { $0.node == "P.f" }?.evidence == .direct)
        #expect(forward.reached.first { $0.node == "A.f" }?.evidence == .candidate)
    }

    @Test("깊이 상한 너머 정점이 있으면 잘림을 표시하고 없으면 표시하지 않는다")
    func marksDepthTruncation() {
        let graph = makeGraph(["A", "B", "C"], [edge("B", "A", .call), edge("C", "B", .call)])
        #expect(traverse(graph, roots: ["A"], maxDepth: 1).truncatedByDepth)
        #expect(traverse(graph, roots: ["A"], maxDepth: 1).reached.map(\.node) == ["B"])
        #expect(!traverse(graph, roots: ["A"], maxDepth: 2).truncatedByDepth)
    }

    // MARK: - 오라클

    @Test("무작위 그래프에서 한 번의 순회가 root 별 BFS 전수 계산과 모든 필드에서 같다", arguments: 0..<60)
    func matchesPerRootBruteForce(seed: Int) {
        var random = SeededRandomNumberGenerator(seed: UInt64(seed) &* 7919 &+ 17)
        let (graph, runtime) = RandomTraversalGraph.make(using: &random)
        let direction: TraversalDirection = seed.isMultiple(of: 2) ? .dependents : .dependencies
        let generator = TraversalHopGenerator(graph: graph, direction: direction,
            closedWorld: seed % 3 != 0, runtimeDependencies: runtime)
        let roots = Array(graph.nodeIDs.shuffled(using: &random).prefix(Int.random(in: 1...6, using: &random)))
        let maxDepth = [1, 2, 3, 128][seed % 4]
        let actual = MultiRootTraversal(generator: generator).traverse(roots: roots, maxDepth: maxDepth)
        let expected = BruteForceTraversal(generator: generator, nodes: graph.nodeIDs, roots: roots, maxDepth: maxDepth)
        #expect(actual.truncatedByDepth == expected.truncated)
        // 출력 한도는 (depth, usr) 앞부분만 남긴다. via 가 항상 root 거나 더 얕은 행이어야 잘라도 부모가 남는다.
        let depthByNode = Dictionary(uniqueKeysWithValues: actual.reached.map { ($0.node, $0.depth) })
        #expect(actual.reached.allSatisfy { visit in
            roots.contains(visit.via) || (depthByNode[visit.via].map { $0 < visit.depth } ?? false)
        })
        #expect(actual.reached.count == expected.rows.count)
        for (lhs, rhs) in zip(actual.reached, expected.rows) {
            #expect(lhs.node == rhs.node)
            #expect(lhs.depth == rhs.depth, "depth of \(lhs.node)")
            #expect(lhs.via == rhs.via, "via of \(lhs.node)")
            #expect(lhs.roots == rhs.roots, "roots of \(lhs.node)")
            #expect(lhs.evidence == rhs.evidence, "evidence of \(lhs.node)")
            #expect(lhs.hop == rhs.hop, "hop of \(lhs.node)")
        }
    }

    @Test("역방향 순회의 root 별 도달 집합은 ImpactAnalyzer 의 root 별 영향 집합과 같다", arguments: 0..<40)
    func dependentsMatchImpactAnalyzerPerRoot(seed: Int) {
        var random = SeededRandomNumberGenerator(seed: UInt64(seed) &* 104_729 &+ 3)
        let (graph, runtime) = RandomTraversalGraph.make(using: &random)
        let generator = TraversalHopGenerator(graph: graph, direction: .dependents, closedWorld: true,
            runtimeDependencies: runtime)
        let roots = Array(graph.nodeIDs.shuffled(using: &random).prefix(5))
        let result = MultiRootTraversal(generator: generator).traverse(roots: roots, maxDepth: 128)
        for (index, root) in roots.enumerated() {
            let perRoot = ImpactAnalyzer().analyze(changing: [root], in: graph, additionalDependencies: runtime)
            let attributed = result.reached.filter { $0.roots.contains(index) }.map(\.node)
            #expect(Set(attributed) == Set(perRoot.affected.map(\.node)), "root \(root)")
        }
    }

    @Test("정방향 도달은 역방향 도달의 정확한 역관계다", arguments: 0..<20)
    func forwardIsInverseOfReverse(seed: Int) {
        var random = SeededRandomNumberGenerator(seed: UInt64(seed) &+ 99)
        let (graph, runtime) = RandomTraversalGraph.make(using: &random)
        let nodes = graph.nodeIDs
        let reach = { (direction: TraversalDirection) -> [NodeID: Set<NodeID>] in
            let generator = TraversalHopGenerator(graph: graph, direction: direction, closedWorld: true,
                runtimeDependencies: runtime)
            let result = MultiRootTraversal(generator: generator).traverse(roots: nodes, maxDepth: 128)
            var sets: [NodeID: Set<NodeID>] = [:]
            for visit in result.reached {
                for index in visit.roots { sets[nodes[index], default: []].insert(visit.node) }
            }
            return sets
        }
        let forward = reach(.dependencies)
        let reverse = reach(.dependents)
        for source in nodes {
            for target in nodes where source != target {
                #expect((forward[source]?.contains(target) == true) == (reverse[target]?.contains(source) == true))
            }
        }
    }

    @Test("같은 입력은 같은 결과를 낸다")
    func isDeterministic() {
        var random = SeededRandomNumberGenerator(seed: 4242)
        let (graph, runtime) = RandomTraversalGraph.make(using: &random)
        let generator = TraversalHopGenerator(graph: graph, direction: .dependents, closedWorld: true,
            runtimeDependencies: runtime)
        let roots = Array(graph.nodeIDs.prefix(4))
        let first = MultiRootTraversal(generator: generator).traverse(roots: roots, maxDepth: 128)
        let second = MultiRootTraversal(generator: generator).traverse(roots: roots, maxDepth: 128)
        #expect(first == second)
    }

    // MARK: - 도우미

    private func traverse(
        _ graph: CodeGraph, roots: [NodeID], direction: TraversalDirection = .dependents,
        closedWorld: Bool = true, maxDepth: Int = 128
    ) -> TraversalResult {
        let generator = TraversalHopGenerator(graph: graph, direction: direction, closedWorld: closedWorld)
        return MultiRootTraversal(generator: generator).traverse(roots: roots, maxDepth: maxDepth)
    }

    private func protocolGraph(extraConformer: Bool) -> CodeGraph {
        var nodes = [
            GraphNode(id: "P", name: "P", kind: .protocolType),
            GraphNode(id: "P.f", name: "f()", kind: .method),
            GraphNode(id: "Live", name: "Live", kind: .structType),
            GraphNode(id: "Live.f", name: "f()", kind: .method),
            GraphNode(id: "Caller", name: "Caller", kind: .function),
        ]
        var edges = [
            edge("P", "P.f", .member), edge("Live", "Live.f", .member), edge("Live", "P", .conformance),
            edge("Live.f", "P.f", .overrides), edge("Caller", "P.f", .call),
        ]
        if extraConformer {
            nodes.append(GraphNode(id: "Mock", name: "Mock", kind: .structType))
            edges.append(edge("Mock", "P", .conformance))
        }
        return CodeGraph(level: .symbol, nodes: nodes, edges: edges)
    }

    private func makeGraph(_ names: [String], _ edges: [GraphEdge]) -> CodeGraph {
        CodeGraph(level: .symbol, nodes: names.map { GraphNode(id: NodeID($0), name: $0, kind: .function) },
            edges: edges)
    }
}

private func edge(_ source: String, _ target: String, _ kind: EdgeKind) -> GraphEdge {
    GraphEdge(source: NodeID(source), target: NodeID(target), kind: kind)
}

/// 프로토콜·오버라이드 사슬·런타임 연결이 섞인 작은 무작위 그래프.
private enum RandomTraversalGraph {
    static func make(using random: inout SeededRandomNumberGenerator) -> (CodeGraph, [ImpactDependency]) {
        var nodes = (0..<10).map { GraphNode(id: NodeID("F\($0)"), name: "F\($0)", kind: .function) }
        var edges: [GraphEdge] = []
        for protocolIndex in 0..<2 {
            let owner = "P\(protocolIndex)"
            nodes.append(GraphNode(id: NodeID(owner), name: owner, kind: .protocolType))
            for requirement in 0..<2 {
                let id = "\(owner).r\(requirement)"
                nodes.append(GraphNode(id: NodeID(id), name: id, kind: .method))
                edges.append(edge(owner, id, .member))
                if Bool.random(using: &random) { edges.append(edge(owner, id, .call)) }
            }
        }
        for typeIndex in 0..<3 {
            let owner = "T\(typeIndex)"
            nodes.append(GraphNode(id: NodeID(owner), name: owner, kind: .structType))
            for method in 0..<2 {
                let id = "\(owner).m\(method)"
                nodes.append(GraphNode(id: NodeID(id), name: id, kind: .method))
                edges.append(edge(owner, id, .member))
            }
        }
        edges += randomEdges(nodes: nodes, using: &random)
        let ids = nodes.map(\.id)
        let runtime = (0..<Int.random(in: 0...3, using: &random)).map { number in
            ImpactDependency(source: ids.randomElement(using: &random)!, target: ids.randomElement(using: &random)!,
                contract: "c\(number)", origin: .automatic)
        }
        return (CodeGraph(level: .symbol, nodes: nodes, edges: edges), runtime)
    }

    private static func randomEdges(nodes: [GraphNode], using random: inout SeededRandomNumberGenerator) -> [GraphEdge] {
        let callables = nodes.filter { $0.kind != .protocolType && $0.kind != .structType }.map(\.id.rawValue)
        let methods = callables.filter { $0.contains(".") }
        var edges: [GraphEdge] = []
        for _ in 0..<Int.random(in: 12...30, using: &random) {
            let kind: EdgeKind = Bool.random(using: &random) ? .call : .reference
            edges.append(edge(callables.randomElement(using: &random)!, callables.randomElement(using: &random)!, kind))
        }
        for _ in 0..<Int.random(in: 2...6, using: &random) {
            edges.append(edge(methods.randomElement(using: &random)!, methods.randomElement(using: &random)!, .overrides))
        }
        for _ in 0..<Int.random(in: 1...4, using: &random) {
            edges.append(edge("T\(Int.random(in: 0..<3, using: &random))", "P\(Int.random(in: 0..<2, using: &random))",
                .conformance))
        }
        return edges
    }
}

/// root 마다 따로 BFS 를 돌려 계약의 정의를 그대로 계산하는 느린 오라클.
private struct BruteForceTraversal {
    struct Row {
        let node: NodeID
        let depth: Int
        let via: NodeID
        let roots: [Int]
        let evidence: TraversalEvidence
        let hop: TraversalHop
    }

    private(set) var rows: [Row] = []
    private(set) var truncated = false

    init(generator: TraversalHopGenerator, nodes: [NodeID], roots: [NodeID], maxDepth: Int) {
        let distances = roots.map { Self.distances(from: $0, generator: generator) { _ in true } }
        let reach = Dictionary(uniqueKeysWithValues: TraversalEvidence.allCases.map { tier in
            (tier, roots.map { Set(Self.distances(from: $0, generator: generator) { $0 <= tier }.keys) })
        })
        let rootIndex = Dictionary(uniqueKeysWithValues: roots.enumerated().map { ($1, $0) })
        for node in nodes {
            let own = rootIndex[node]
            let listed = roots.indices.filter { $0 != own && distances[$0][node] != nil }
            guard !listed.isEmpty else { continue }
            // 자기 root 를 뺀 가장 가까운 root 까지의 거리. root 항목의 depth 정의다.
            let nearest = { (vertex: NodeID) in
                roots.indices.filter { $0 != own }.compactMap { distances[$0][vertex] }.min()
            }
            let depth = nearest(node)!
            guard depth <= maxDepth else { truncated = true; continue }
            let parents = nodes.filter { parent in
                parent != node && nearest(parent) == depth - 1
                    && generator.hops(from: parent).contains { $0.target == node }
            }.sorted()
            let via = parents.first!
            let tiers = listed.map { index in
                TraversalEvidence.allCases.first { reach[$0]![index].contains(node) }!
            }
            rows.append(Row(node: node, depth: depth, via: via, roots: listed, evidence: tiers.max()!,
                hop: generator.hops(from: via).first { $0.target == node }!))
        }
        rows.sort { $0.depth != $1.depth ? $0.depth < $1.depth : $0.node.rawValue < $1.node.rawValue }
    }

    private static func distances(
        from root: NodeID, generator: TraversalHopGenerator, allows: (TraversalEvidence) -> Bool
    ) -> [NodeID: Int] {
        var result: [NodeID: Int] = [root: 0]
        var queue = [root]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for hop in generator.hops(from: current) where allows(hop.evidence) && result[hop.target] == nil {
                result[hop.target] = result[current]! + 1
                queue.append(hop.target)
            }
        }
        return result
    }
}
