import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("프로토콜 요구사항의 상속")
struct ProtocolRefinementReachabilityTests {
    @Test("자식 요구사항 호출은 부모 요구사항과 부모 기본 구현을 보존한다")
    func inheritedRequirementKeepsParentDefault() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Parent", kind: .protocolType)
        builder.symbol("Parent.run", name: "run()", kind: .method, parent: "Parent")
        builder.symbol("Child", kind: .protocolType)
        builder.symbol("Child.run", name: "run()", kind: .method, parent: "Child")
        builder.symbol("Defaults", name: "Parent", kind: .extensionDeclaration)
        builder.symbol("Defaults.run", name: "run()", kind: .method, parent: "Defaults")
        builder.symbol("helper", kind: .function)
        builder.reference(from: "App", to: "Child.run", kind: .call)
        builder.reference(from: "Child.run", to: "Parent.run", kind: .overrides)
        builder.reference(from: "Defaults", to: "Parent", kind: .extends)
        builder.reference(from: "Defaults.run", to: "Parent.run", kind: .overrides)
        builder.reference(from: "Defaults.run", to: "helper", kind: .call)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let result = ReachabilityAnalyzer(options: .init(reportMembersOfUnusedTypes: true))
            .analyze(graph: graph, snapshot: snapshot)
        let unused = Set(result.unused.map(\.id))
        #expect(!unused.contains("Parent.run"))
        #expect(!unused.contains("Defaults.run"))
        #expect(!unused.contains("helper"))
    }
}
