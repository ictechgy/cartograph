import CartographAnalysis
import CartographCore
import Testing

@Suite("수정 영향 그래프")
struct ImpactAnalyzerTests {
    @Test("컴파일러의 프로토콜 자기 요구사항 call을 구현체 호출자로 투영하지 않는다")
    func ignoresProtocolDeclarationCallWhenProjectingWitness() {
        let graph = CodeGraph(level: .symbol, nodes: [
            GraphNode(id: "P", name: "P", kind: .protocolType),
            GraphNode(id: "P.f", name: "f()", kind: .method),
            GraphNode(id: "Live.f", name: "f()", kind: .method),
            GraphNode(id: "Spare", name: "Spare", kind: .structType),
            GraphNode(id: "Caller", name: "Caller", kind: .function),
        ], edges: [
            edge("P", "P.f", .member), edge("P", "P.f", .call),
            edge("Live.f", "P.f", .overrides), edge("Spare", "P", .conformance),
            edge("Caller", "P.f", .call),
        ])
        let report = ImpactAnalyzer().analyze(changing: ["Live.f"], in: graph)
        #expect(report.affected.map(\.node) == [NodeID("Caller")])
    }

    @Test("소비자 방향의 사용 간선만 따라가고 포함 간선과 outgoing 사용은 무시한다")
    func followsIncomingUsageOnly() {
        let graph = makeGraph(
            nodes: ["changed", "caller", "memberOwner", "outgoing"],
            edges: [
                edge("caller", "changed", .call),
                edge("caller", "changed", .reference),
                edge("memberOwner", "changed", .member),
                edge("changed", "outgoing", .call),
            ]
        )

        let report = ImpactAnalyzer().analyze(changing: ["changed"], in: graph)

        #expect(report.changed == [NodeID("changed")])
        #expect(report.affected.map(\.node) == [NodeID("caller")])
        #expect(report.affected.first?.via == "changed")
        #expect(report.affected.first?.relationship == .dependent)
        #expect(report.affected.first?.edges == [.call, .reference])
        #expect(report.affected.first?.dispatchContract == nil)
        #expect(!report.truncatedByDepth)
    }

    @Test("같은 깊이의 후보는 선행 정점과 관계 우선순위로 결정된다")
    func choosesDeterministicPredecessor() throws {
        let graph = makeGraph(
            nodes: ["seedA", "seedB", "consumer"],
            edges: [
                edge("consumer", "seedB", .call),
                edge("consumer", "seedA", .reference),
            ]
        )

        let report = ImpactAnalyzer().analyze(changing: ["seedB", "seedA"], in: graph)

        #expect(report.changed == [NodeID("seedA"), NodeID("seedB")])
        let visit = try #require(report.affected.first)
        #expect(visit.node == "consumer")
        #expect(visit.depth == 1)
        // seedA 가 더 작은 ID 이므로 같은 consumer 를 그 경로로 설명한다.
        #expect(visit.via == "seedA")
        #expect(visit.edges == [.reference])
    }

    @Test("변경된 witness 는 계약 호출자를 찾지만 형제 witness 를 영향으로 전파하지 않는다")
    func projectsDispatchWithoutSiblingWitnesses() throws {
        let graph = makeGraph(
            nodes: ["Impl1.f", "Impl2.f", "Requirement.f", "ContractCaller", "SiblingCaller"],
            edges: [
                edge("Impl1.f", "Requirement.f", .overrides),
                edge("Impl2.f", "Requirement.f", .overrides),
                edge("ContractCaller", "Requirement.f", .call),
                edge("SiblingCaller", "Impl2.f", .call),
            ]
        )

        let report = ImpactAnalyzer().analyze(changing: ["Impl1.f"], in: graph)

        let visit = try #require(report.affected.first)
        #expect(report.affected.map(\.node) == [NodeID("ContractCaller")])
        #expect(visit.depth == 1)
        #expect(visit.via == "Impl1.f")
        #expect(visit.relationship == .dispatchCaller)
        #expect(visit.dispatchContract == "Requirement.f")
        #expect(visit.edges == [.call, .overrides])
    }

    @Test("직접 witness 소비 근거가 계약 투영 근거보다 우선한다")
    func prefersDirectProofOverProjection() throws {
        let graph = makeGraph(
            nodes: ["Impl.f", "Requirement.f", "Caller"],
            edges: [
                edge("Impl.f", "Requirement.f", .overrides),
                edge("Caller", "Impl.f", .call),
                edge("Caller", "Requirement.f", .call),
            ]
        )

        let report = ImpactAnalyzer().analyze(changing: ["Impl.f"], in: graph)
        let visit = try #require(report.affected.first)

        #expect(visit.node == "Caller")
        #expect(visit.relationship == .dependent)
        #expect(visit.dispatchContract == nil)
        #expect(visit.edges == [.call])
    }

    @Test("override 체인의 상위 계약까지 투영하고 순환에서 멈춘다")
    func projectsOverrideChainWithCycleProtection() throws {
        let graph = makeGraph(
            nodes: ["Impl.f", "Mid.f", "Base.f", "BaseCaller"],
            edges: [
                edge("Impl.f", "Mid.f", .overrides),
                edge("Mid.f", "Base.f", .overrides),
                edge("Base.f", "Mid.f", .overrides),
                edge("BaseCaller", "Base.f", .call),
            ]
        )

        let report = ImpactAnalyzer().analyze(changing: ["Impl.f"], in: graph)
        let visit = try #require(report.affected.first)

        #expect(report.affected.map(\.node) == [NodeID("BaseCaller")])
        #expect(visit.depth == 1)
        #expect(visit.via == "Impl.f")
        #expect(visit.relationship == .dispatchCaller)
        #expect(visit.dispatchContract == "Base.f")
        #expect(visit.edges == [.call, .overrides])
    }

    @Test("변경된 요구사항은 모든 구현체와 구현체 소비자를 계약 근거와 함께 찾는다")
    func requirementChangeReachesWitnesses() {
        let graph = makeGraph(
            nodes: ["Impl1.f", "Impl2.f", "Requirement.f", "Caller1", "Caller2"],
            edges: [
                edge("Impl1.f", "Requirement.f", .overrides),
                edge("Impl2.f", "Requirement.f", .overrides),
                edge("Caller1", "Impl1.f", .call),
                edge("Caller2", "Impl2.f", .reference),
            ]
        )

        let report = ImpactAnalyzer().analyze(changing: ["Requirement.f"], in: graph)
        let byNode = Dictionary(uniqueKeysWithValues: report.affected.map { ($0.node, $0) })

        #expect(byNode["Impl1.f"]?.depth == 1)
        #expect(byNode["Impl1.f"]?.via == "Requirement.f")
        #expect(byNode["Impl1.f"]?.relationship == .dispatchContract)
        #expect(byNode["Impl1.f"]?.edges == [.overrides])
        #expect(byNode["Impl2.f"]?.relationship == .dispatchContract)
        #expect(byNode["Caller1"]?.depth == 2)
        #expect(byNode["Caller1"]?.via == "Impl1.f")
        #expect(byNode["Caller2"]?.depth == 2)
    }

    @Test("깊이 상한은 실제 미방문 후보가 있을 때만 잘림으로 표시한다")
    func reportsDepthTruncationPrecisely() {
        let chain = makeGraph(
            nodes: ["A", "B", "C"],
            edges: [edge("B", "A", .call), edge("C", "B", .call)]
        )
        let shallow = ImpactAnalyzer().analyze(changing: ["A"], in: chain, maxDepth: 1)
        #expect(shallow.affected.map(\.node) == [NodeID("B")])
        #expect(shallow.truncatedByDepth)

        let exact = ImpactAnalyzer().analyze(changing: ["A"], in: chain, maxDepth: 2)
        #expect(exact.affected.map(\.node) == [NodeID("B"), NodeID("C")])
        #expect(!exact.truncatedByDepth)

        let cycle = makeGraph(
            nodes: ["A", "B"],
            edges: [edge("B", "A", .call), edge("A", "B", .call)]
        )
        let cycleAtBoundary = ImpactAnalyzer().analyze(changing: ["A"], in: cycle, maxDepth: 1)
        #expect(cycleAtBoundary.affected.map(\.node) == [NodeID("B")])
        #expect(!cycleAtBoundary.truncatedByDepth)
    }

    @Test("이만 정점 사슬과 순환을 반복문으로 처리한다")
    func handlesLargeChainAndCycle() {
        let count = 20_000
        let nodes = (0..<count).map { id in
            GraphNode(id: NodeID("N\(id)"), name: "N\(id)", kind: .function)
        }
        var edges = (1..<count).map { id in
            GraphEdge(source: NodeID("N\(id)"), target: NodeID("N\(id - 1)"), kind: .call)
        }
        edges.append(GraphEdge(source: "N0", target: NodeID("N\(count - 1)"), kind: .call))
        let graph = CodeGraph(level: .symbol, nodes: nodes, edges: edges)

        let report = ImpactAnalyzer().analyze(changing: ["N0"], in: graph)

        #expect(report.affected.count == count - 1)
        #expect(report.affected.first?.node == "N1")
        #expect(report.affected.last?.node == NodeID("N\(count - 1)"))
        #expect(report.affected.last?.depth == count - 1)
        #expect(!report.truncatedByDepth)
    }

    @Test("긴 override 체인도 경로 사본 없이 반복문으로 투영한다")
    func handlesLongOverrideChain() throws {
        let count = 20_000
        let chainIDs = (0..<count).map { "Override\($0)" }
        let nodes = chainIDs + ["Caller"]
        var edges = (0..<(count - 1)).map { index in
            GraphEdge(
                source: NodeID(chainIDs[index]), target: NodeID(chainIDs[index + 1]), kind: .overrides
            )
        }
        edges.append(
            GraphEdge(source: "Caller", target: NodeID(chainIDs[count - 1]), kind: .call)
        )
        let graph = makeGraph(nodes: nodes, edges: edges)

        let report = ImpactAnalyzer().analyze(changing: [NodeID(chainIDs[0])], in: graph)
        let visit = try #require(report.affected.first)

        #expect(report.affected.count == 1)
        #expect(visit.node == "Caller")
        #expect(visit.depth == 1)
        #expect(visit.dispatchContract == NodeID(chainIDs[count - 1]))
        #expect(visit.edges == [EdgeKind.call, EdgeKind.overrides])
        #expect(!report.truncatedByDepth)
    }

    @Test("많은 witness 가 공유하는 계약의 호출자를 한 번만 투영한다")
    func reusesDispatchProjectionAcrossWitnesses() {
        let witnessCount = 5_000
        let callerCount = 5_000
        let requirement = "Requirement.f"
        let witnessIDs = (0..<witnessCount).map { "Witness\($0)" }
        let callerIDs = (0..<callerCount).map { "Caller\($0)" }
        let nodes = witnessIDs + callerIDs + [requirement]
        let edges = witnessIDs.map {
            GraphEdge(source: NodeID($0), target: NodeID(requirement), kind: .overrides)
        } + callerIDs.map {
            GraphEdge(source: NodeID($0), target: NodeID(requirement), kind: .call)
        }
        let graph = makeGraph(nodes: nodes, edges: edges)
        let clock = ContinuousClock()
        let start = clock.now

        let report = ImpactAnalyzer().analyze(
            changing: Set(witnessIDs.map { NodeID($0) }), in: graph
        )

        #expect(report.affected.count == callerCount)
        #expect(report.affected.allSatisfy { $0.depth == 1 && $0.via == "Witness0" })
        #expect(report.affected.allSatisfy { $0.dispatchContract == NodeID(requirement) })
        // 계약 호출자 C 명을 W 명 witness 마다 다시 훑으면 이 입력의 비용이
        // W×C 로 늘어난다. 공유 계약 투영은 그래프 크기에 비례해야 한다.
        #expect(clock.now - start < .seconds(3))
    }

    private func makeGraph(nodes: [String], edges: [GraphEdge]) -> CodeGraph {
        CodeGraph(
            level: .symbol,
            nodes: nodes.map { GraphNode(id: NodeID($0), name: $0, kind: .function) },
            edges: edges
        )
    }

    private func edge(_ source: String, _ target: String, _ kind: EdgeKind) -> GraphEdge {
        GraphEdge(source: NodeID(source), target: NodeID(target), kind: kind)
    }
}
