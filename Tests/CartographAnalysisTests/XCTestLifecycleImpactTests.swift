import CartographCore
import CartographTestSupport
@testable import CartographAnalysis
import Testing

@Suite("XCTest 실행 의존성")
struct XCTestLifecycleImpactTests {
    @Test("일반 도우미와 인자가 있는 동명 함수는 생명주기 호출로 간주하지 않는다")
    func excludesOrdinaryMembers() {
        var builder = SnapshotBuilder()
        builder.symbol("Tests", kind: .classType, attributes: [.unitTest])
        builder.symbol("helper", name: "helper()", kind: .method, parent: "Tests")
        builder.symbol("overload", name: "setUp(_:)", kind: .method, parent: "Tests")
        builder.symbol("Production", kind: .classType)
        builder.symbol("setup", name: "setUp()", kind: .method, parent: "Production")
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: builder.build())
        #expect(XCTestLifecycleImpact(in: graph).dependencies.isEmpty)
    }

    @Test("표식 없는 상위 클래스의 익스텐션 생명주기도 찾고 상속 순환에서 멈춘다")
    func inheritedExtensionHookSurvivesCycles() {
        var builder = SnapshotBuilder()
        builder.symbol("Base", kind: .classType)
        builder.symbol("Extension", kind: .extensionDeclaration)
        builder.reference(from: "Extension", to: "Base", kind: .extends)
        builder.symbol("hook", name: "tearDown()", kind: .method, parent: "Extension")
        builder.symbol("Child", kind: .classType, attributes: [.unitTest])
        builder.symbol("Grandchild", kind: .classType)
        builder.reference(from: "Child", to: "Base", kind: .inheritance)
        builder.reference(from: "Grandchild", to: "Child", kind: .inheritance)
        builder.reference(from: "Child", to: "Grandchild", kind: .inheritance)
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: builder.build())
        let result = XCTestLifecycleImpact(in: graph)
        #expect(result.testClasses == [NodeID("Child"), NodeID("Grandchild")])
        #expect(result.dependencies.map(\.source) == [NodeID("Child"), NodeID("Grandchild")])
        #expect(result.dependencies.allSatisfy { $0.target == NodeID("hook") && $0.origin == .automatic })
        #expect(result == XCTestLifecycleImpact(in: graph))
    }
}
