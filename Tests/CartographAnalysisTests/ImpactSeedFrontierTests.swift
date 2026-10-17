@testable import CartographAnalysis
import CartographCore
import Testing

@Suite("영향 탐색 시드 전선")
struct ImpactSeedFrontierTests {
    @Test("시드 전선의 존재 확인 횟수는 무관한 정점 수와 상관없이 시드 수와 같다")
    func initialFrontierChecksOnlyChangedIDs() {
        let changed: [NodeID] = ["Missing", "Seed"]
        let changedSet = Set(changed)
        for noiseCount in [0, 20_000] {
            let graph = Self.narrowGraph(noiseCount: noiseCount)
            var queried: [NodeID] = []
            let frontier = ImpactAnalyzer.initialFrontier(changed: changed) { id in
                queried.append(id)
                return graph.contains(id)
            }
            var baselinePredicateCalls = 0
            let baseline = graph.nodeIDs.filter { id in
                baselinePredicateCalls += 1
                return changedSet.contains(id)
            }

            #expect(frontier == baseline)
            #expect(frontier == [NodeID("Seed")])
            #expect(queried == changed)
            // 초기 전선 헬퍼에 전달한 실제 존재 조회만 센다. 분석 전체의 비용이나
            // 실행 시간을 측정하는 검사는 아니다. 전수 스캔은 양성 대조로 남긴다.
            #expect(queried.count == 2)
            #expect(baselinePredicateCalls == noiseCount + 3)

            let report = ImpactAnalyzer().analyze(changing: changedSet, in: graph)
            #expect(report == ImpactReport(
                changed: changed,
                affected: [
                    ImpactVisit(node: "Caller", depth: 1, via: "Seed", relationship: .dependent, edges: [.call]),
                    ImpactVisit(node: "Tail", depth: 2, via: "Caller", relationship: .dependent, edges: [.reference]),
                ],
                truncatedByDepth: false
            ))
        }
    }

    @Test("빈 시드와 그래프에 없는 시드는 변경 목록을 보존하고 영향이나 잘림을 만들지 않는다")
    func missingAndEmptySeedsRemainInChangedOnly() {
        let graph = Self.narrowGraph(noiseCount: 0)
        let inputs: [Set<NodeID>] = [[], ["MissingZ", "MissingA"]]
        let depths: [Int?] = [nil, -1, 0, 1]
        for changed in inputs {
            var queried: [NodeID] = []
            let frontier = ImpactAnalyzer.initialFrontier(changed: changed.sorted()) { id in
                queried.append(id)
                return graph.contains(id)
            }
            #expect(frontier.isEmpty)
            #expect(queried == changed.sorted())
            for depth in depths {
                #expect(ImpactAnalyzer().analyze(changing: changed, in: graph, maxDepth: depth) == ImpactReport(
                    changed: changed.sorted(), affected: [], truncatedByDepth: false
                ))
            }
        }
    }

    @Test("그래프와 시드 순서를 뒤집어도 깊이별 디스패치와 런타임 근거를 포함한 전체 보고서가 같다")
    func preservesExactReportsAcrossInputOrderAndDepth() {
        let nodes = Self.mixedNodes()
        let edges = Self.mixedEdges()
        let dependencies = Self.mixedDependencies()
        let seedOrder: [NodeID] = ["SeedB", "Missing", "SeedA"]
        let depths: [Int?] = [nil, -1, 0, 1, 2, 3]
        for reversed in [false, true] {
            let graph = CodeGraph(
                level: .symbol,
                nodes: reversed ? Array(nodes.reversed()) : nodes,
                edges: reversed ? Array(edges.reversed()) : edges
            )
            var seeds: Set<NodeID> = []
            for seed in reversed ? Array(seedOrder.reversed()) : seedOrder { seeds.insert(seed) }
            for depth in depths {
                let report = ImpactAnalyzer().analyze(
                    changing: seeds, in: graph, maxDepth: depth,
                    additionalDependencies: reversed ? Array(dependencies.reversed()) : dependencies
                )
                let limit = depth.map { max(0, $0) } ?? Int.max
                #expect(report == ImpactReport(
                    changed: ["Missing", "SeedA", "SeedB"],
                    affected: Self.expectedVisits().filter { $0.depth <= limit },
                    truncatedByDepth: limit < 2
                ))
            }
        }
    }

    private static func narrowGraph(noiseCount: Int) -> CodeGraph {
        let nodes = ["Seed", "Caller", "Tail"].map(node)
            + (0..<noiseCount).map { node("Noise\($0)") }
        return CodeGraph(level: .symbol, nodes: nodes, edges: [
            edge("Caller", "Seed", .call),
            edge("Tail", "Caller", .reference),
        ])
    }

    private static func mixedNodes() -> [GraphNode] {
        ["SeedA", "SeedB", "Contract", "Direct", "DispatchCaller", "Runtime",
         "NextContract", "NextDispatch", "Tail", "Owner", "Outgoing"].map(node)
    }

    private static func mixedEdges() -> [GraphEdge] {
        [
            edge("SeedB", "Contract", .overrides),
            edge("SeedA", "Contract", .overrides),
            edge("DispatchCaller", "Contract", .reference),
            edge("DispatchCaller", "Contract", .call),
            edge("Direct", "SeedB", .call),
            edge("Direct", "SeedA", .reference),
            edge("Direct", "SeedA", .call),
            // 다음 층도 공유 계약의 첫 witness 가 결정적인 부모가 되어야 한다.
            edge("DispatchCaller", "NextContract", .overrides),
            edge("Direct", "NextContract", .overrides),
            edge("NextDispatch", "NextContract", .call),
            edge("Tail", "DispatchCaller", .reference),
            edge("Tail", "Direct", .call),
            edge("SeedA", "Tail", .call),
            edge("SeedB", "SeedA", .call),
            edge("Owner", "SeedA", .member),
            edge("SeedA", "Outgoing", .call),
        ]
    }

    private static func mixedDependencies() -> [ImpactDependency] {
        [
            ImpactDependency(source: "Runtime", target: "SeedB", contract: "other-seed"),
            ImpactDependency(source: "Runtime", target: "SeedA", contract: "z-contract"),
            ImpactDependency(source: "Runtime", target: "SeedA", contract: "a-contract"),
            ImpactDependency(source: "Runtime", target: "SeedA", contract: "a-contract"),
            ImpactDependency(
                source: "Runtime", target: "SeedA", contract: "observed", origin: .observed,
                kind: .selectorInvocation
            ),
            ImpactDependency(
                source: "Runtime", target: "SeedA", contract: "automatic", origin: .automatic,
                kind: .selectorReference
            ),
            ImpactDependency(source: "Direct", target: "SeedA", contract: "direct-also-runtime"),
            ImpactDependency(source: "GhostCaller", target: "SeedA", contract: "missing-source"),
            ImpactDependency(source: "Runtime", target: "Missing", contract: "missing-target"),
        ]
    }

    private static func expectedVisits() -> [ImpactVisit] {
        [
            ImpactVisit(
                node: "Direct", depth: 1, via: "SeedA", relationship: .dependent, edges: [.call, .reference]
            ),
            ImpactVisit(
                node: "DispatchCaller", depth: 1, via: "SeedA", relationship: .dispatchCaller,
                edges: [.call, .overrides, .reference], dispatchContract: "Contract"
            ),
            ImpactVisit(
                node: "Runtime", depth: 1, via: "SeedA", relationship: .observedRuntime, edges: [],
                runtimeContracts: ["a-contract", "z-contract"],
                runtimeEvidence: [
                    RuntimeEvidenceReference(id: "automatic", origin: .automatic, kind: .selectorReference),
                    RuntimeEvidenceReference(id: "observed", origin: .observed, kind: .selectorInvocation),
                ]
            ),
            ImpactVisit(
                node: "NextDispatch", depth: 2, via: "Direct", relationship: .dispatchCaller,
                edges: [.call, .overrides], dispatchContract: "NextContract"
            ),
            ImpactVisit(node: "Tail", depth: 2, via: "Direct", relationship: .dependent, edges: [.call]),
        ]
    }

    private static func node(_ id: String) -> GraphNode {
        GraphNode(id: NodeID(id), name: id, kind: .function)
    }

    private static func edge(_ source: String, _ target: String, _ kind: EdgeKind) -> GraphEdge {
        GraphEdge(source: NodeID(source), target: NodeID(target), kind: kind)
    }
}
