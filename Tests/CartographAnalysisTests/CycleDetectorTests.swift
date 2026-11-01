import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("CycleDetector")
struct CycleDetectorTests {
    @Test("순환이 없으면 아무것도 보고하지 않는다")
    func acyclicGraphHasNoCycles() {
        let graph = TestGraph.make(["A": ["B"], "B": ["C"], "C": []])
        #expect(CycleDetector().detectCycles(in: graph).isEmpty)
    }

    @Test("두 정점 사이 순환을 찾는다")
    func findsTwoNodeCycle() {
        let graph = TestGraph.make(["A": ["B"], "B": ["A"]])
        let cycles = CycleDetector().detectCycles(in: graph)
        #expect(cycles.count == 1)
        #expect(cycles[0].path == [NodeID("A"), NodeID("B")])
        #expect(cycles[0].length == 2)
        #expect(cycles[0].description(using: graph) == "A → B → A")
    }

    @Test("긴 순환도 경로로 복원한다")
    func findsLongerCycle() {
        let graph = TestGraph.make(["A": ["B"], "B": ["C"], "C": ["A"]])
        let cycles = CycleDetector().detectCycles(in: graph)
        #expect(cycles.count == 1)
        #expect(cycles[0].length == 3)
        #expect(Set(cycles[0].path) == [NodeID("A"), NodeID("B"), NodeID("C")])
    }

    @Test("서로 독립적인 순환을 모두 찾는다")
    func findsMultipleIndependentCycles() {
        let graph = TestGraph.make([
            "A": ["B"], "B": ["A"],
            "X": ["Y"], "Y": ["Z"], "Z": ["X"],
        ])
        let cycles = CycleDetector().detectCycles(in: graph)
        #expect(cycles.count == 2)
        // 짧은 순환이 먼저 온다.
        #expect(cycles[0].length == 2)
        #expect(cycles[1].length == 3)
    }

    @Test("큰 강결합 요소에서는 대표 최단 경로를 보여 준다")
    func reportsShortestRepresentativePath() {
        let graph = TestGraph.make([
            "A": ["B"], "B": ["A", "C"], "C": ["D"], "D": ["A"],
        ])
        let cycles = CycleDetector().detectCycles(in: graph)
        #expect(cycles.count == 1)
        #expect(cycles[0].length == 2)
        #expect(cycles[0].component.count == 4)
    }

    /// 시작점마다 탐색 상태를 새로 만들지 않고 다시 쓴다. 앞 시작점의 방문 표시가 남으면
    /// 뒤 시작점에서 이미 본 정점을 건너뛰어, 더 짧은 순환이 있는데도 앞의 긴 순환이 남는다.
    @Test("앞 시작점의 탐색 흔적이 뒤 시작점의 더 짧은 순환을 가리지 않는다")
    func laterStartFindsShorterCycleAfterEarlierSearches() {
        let graph = TestGraph.make([
            "A": ["B"], "B": ["C"], "C": ["D"], "D": ["E"], "E": ["A", "C"],
        ])
        let cycles = CycleDetector().detectCycles(in: graph)
        #expect(cycles.count == 1)
        #expect(cycles[0].path == [NodeID("C"), NodeID("D"), NodeID("E")])
        #expect(cycles[0].component.count == 5)
    }

    /// 시작점 상한(기본 32개)보다 큰 요소에서는 앞쪽 시작점만 너비 우선으로 탐색한다.
    /// 길이 2 순환이 33번째 이후 정점에만 있으면, 앞쪽 시작점이 찾은 긴 순환이 "최단"으로 나갔다.
    @Test("시작점 상한보다 큰 요소에서도 뒤쪽의 길이 2 순환을 보고한다")
    func reportsTwoCycleBeyondSearchStarts() throws {
        let names = (0..<40).map { "n" + ($0 < 10 ? "0" : "") + "\($0)" }
        var adjacency = Dictionary(uniqueKeysWithValues: names.indices.map {
            (names[$0], [names[($0 + 1) % names.count]])
        })
        adjacency["n36", default: []].append("n35")
        let graph = TestGraph.make(adjacency)

        let cycles = CycleDetector().detectCycles(in: graph)
        let cycle = try #require(cycles.first)
        #expect(cycles.count == 1)
        #expect(cycle.component.count == 40)
        #expect(cycle.path == [NodeID("n35"), NodeID("n36")])
        #expect(cycle.edges.map(\.target) == [NodeID("n36"), NodeID("n35")])
    }

    @Test("길이 2 순환이 없는 큰 요소는 앞쪽 시작점에서 찾은 가장 짧은 순환을 낸다")
    func largeComponentWithoutTwoCycleUsesBoundedStarts() throws {
        // 41개 정점 링에 n37 → n35 를 더해 n35 → n36 → n37 → n35 삼각형을 만든다. 길이 3 순환은
        // 33번째 이후 정점에만 있으므로, 시작점 32개로는 찾지 못하고 링 전체가 대표 경로가 된다.
        // 이 테스트는 최단 보장이 길이 2 와 상한 이하 요소에만 있다는 문서의 문장을 고정한다.
        let names = (0..<41).map { "n" + ($0 < 10 ? "0" : "") + "\($0)" }
        var adjacency = Dictionary(uniqueKeysWithValues: names.indices.map {
            (names[$0], [names[($0 + 1) % names.count]])
        })
        adjacency["n37", default: []].append("n35")
        let graph = TestGraph.make(adjacency)

        let bounded = try #require(CycleDetector().detectCycles(in: graph).first)
        #expect(bounded.length == 41)
        let exhaustive = try #require(
            CycleDetector(options: .init(maximumSearchStarts: names.count)).detectCycles(in: graph).first
        )
        #expect(exhaustive.path == [NodeID("n35"), NodeID("n36"), NodeID("n37")])
    }

    @Test("자기 순환은 기본적으로 무시하고 옵션으로 켤 수 있다")
    func selfLoopsAreOptional() {
        let graph = CodeGraph(
            level: .module,
            nodes: [GraphNode(id: "A", name: "A", kind: .module)],
            edges: [GraphEdge(source: "A", target: "A", kind: .call)]
        )
        #expect(CycleDetector().detectCycles(in: graph).isEmpty)

        let detector = CycleDetector(options: .init(includeSelfLoops: true, minimumLength: 1))
        let cycles = detector.detectCycles(in: graph)
        #expect(cycles.count == 1)
        #expect(cycles[0].length == 1)
    }

    @Test("포함 관계 간선은 순환으로 세지 않는다")
    func containmentEdgesAreNotCycles() {
        let graph = CodeGraph(
            level: .symbol,
            nodes: [
                GraphNode(id: "A", name: "A", kind: .classType),
                GraphNode(id: "B", name: "B", kind: .method),
            ],
            edges: [
                GraphEdge(source: "A", target: "B", kind: .member),
                GraphEdge(source: "B", target: "A", kind: .member),
            ]
        )
        #expect(CycleDetector().detectCycles(in: graph).isEmpty)
    }

    @Test("간선 종류를 지정하면 그 종류만 따라간다")
    func edgeKindFilterIsRespected() {
        let graph = CodeGraph(
            level: .type,
            nodes: [
                GraphNode(id: "A", name: "A", kind: .classType),
                GraphNode(id: "B", name: "B", kind: .classType),
            ],
            edges: [
                GraphEdge(source: "A", target: "B", kind: .call),
                GraphEdge(source: "B", target: "A", kind: .conformance),
            ]
        )
        #expect(CycleDetector().detectCycles(in: graph).count == 1)
        #expect(CycleDetector(options: .init(edgeKinds: [.call])).detectCycles(in: graph).isEmpty)
    }

    @Test("끊을 간선으로 가장 약한 연결을 고른다")
    func suggestsWeakestEdgeToBreak() {
        let graph = CodeGraph(
            level: .module,
            nodes: [
                GraphNode(id: "A", name: "A", kind: .module),
                GraphNode(id: "B", name: "B", kind: .module),
            ],
            edges: [
                GraphEdge(source: "A", target: "B", kind: .call, weight: 42),
                GraphEdge(source: "B", target: "A", kind: .call, weight: 1),
            ]
        )
        let cycle = CycleDetector().detectCycles(in: graph).first
        #expect(cycle?.suggestedEdgeToBreak?.source == NodeID("B"))
        #expect(cycle?.suggestedEdgeToBreak?.weight == 1)
    }

    @Test("최소 길이보다 짧은 순환은 걸러 낸다")
    func minimumLengthFiltersShortCycles() {
        let graph = TestGraph.make(["A": ["B"], "B": ["A"]])
        let detector = CycleDetector(options: .init(minimumLength: 3))
        #expect(detector.detectCycles(in: graph).isEmpty)
    }

    @Test("깊은 사슬에서도 스택을 넘기지 않는다")
    func deepChainDoesNotOverflowStack() {
        var adjacency: [String: [String]] = [:]
        let depth = 20_000
        for index in 0..<depth {
            adjacency["n\(index)"] = ["n\(index + 1)"]
        }
        adjacency["n\(depth)"] = ["n0"]
        let graph = TestGraph.make(adjacency)
        let cycles = CycleDetector().detectCycles(in: graph)
        #expect(cycles.count == 1)
        #expect(cycles[0].component.count == depth + 1)
    }

    @Test("강결합 요소는 정렬되어 결정적으로 반환된다")
    func componentsAreDeterministic() {
        let graph = TestGraph.make(["C": ["A"], "A": ["B"], "B": ["C"]])
        let first = CycleDetector().stronglyConnectedComponents(in: graph)
        let second = CycleDetector().stronglyConnectedComponents(in: graph)
        #expect(first == second)
        #expect(first == [[NodeID("A"), NodeID("B"), NodeID("C")]])
    }

    @Test("빈 그래프를 안전하게 처리한다")
    func emptyGraph() {
        #expect(CycleDetector().detectCycles(in: CodeGraph(level: .module, nodes: [], edges: [])).isEmpty)
    }
}

@Suite("자기 순환이 섞인 요소")
struct CycleDetectorSelfLoopRegressionTests {
    /// 여러 정점 요소 안의 자기 순환이 진짜 순환을 덮어써 요소 전체가 사라지던 결함.
    ///
    /// 시작점을 여러 개 시도하면서, 자기 순환을 가진 정점에서 얻은 길이 1 경로가
    /// 더 짧다는 이유로 채택되고, 그 뒤 최소 길이 필터에 걸려 보고가 통째로 없어졌다.
    @Test("자기 순환이 있어도 요소의 진짜 순환을 보고한다")
    func selfLoopDoesNotHideRealCycle() {
        let graph = CodeGraph(
            level: .type,
            nodes: ["A", "B", "C"].map { GraphNode(id: NodeID($0), name: $0, kind: .classType) },
            edges: [
                GraphEdge(source: "A", target: "B", kind: .call),
                GraphEdge(source: "B", target: "C", kind: .call),
                GraphEdge(source: "C", target: "A", kind: .call),
                GraphEdge(source: "C", target: "C", kind: .call),
            ]
        )
        let cycles = CycleDetector().detectCycles(in: graph)
        #expect(cycles.count == 1)
        #expect(cycles[0].length == 3)
        #expect(Set(cycles[0].path) == [NodeID("A"), NodeID("B"), NodeID("C")])
    }

    @Test("자기 순환을 가진 정점이 사전순 첫 시작점이어도 마찬가지다")
    func selfLoopOnFirstStartNode() {
        // func a() { a(); b() }; func b() { a() } 가 정확히 이 그래프다.
        let graph = CodeGraph(
            level: .symbol,
            nodes: ["A", "B"].map { GraphNode(id: NodeID($0), name: $0, kind: .function) },
            edges: [
                GraphEdge(source: "A", target: "A", kind: .call),
                GraphEdge(source: "A", target: "B", kind: .call),
                GraphEdge(source: "B", target: "A", kind: .call),
            ]
        )
        let cycles = CycleDetector().detectCycles(in: graph)
        #expect(cycles.count == 1)
        #expect(cycles[0].path == [NodeID("A"), NodeID("B")])
    }

    @Test("정점 하나짜리 자기 순환은 여전히 옵션으로만 보고된다")
    func singleNodeSelfLoopStillOptional() {
        let graph = CodeGraph(
            level: .symbol,
            nodes: [GraphNode(id: "A", name: "A", kind: .function)],
            edges: [GraphEdge(source: "A", target: "A", kind: .call)]
        )
        #expect(CycleDetector().detectCycles(in: graph).isEmpty)
        #expect(
            CycleDetector(options: .init(includeSelfLoops: true, minimumLength: 1))
                .detectCycles(in: graph).count == 1
        )
    }
}

@Suite("자기 순환과 최소 길이")
struct SelfLoopMinimumLengthTests {
    @Test("자기 순환도 최소 길이 규칙을 따른다")
    func selfLoopRespectsMinimumLength() {
        // 예외를 두면 minimumLength 를 올려도 자기 순환만 계속 보고된다.
        let graph = CodeGraph(
            level: .symbol,
            nodes: [GraphNode(id: "A", name: "A", kind: .function)],
            edges: [GraphEdge(source: "A", target: "A", kind: .call)]
        )
        #expect(
            CycleDetector(options: .init(includeSelfLoops: true, minimumLength: 1))
                .detectCycles(in: graph).count == 1
        )
        #expect(
            CycleDetector(options: .init(includeSelfLoops: true, minimumLength: 2))
                .detectCycles(in: graph).isEmpty
        )
    }
}
