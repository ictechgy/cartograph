import CartographAnalysis
import CartographCore
import Testing

@Suite("익스텐션 질의의 원형 타입 신원")
struct ExtensionQueryIdentityTests {
    @Test("타입 하나와 그 타입만 확장하는 세 선언은 이름으로 하나를 찾되 USR 조회는 보존한다")
    func oneTypeAndThreeExtensionsResolveToTheType() {
        let type = GraphNode(id: "a:type", name: "Widget", kind: .classType, module: "App")
        let extensions = (1...3).map {
            GraphNode(id: NodeID("b:extension\($0)"), name: "Widget", kind: .extensionDeclaration, module: "App")
        }
        let edges = extensions.map { GraphEdge(source: $0.id, target: type.id, kind: .extends) }
        for nodes in [[type] + extensions, Array(extensions.reversed()) + [type]] {
            let index = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: nodes, edges: edges))
            #expect(index.resolve("Widget") == .found(type))
            #expect(index.resolve("App.Widget") == .found(type))
            for node in nodes { #expect(index.resolve(node.id.rawValue) == .found(node)) }
        }
    }

    @Test("같은 이름의 실제 타입 둘은 익스텐션이 있어도 모호하게 남긴다")
    func distinctTypesRemainAmbiguous() {
        let first = GraphNode(id: "a:type", name: "Widget", kind: .classType, module: "App")
        let second = GraphNode(id: "b:type", name: "Widget", kind: .classType, module: "Other")
        let extensionNode = GraphNode(id: "c:extension", name: "Widget", kind: .extensionDeclaration, module: "App")
        let nodes = [first, second, extensionNode]
        let index = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: Array(nodes.reversed()), edges: [
            GraphEdge(source: extensionNode.id, target: first.id, kind: .extends)
        ]))
        #expect(index.resolve("Widget") == .ambiguous(nodes))
        #expect(index.resolve("App.Widget") == .found(first))
        #expect(index.resolve("Other.Widget") == .found(second))
    }

    @Test("관계가 없거나 다른 종류의 간선만 있으면 동명 익스텐션을 합치지 않는다")
    func namesAndOrdinaryEdgesAreNotTypeIdentity() {
        let type = GraphNode(id: "a:type", name: "Widget", kind: .structType, module: "App")
        let extensionNode = GraphNode(id: "b:extension", name: "Widget", kind: .extensionDeclaration, module: "App")
        for edges in [[], [EdgeKind.reference, .inheritance, .member].map {
            GraphEdge(source: extensionNode.id, target: type.id, kind: $0)
        }] {
            let index = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: [type, extensionNode], edges: edges))
            #expect(index.resolve("Widget") == .ambiguous([type, extensionNode]))
        }
    }

    @Test("익스텐션의 두 대상 중 이름이 맞는 하나만 골라 확정하지 않는다")
    func multipleTargetsRemainAmbiguous() {
        let type = GraphNode(id: "a:type", name: "Widget", kind: .classType)
        let extensionNode = GraphNode(id: "b:extension", name: "Widget", kind: .extensionDeclaration)
        let other = GraphNode(id: "c:type", name: "Different", kind: .classType)
        let index = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: [type, extensionNode, other], edges: [
            GraphEdge(source: extensionNode.id, target: type.id, kind: .extends),
            GraphEdge(source: extensionNode.id, target: other.id, kind: .extends)
        ]))
        #expect(index.resolve("Widget") == .ambiguous([type, extensionNode]))
    }

    @Test("익스텐션 사슬과 순환은 원형 증명으로 쓰지 않는다")
    func extensionChainsAndCyclesRemainAmbiguous() {
        let type = GraphNode(id: "a:type", name: "Widget", kind: .classType)
        let first = GraphNode(id: "b:extension", name: "Widget", kind: .extensionDeclaration)
        let second = GraphNode(id: "c:extension", name: "Widget", kind: .extensionDeclaration)
        for target in [type.id, first.id] {
            let index = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: [type, first, second], edges: [
                GraphEdge(source: first.id, target: second.id, kind: .extends),
                GraphEdge(source: second.id, target: target, kind: .extends)
            ]))
            #expect(index.resolve("Widget") == .ambiguous([type, first, second]))
        }
    }

    @Test("타입 아닌 동명 선언이나 집계 레벨에서는 익스텐션으로 모호성을 지우지 않는다")
    func nonNominalDeclarationsAndAggregatedGraphsKeepTheirCandidates() {
        for kind in [SymbolKind.function, .typeAlias, .associatedType] {
            let target = GraphNode(id: "a:target", name: "Widget", kind: kind)
            let extensionNode = GraphNode(id: "b:extension", name: "Widget", kind: .extensionDeclaration)
            let index = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: [target, extensionNode], edges: [
                GraphEdge(source: extensionNode.id, target: target.id, kind: .extends)
            ]))
            #expect(index.resolve("Widget") == .ambiguous([target, extensionNode]))
        }
        let type = GraphNode(id: "a:type", name: "Widget", kind: .classType)
        let extensionNode = GraphNode(id: "b:extension", name: "Widget", kind: .extensionDeclaration)
        let index = GraphQueryIndex(graph: CodeGraph(level: .type, nodes: [type, extensionNode], edges: [
            GraphEdge(source: extensionNode.id, target: type.id, kind: .extends)
        ]))
        #expect(index.resolve("Widget") == .ambiguous([type, extensionNode]))
    }
}
