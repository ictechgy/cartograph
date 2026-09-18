import CartographAnalysis
import CartographCore
import CartographTestSupport
import Foundation
import Testing

@Suite("영향 선택 컨테이너 확장")
struct ImpactSelectionExpansionTests {
    @Test("타입 시드는 중첩 타입과 멤버까지 확장하지만 소비자의 형제는 닿지 않는다")
    func expandsNestedContainersWithoutConsumerSiblings() {
        var builder = SnapshotBuilder()
        builder.symbol("Outer", kind: .classType)
        builder.symbol("Inner", kind: .structType, parent: "Outer")
        builder.symbol("Leaf", kind: .method, parent: "Inner")
        builder.symbol("Consumer", kind: .function)
        builder.symbol("Sibling", kind: .method, parent: "Consumer")
        builder.reference(from: "Consumer", to: "Outer", kind: .call)
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: builder.build())

        let expanded = ImpactSelectionExpansion.expandingContainers(["Outer"], graph: graph)

        #expect(expanded == ["Outer", "Inner", "Leaf"])
    }

    @Test("타입 시드는 그 타입을 확장하는 익스텐션과 그 멤버까지 닿는다")
    func reachesExtensionMembersFromTypeSeed() {
        let t = GraphNode(id: "T", name: "T", kind: .structType)
        let e = GraphNode(id: "E", name: "E", kind: .extensionDeclaration)
        let m = GraphNode(id: "M", name: "M", kind: .method)
        let graph = CodeGraph(level: .symbol, nodes: [t, e, m], edges: [
            GraphEdge(source: "E", target: "T", kind: .extends),
            GraphEdge(source: "E", target: "M", kind: .member),
        ])

        let expanded = ImpactSelectionExpansion.expandingContainers(["T"], graph: graph)

        #expect(expanded == ["T", "E", "M"])
    }

    @Test("익스텐션 시드는 자기 멤버만 확장하고 확장 대상 타입은 포함하지 않는다")
    func extensionSeedKeepsExtendedTypeOut() {
        let t = GraphNode(id: "T", name: "T", kind: .structType)
        let e = GraphNode(id: "E", name: "E", kind: .extensionDeclaration)
        let m = GraphNode(id: "M", name: "M", kind: .method)
        let graph = CodeGraph(level: .symbol, nodes: [t, e, m], edges: [
            GraphEdge(source: "E", target: "T", kind: .extends),
            GraphEdge(source: "E", target: "M", kind: .member),
        ])

        let expanded = ImpactSelectionExpansion.expandingContainers(["E"], graph: graph)

        #expect(expanded == ["E", "M"])
    }

    @Test("익스텐션이 서로를 확장하는 순환에서도 종료하고 시드를 잃지 않는다")
    func terminatesOnCyclicContainerEdges() {
        // extends 는 source 가 익스텐션일 때만 자식으로 읽히므로, 진짜 순환을
        // 만들려면 두 정점이 모두 익스텐션이어야 한다.
        var builder = SnapshotBuilder()
        builder.symbol("A", kind: .extensionDeclaration)
        builder.symbol("B", kind: .extensionDeclaration)
        builder.symbol("a", kind: .method, parent: "A")
        builder.symbol("b", kind: .method, parent: "B")
        builder.reference(from: "B", to: "A", kind: .extends)
        builder.reference(from: "A", to: "B", kind: .extends)
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: builder.build())

        // 시드를 하나만 두어 순환을 따라가는 탐색 자체를 검증한다 — 둘을 넣으면
        // 확장이 깨져도 시드 보존만으로 통과해 순회를 검사하지 못한다.
        let expanded = ImpactSelectionExpansion.expandingContainers(["A"], graph: graph)

        #expect(expanded == ["A", "B", "a", "b"])
    }

    @Test("컨테이너가 아닌 시드 멤버는 자기 자식을 확장하지 않는다 — 옮기기 전 구현의 기존 계약")
    func nonContainerSeedMemberDoesNotExpandItsChildren() {
        // 큐에는 컨테이너 시드만 들어간다. 타입과 그 멤버를 함께 골라도 멤버는
        // 결과에 남기만 하고 자기 자식(지역 선언)을 확장하지는 않는다. 옮기기 전
        // 구현도 같은 동작이므로, 바꾸려면 이 계약을 의식해서 바꿔야 한다.
        var builder = SnapshotBuilder()
        builder.symbol("T", kind: .classType)
        builder.symbol("m", kind: .method, parent: "T")
        builder.symbol("local", kind: .function, parent: "m")
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: builder.build())

        let expanded = ImpactSelectionExpansion.expandingContainers(["T", "m"], graph: graph)

        #expect(expanded == ["T", "m"])
    }

    @Test("도달한 멤버 아래의 지역 선언과 그 안의 중첩 컨테이너까지 확장한다")
    func expandsLocalDeclarationsUnderReachedMembers() {
        // 인덱스는 함수 본문의 지역 선언을 그 함수의 자식(parentUSR)으로 남긴다.
        // 타입을 고르면 그 멤버 전체가 수정 대상이므로, 멤버 아래에 매달린 지역
        // 선언과 지역 타입의 멤버도 같은 범위에 들어와야 한다.
        var builder = SnapshotBuilder()
        builder.symbol("T", kind: .classType)
        builder.symbol("m", kind: .method, parent: "T")
        builder.symbol("local", kind: .function, parent: "m")
        builder.symbol("LocalType", kind: .structType, parent: "m")
        builder.symbol("localMember", kind: .method, parent: "LocalType")
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: builder.build())

        let expanded = ImpactSelectionExpansion.expandingContainers(["T"], graph: graph)

        #expect(expanded == ["T", "m", "local", "LocalType", "localMember"])
    }

    @Test("컨테이너가 아닌 시드는 확장 없이 그대로 돌아온다")
    func keepsNonContainerSeedsUntouched() {
        var builder = SnapshotBuilder()
        builder.symbol("Caller", kind: .function)
        builder.symbol("Callee", kind: .function)
        builder.symbol("Owner", kind: .structType)
        builder.symbol("Member", kind: .method, parent: "Owner")
        builder.reference(from: "Caller", to: "Callee", kind: .call)
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: builder.build())

        let expanded = ImpactSelectionExpansion.expandingContainers(["Caller", "Callee"], graph: graph)

        #expect(expanded == ["Caller", "Callee"])
    }

    @Test("큰 그래프의 좁은 선택은 도달 범위의 차수 합만큼만 든다")
    func narrowSelectionSkipsFullEdgeScan() {
        let memberCount = 500
        let noiseCount = 140_000
        var nodes = [GraphNode(id: "Root", name: "Root", kind: .classType)]
        let edges = (0..<memberCount).map { index in
            GraphEdge(source: "Root", target: NodeID("Member\(index)"), kind: .member)
        } + (0..<noiseCount).map { index in
            // 도달 범위 밖의 간선만이 비용 차이를 만든다 — 도달된 멤버로 향하는
            // 간선은 어느 구현이나 읽어야 하므로 노이즈는 Noise 끼리 잇는다.
            GraphEdge(source: NodeID("Noise\(index)"), target: NodeID("Noise\((index + 1) % noiseCount)"), kind: .call)
        }
        nodes += (0..<memberCount).map { GraphNode(id: NodeID("Member\($0)"), name: "Member\($0)", kind: .method) }
        nodes += (0..<noiseCount).map { GraphNode(id: NodeID("Noise\($0)"), name: "Noise\($0)", kind: .function) }
        let graph = CodeGraph(level: .symbol, nodes: nodes, edges: edges)

        let clock = ContinuousClock()
        let baselineStart = clock.now
        let baselineExpanded = Self.fullEdgeScanExpandingContainers(["Root"], graph: graph)
        let baselineElapsed = clock.now - baselineStart
        let start = clock.now
        let expanded = ImpactSelectionExpansion.expandingContainers(["Root"], graph: graph)
        let elapsed = clock.now - start

        #expect(expanded == baselineExpanded)
        #expect(expanded.count == memberCount + 1)
        #expect(expanded.contains("Root"))
        // 절대 시각은 기계·CI 부하에 따라 흔들리므로, 같은 입력 위에서 전수 스캔
        // 기준과 견준다 — 도달 범위만 읽는 구현이 4배 이상 빨라야 한다
        // (디버그 계측으로는 약 400배 차이가 났다).
        #expect(elapsed * 4 < baselineElapsed)
    }

    /// 옮기기 전 CartographKit 구현. 결과 동등성과 비용 차이의 기준선으로 남긴다.
    ///
    /// 간선 배열을 두 번 훑어 자식 사전을 전부 만든 뒤 BFS로 확장한다.
    /// 확장 의미를 의도적으로 바꾸면 이 복사본도 함께 갱신하거나 프로퍼티 비교를
    /// 거둔다. 두 구현이 같은 `graph.semanticParent`를 부르므로, 그 함수의
    /// 의미가 바뀌는 회귀는 이 비교로는 잡히지 않는다.
    private static func fullEdgeScanExpandingContainers(
        _ selected: Set<NodeID>, graph: CodeGraph
    ) -> Set<NodeID> {
        let roots = selected.filter {
            graph.node($0)?.kind.isTypeDeclaration == true || graph.node($0)?.kind == .extensionDeclaration
        }.sorted()
        guard !roots.isEmpty else { return selected }
        var children: [NodeID: Set<NodeID>] = [:]
        for edge in graph.edges where edge.kind == .member {
            children[edge.source, default: []].insert(edge.target)
            if let owner = graph.semanticParent(of: edge.target) { children[owner, default: []].insert(edge.target) }
        }
        for edge in graph.edges where edge.kind == .extends && graph.node(edge.source)?.kind == .extensionDeclaration {
            children[edge.target, default: []].insert(edge.source)
        }
        var result = selected
        var queue = roots
        var head = 0
        while head < queue.count {
            let parent = queue[head]
            head += 1
            for child in (children[parent] ?? []).sorted() where result.insert(child).inserted {
                queue.append(child)
            }
        }
        return result
    }

    @Test("간선 전수 스캔 기준 구현과 시드 폭 구현은 모든 확장 결과가 같다")
    func adjacencyVersionMatchesFullEdgeScanBaseline() {
        var builder = SnapshotBuilder()
        builder.symbol("Type", kind: .structType)
        builder.symbol("Ext", kind: .extensionDeclaration)
        builder.symbol("Nested", kind: .enumType, parent: "Type")
        builder.symbol("extMethod", kind: .method, parent: "Ext")
        builder.symbol("nestedMethod", kind: .method, parent: "Nested")
        builder.symbol("Consumer", kind: .function)
        builder.symbol("ConsumerMember", kind: .method, parent: "Consumer")
        builder.reference(from: "Ext", to: "Type", kind: .extends)
        builder.reference(from: "Consumer", to: "Type", kind: .call)
        builder.reference(from: "Consumer", to: "nestedMethod", kind: .call)
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: builder.build())

        let seeds: [Set<NodeID>] = [["Type"], ["Ext"], ["Type", "Consumer"], ["Consumer"],
            ["Type", "Ext"], ["extMethod", "nestedMethod"], []]
        for seed in seeds {
            #expect(
                ImpactSelectionExpansion.expandingContainers(seed, graph: graph)
                    == Self.fullEdgeScanExpandingContainers(seed, graph: graph)
            )
        }
    }

    @Test("무작위 심볼 그래프의 어떤 시드에서도 간선 전수 스캔 기준과 같은 집합을 돌려준다")
    func matchesBaselineAcrossRandomSymbolGraphs() {
        var generator = SeededRandomNumberGenerator(seed: 0xC0FF_EE)
        let kinds: [SymbolKind] = [.classType, .structType, .enumType, .protocolType,
            .extensionDeclaration, .method, .function, .property, .variable]
        for graphIndex in 0..<40 {
            let nodeCount = 8 + Int.random(in: 0..<12, using: &generator)
            let ids = (0..<nodeCount).map { "n\($0)" }
            let nodes = ids.map {
                GraphNode(id: NodeID($0), name: $0,
                          kind: kinds.randomElement(using: &generator)!, module: "M")
            }
            var edges: [GraphEdge] = []
            for target in ids {
                // 0~2개의 member 부모를 둔다. 비컨테이너 부모·다중 부모까지 섞인다.
                for _ in 0..<Int.random(in: 0...2, using: &generator) {
                    edges.append(GraphEdge(
                        source: NodeID(ids.randomElement(using: &generator)!),
                        target: NodeID(target), kind: .member))
                }
            }
            // extends 는 모든 종류의 정점에서 만든다 — 익스텐션이 아닌 source 의
            // extends 간선이 양쪽 구현에서 똑같이 무시되는지도 비교 대상이다.
            for node in nodes {
                for _ in 0..<Int.random(in: 0...2, using: &generator) {
                    edges.append(GraphEdge(
                        source: node.id,
                        target: NodeID(ids.randomElement(using: &generator)!), kind: .extends))
                }
            }
            for _ in 0..<nodeCount {
                edges.append(GraphEdge(
                    source: NodeID(ids.randomElement(using: &generator)!),
                    target: NodeID(ids.randomElement(using: &generator)!), kind: .call))
            }
            let graph = CodeGraph(level: .symbol, nodes: nodes, edges: edges)

            for _ in 0..<12 {
                let seed = Set(ids.filter { _ in generator.next() % 2 == 0 }.map { NodeID($0) })
                // 불일치 한 건만으로는 재현 정보가 없으므로 그래프 번호와 시드를 남긴다.
                #expect(
                    ImpactSelectionExpansion.expandingContainers(seed, graph: graph)
                        == Self.fullEdgeScanExpandingContainers(seed, graph: graph),
                    "graph \(graphIndex), seed \(seed.map(\.rawValue).sorted())"
                )
            }
        }
    }
}
