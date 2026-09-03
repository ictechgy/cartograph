import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("레이어 규칙 검증")
struct LayerRuleEvaluatorTests {
    private let layers = [
        LayerDefinition(name: "Presentation", patterns: ["Features/**", "*ViewController"]),
        LayerDefinition(name: "Domain", patterns: ["Domain", "Domain/**"]),
        LayerDefinition(name: "Data", patterns: ["Data", "Data/**", "*Repository"]),
    ]

    private func makeGraph() -> CodeGraph {
        CodeGraph(
            level: .module,
            nodes: [
                GraphNode(id: "Presentation", name: "Presentation", kind: .module, module: "Presentation",
                          location: SourceLocation(path: "Features/Home.swift", line: 1, column: 1)),
                GraphNode(id: "Domain", name: "Domain", kind: .module, module: "Domain"),
                GraphNode(id: "Data", name: "Data", kind: .module, module: "Data"),
            ],
            edges: [
                GraphEdge(source: "Presentation", target: "Domain", kind: .call),
                GraphEdge(source: "Presentation", target: "Data", kind: .call),
                GraphEdge(source: "Domain", target: "Data", kind: .reference),
            ]
        )
    }

    @Test("금지된 의존을 위반으로 보고한다")
    func reportsDeniedDependency() {
        let evaluator = LayerRuleEvaluator(
            layers: layers,
            rules: [LayerRule(from: "Presentation", deny: ["Data"])]
        )
        let violations = evaluator.evaluate(graph: makeGraph())
        #expect(violations.count == 1)
        #expect(violations[0].sourceLayer == "Presentation")
        #expect(violations[0].targetLayer == "Data")
        #expect(violations[0].message.contains("must not depend on Data"))
    }

    @Test("허용 목록은 화이트리스트로 동작한다")
    func allowListIsExclusive() {
        let evaluator = LayerRuleEvaluator(
            layers: layers,
            rules: [LayerRule(from: "Domain", allow: [])]
        )
        let violations = evaluator.evaluate(graph: makeGraph())
        #expect(violations.count == 1)
        #expect(violations[0].sourceLayer == "Domain")
    }

    @Test("같은 레이어 안의 의존은 위반이 아니다")
    func sameLayerIsAlwaysAllowed() {
        let graph = CodeGraph(
            level: .module,
            nodes: [
                GraphNode(id: "A", name: "A", kind: .module, module: "Data"),
                GraphNode(id: "B", name: "B", kind: .module, module: "Data"),
            ],
            edges: [GraphEdge(source: "A", target: "B", kind: .call)]
        )
        let evaluator = LayerRuleEvaluator(layers: layers, rules: [LayerRule(from: "Data", allow: [])])
        #expect(evaluator.evaluate(graph: graph).isEmpty)
    }

    @Test("레이어 판정은 이름과 파일 경로를 모두 본다")
    func layerMatchingUsesNameAndPath() {
        let evaluator = LayerRuleEvaluator(layers: layers, rules: [])
        let byPath = GraphNode(
            id: "n", name: "Home", kind: .classType, module: "App",
            location: SourceLocation(path: "Features/Home/Home.swift", line: 1, column: 1)
        )
        #expect(evaluator.layer(of: byPath) == "Presentation")

        let byName = GraphNode(id: "n2", name: "UserRepository", kind: .classType, module: "App")
        #expect(evaluator.layer(of: byName) == "Data")

        let unmatched = GraphNode(id: "n3", name: "Utility", kind: .structType, module: "Shared")
        #expect(evaluator.layer(of: unmatched) == nil)
    }

    @Test("먼저 정의된 레이어가 우선한다")
    func firstMatchingLayerWins() {
        let overlapping = [
            LayerDefinition(name: "First", patterns: ["*"]),
            LayerDefinition(name: "Second", patterns: ["*"]),
        ]
        let evaluator = LayerRuleEvaluator(layers: overlapping, rules: [])
        #expect(evaluator.layer(of: GraphNode(id: "n", name: "X", kind: .module)) == "First")
    }

    @Test("어느 레이어에도 속하지 않은 정점을 알려 준다")
    func reportsUnassignedNodes() {
        let graph = TestGraph.make(["HomeViewController": [], "Unknown": []])
        let evaluator = LayerRuleEvaluator(layers: layers, rules: [])
        #expect(evaluator.unassignedNodes(in: graph) == [NodeID("Unknown")])
    }

    @Test("레이어나 규칙이 없으면 아무것도 검사하지 않는다")
    func noLayersMeansNoEvaluation() {
        #expect(LayerRuleEvaluator(layers: [], rules: []).evaluate(graph: makeGraph()).isEmpty)
        #expect(LayerRuleEvaluator(layers: layers, rules: []).evaluate(graph: makeGraph()).isEmpty)
        #expect(LayerRuleEvaluator(layers: [], rules: []).unassignedNodes(in: makeGraph()).isEmpty)
    }

    @Test("포함 관계 간선은 의존으로 세지 않는다")
    func containmentEdgesAreIgnored() {
        let graph = CodeGraph(
            level: .type,
            nodes: [
                GraphNode(id: "A", name: "HomeViewController", kind: .classType, module: "App"),
                GraphNode(id: "B", name: "UserRepository", kind: .classType, module: "App"),
            ],
            edges: [GraphEdge(source: "A", target: "B", kind: .member)]
        )
        let evaluator = LayerRuleEvaluator(
            layers: layers,
            rules: [LayerRule(from: "Presentation", deny: ["Data"])]
        )
        #expect(evaluator.evaluate(graph: graph).isEmpty)
    }

    @Test("위반은 출발 정점의 위치를 함께 보고한다")
    func violationCarriesLocation() {
        let evaluator = LayerRuleEvaluator(
            layers: layers,
            rules: [LayerRule(from: "Presentation", deny: ["Data"])]
        )
        let violation = evaluator.evaluate(graph: makeGraph()).first
        #expect(violation?.location?.path == "Features/Home.swift")
    }
    @Test("레이어 판정의 근거를 남긴다")
    func explainsLayerAssignment() {
        // 설정을 디버깅할 때 아픈 지점은 "이 정점이 왜 저 레이어인가"다.
        // 무엇이 어느 패턴에 맞았는지 보여 주지 않으면 패턴을 바꿔 가며 추측하게 된다.
        let evaluator = LayerRuleEvaluator(
            layers: [
                LayerDefinition(name: "Presentation", patterns: ["**/Features/**"]),
                LayerDefinition(name: "Data", patterns: ["*Repository"]),
            ],
            rules: [LayerRule(name: "no data", from: "Presentation", deny: ["Data"])]
        )
        let view = GraphNode(
            id: NodeID("V"), name: "HomeView", kind: .structType, module: "App",
            location: SourceLocation(path: "/p/Features/HomeView.swift", line: 1, column: 1)
        )
        let assignment = evaluator.assignment(of: view)
        #expect(assignment.layer == "Presentation")
        #expect(assignment.match?.pattern == "**/Features/**")
        #expect(assignment.match?.candidate == "/p/Features/HomeView.swift")
        #expect(evaluator.rules(from: "Presentation").count == 1)
        #expect(evaluator.rules(from: "Data").isEmpty)

        let orphan = GraphNode(id: NodeID("O"), name: "Loose", kind: .structType, module: "App")
        let unmatched = evaluator.assignment(of: orphan)
        #expect(unmatched.layer == nil)
        // 같은 문자열이 여러 후보로 겹치면 한 번만 보여 준다.
        #expect(unmatched.candidates == ["Loose", "App.Loose", "App"])
    }

}
