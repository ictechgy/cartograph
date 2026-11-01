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

    @Test("프로젝트 상대 패턴과 절대 패턴을 같은 컴파일러 경로에 적용한다")
    func projectRelativeAndAbsolutePatterns() {
        let node = GraphNode(id: "n", name: "Home", kind: .structType, module: "App",
            location: .init(path: "/p/Features/Home.swift", line: 1, column: 1))
        for pattern in ["Features/**", "/p/Features/**", "**/Features/**"] {
            let evaluator = LayerRuleEvaluator(
                layers: [.init(name: "UI", patterns: [GlobPattern(pattern)])], rules: [], projectPath: "/p"
            )
            #expect(evaluator.layer(of: node) == "UI")
            #expect(evaluator.assignment(of: node).layer == "UI")
        }
        let evaluator = LayerRuleEvaluator(layers: [
            .init(name: "UI", patterns: ["Features/**"]),
            .init(name: "Fallback", patterns: ["App"]),
        ], rules: [], projectPath: "/p")
        #expect(evaluator.assignment(of: node).match?.candidate == "Features/Home.swift")
        #expect(evaluator.layer(of: node) == "UI")
    }

    @Test("프로젝트 경계 밖 경로는 상대 패턴에 잘못 포함하지 않는다")
    func projectBoundaryAndOutsideAbsolutePattern() {
        let outside = GraphNode(id: "n", name: "Home", kind: .structType, module: "App",
            location: .init(path: "/project-other/Features/Home.swift", line: 1, column: 1))
        let evaluator = LayerRuleEvaluator(layers: [
            .init(name: "UI", patterns: ["Features/**"]),
        ], rules: [], projectPath: "/project")
        #expect(evaluator.layer(of: outside) == nil)
        let explicit = LayerRuleEvaluator(layers: [
            .init(name: "External", patterns: ["/project-other/Features/**"]),
        ], rules: [], projectPath: "/project")
        #expect(explicit.layer(of: outside) == "External")
    }

    @Test("임의 private 접두사는 프로젝트 별칭으로 취급하지 않는다")
    func unprovenPrivatePrefixIsOutsideProject() {
        let outside = GraphNode(id: "n", name: "Home", kind: .structType, module: "App",
            location: .init(path: "/private/project/Features/Home.swift", line: 1, column: 1))
        let evaluator = LayerRuleEvaluator(layers: [
            .init(name: "UI", patterns: ["Features/**"]),
            .init(name: "External", patterns: ["/private/project/Features/**"]),
        ], rules: [], projectPath: "/project")
        #expect(evaluator.layer(of: outside) == "External")
        #expect(evaluator.assignment(of: outside).match?.candidate == outside.location?.path)
        #expect(!evaluator.assignment(of: outside).candidates.contains("Features/Home.swift"))
    }

    @Test("준비된 루트 별칭과 끝 슬래시를 순수 문자열로 대조한다")
    func preparedProjectAliasesAndTrailingSlash() {
        let evaluator = LayerRuleEvaluator(layers: [
            .init(name: "UI", patterns: ["Features/**"]),
        ], rules: [], projectPaths: ["/tmp/LayerProject/", "/private/tmp/LayerProject/"])
        let node = GraphNode(id: "n", name: "Home", kind: .structType, module: "App",
            location: .init(path: "/private/tmp/LayerProject/Features/Home.swift", line: 1, column: 1))
        #expect(evaluator.layer(of: node) == "UI")
    }

    @Test("리터럴 루트 초기화는 실제 파일 시스템 별칭도 임의로 추측하지 않는다")
    func literalProjectPathDoesNotResolveAliases() {
        let evaluator = LayerRuleEvaluator(layers: [
            .init(name: "UI", patterns: ["Features/**"]),
        ], rules: [], projectPath: "/tmp/LayerProject/")
        let node = GraphNode(id: "n", name: "Home", kind: .structType, module: "App",
            location: .init(path: "/private/tmp/LayerProject/Features/Home.swift", line: 1, column: 1))
        #expect(evaluator.layer(of: node) == nil)
        #expect(!evaluator.assignment(of: node).candidates.contains("Features/Home.swift"))
    }

    @Test("기존 초기화 함수 참조와 루트 없는 경로 판정을 유지한다")
    func originalInitializerFunctionReference() {
        let make: ([LayerDefinition], [LayerRule]) -> LayerRuleEvaluator = LayerRuleEvaluator.init
        let evaluator = make([.init(name: "UI", patterns: ["Features/**"])], [])
        let node = GraphNode(id: "n", name: "Home", kind: .structType, module: "App",
            location: .init(path: "Features/Home.swift", line: 1, column: 1))
        #expect(evaluator.layer(of: node) == "UI")
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

    /// 보존 합성 간선은 지표의 결합도에도, 순환에도 들어가지 않는다. 레이어 규칙만 이것을 의존으로
    /// 세면 같은 간선 하나가 "결합은 없는데 금지된 의존은 있다"는 모순된 답을 낸다.
    @Test("보존 합성 간선은 레이어 의존으로 세지 않는다")
    func retentionEdgesAreNotLayerDependencies() {
        let graph = CodeGraph(
            level: .type,
            nodes: [
                GraphNode(id: "A", name: "HomeViewController", kind: .classType, module: "App"),
                GraphNode(id: "B", name: "UserRepository", kind: .classType, module: "App"),
            ],
            edges: [GraphEdge(source: "A", target: "B", kind: .retention)]
        )
        let evaluator = LayerRuleEvaluator(
            layers: layers,
            rules: [LayerRule(from: "Presentation", deny: ["Data"])]
        )
        #expect(evaluator.evaluate(graph: graph).isEmpty)
        #expect(evaluator.assess(graph: graph).violations.isEmpty)
    }

    @Test("참조 근거가 없으면 선언 위치를 위반 발생 위치로 대신 쓰지 않는다")
    func violationCarriesLocation() {
        let evaluator = LayerRuleEvaluator(
            layers: layers,
            rules: [LayerRule(from: "Presentation", deny: ["Data"])]
        )
        let violation = evaluator.evaluate(graph: makeGraph()).first
        #expect(violation?.location == nil)
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

    @Test("대조 대상을 좁힌 레이어는 그 대상의 후보만 본다")
    func matchTargetsRestrictCandidates() {
        // 모듈 이름을 뜻한 "Networking" 이 App 모듈의 같은 이름 네임스페이스 타입에 걸리면 안 된다.
        let evaluator = LayerRuleEvaluator(layers: [
            LayerDefinition(name: "Networking", patterns: ["Networking"], matchTargets: [.module]),
            LayerDefinition(name: "Screens", patterns: ["Features/**"], matchTargets: [.path]),
            LayerDefinition(name: "Named", patterns: ["*Screen*"], matchTargets: [.name]),
        ], rules: [], projectPath: "/p")
        let namespace = GraphNode(id: "a", name: "Networking", kind: .enumType, module: "App")
        let client = GraphNode(id: "b", name: "Client", kind: .classType, module: "Networking")
        #expect(evaluator.layer(of: namespace) == nil)
        #expect(evaluator.layer(of: client) == "Networking")
        // 모듈 정점은 이름과 모듈이 같은 문자열이다. 문자열의 첫 출처만 기억하면 모듈 대상 레이어가 놓친다.
        #expect(evaluator.layer(of: GraphNode(id: "Networking", name: "Networking", kind: .module,
                                              module: "Networking")) == "Networking")

        // 이름 대상 레이어는 경로에 맞는 패턴을 보지 않고, 경로 대상 레이어는 이름을 보지 않는다.
        let screen = GraphNode(id: "c", name: "HomeScreen", kind: .structType, module: "App",
            location: .init(path: "/p/Sources/HomeScreen.swift", line: 1, column: 1))
        let feature = GraphNode(id: "d", name: "Home", kind: .structType, module: "App",
            location: .init(path: "/p/Features/Home.swift", line: 1, column: 1))
        let login = GraphNode(id: "e", name: "Login", kind: .structType, module: "App",
            location: .init(path: "/p/Sources/LoginScreen.swift", line: 1, column: 1))
        #expect(evaluator.layer(of: screen) == "Named")
        #expect(evaluator.layer(of: login) == nil)
        #expect(evaluator.layer(of: feature) == "Screens")
        let assignment = evaluator.assignment(of: feature)
        #expect(assignment.match?.candidate == "Features/Home.swift")
        #expect(assignment.match?.matchTargets == [.path])
        // 설명의 후보 목록은 대상과 무관하게 전부다. 무엇을 봤는지 숨기지 않는다.
        #expect(assignment.candidates == ["Home", "App.Home", "App", "/p/Features/Home.swift", "Features/Home.swift"])
        #expect(LayerRuleEvaluator(layers: [.init(name: "UI", patterns: ["Features/**"])], rules: [],
                                   projectPath: "/p").assignment(of: feature).match?.matchTargets == nil)
    }

    /// 대상은 기본 판정이 비교하던 후보를 나눌 뿐이다. 문서에 적은 두 경계를 고정한다.
    @Test("이름 대상은 정규화 이름을, 경로 대상은 파일 이름을 포함한다")
    func matchTargetBoundaries() {
        // `name` 은 모듈을 붙인 정규화 이름도 본다. `Network*` 는 NetworkKit 모듈의 선언에도 맞는다.
        let byName = LayerRuleEvaluator(layers: [
            LayerDefinition(name: "Net", patterns: ["Network*"], matchTargets: [.name]),
        ], rules: [])
        #expect(byName.layer(of: GraphNode(id: "c", name: "Client", kind: .classType, module: "NetworkKit")) == "Net")
        #expect(byName.assignment(of: GraphNode(id: "c", name: "Client", kind: .classType, module: "NetworkKit"))
            .match?.candidate == "NetworkKit.Client")

        // `/` 없는 경로 패턴은 마지막 요소(파일 이름)에 대조된다. 타입과 이름이 같은 파일이면 그대로 맞고,
        // 이름이 다른 파일에 선언된 타입에는 맞지 않는다.
        let byPath = LayerRuleEvaluator(layers: [
            LayerDefinition(name: "Net", patterns: ["*Network*"], matchTargets: [.path]),
        ], rules: [], projectPath: "/p")
        let sameFile = GraphNode(id: "e1", name: "NetworkError", kind: .structType, module: "App",
            location: .init(path: "/p/Domain/NetworkError.swift", line: 1, column: 1))
        let otherFile = GraphNode(id: "e2", name: "NetworkError", kind: .structType, module: "App",
            location: .init(path: "/p/Domain/Errors.swift", line: 1, column: 1))
        #expect(byPath.layer(of: sameFile) == "Net")
        #expect(byPath.assignment(of: sameFile).match?.candidate == "/p/Domain/NetworkError.swift")
        #expect(byPath.layer(of: otherFile) == nil)
    }

    @Test("대조 대상은 정렬·중복 제거되어 같은 설정이 같은 값이 된다")
    func matchTargetsAreNormalized() {
        let layer = LayerDefinition(name: "L", patterns: ["*"], matchTargets: [.path, .name, .path])
        #expect(layer.matchTargets == [.name, .path])
        #expect(layer == LayerDefinition(name: "L", patterns: ["*"], matchTargets: [.name, .path]))
        #expect(LayerDefinition(name: "L", patterns: ["*"]).matchTargets == nil)
    }
}
