@testable import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("xcodebuild -only-testing 식별자")
struct XCTestIdentifierTests {
    /// 최상위 XCTest 클래스 `LoginTests` 와 그 테스트 메서드 하나.
    private func builder() -> SnapshotBuilder {
        var builder = SnapshotBuilder(path: "/p/Tests/LoginTests.swift")
        builder.symbol("LoginTests", name: "LoginTests", kind: .classType, module: "AppTests",
            attributes: [.unitTest])
        builder.symbol("LoginTests.testLogin", name: "testLogin()", kind: .method, module: "AppTests",
            parent: "LoginTests", attributes: [.unitTest])
        return builder
    }

    private func identifier(_ id: NodeID, _ builder: SnapshotBuilder, canProve: Bool = true) -> String? {
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: builder.build())
        return XCTestIdentifier.identifier(for: id, in: graph, canProveClassHierarchy: canProve)
    }

    @Test("최상위 클래스의 테스트 메서드는 Module/Class/method 로 좁힌다")
    func narrowsTopLevelTestMethod() {
        #expect(identifier("LoginTests.testLogin", builder()) == "AppTests/LoginTests/testLogin")
        #expect(identifier("LoginTests", builder()) == "AppTests/LoginTests")
    }

    @Test("익스텐션에 둔 테스트 메서드도 확장한 클래스 이름으로 좁힌다")
    func narrowsTestMethodDeclaredInExtension() {
        var builder = builder()
        builder.symbol("LoginTestsExtension", name: "LoginTests", kind: .extensionDeclaration, module: "AppTests")
        builder.reference(from: "LoginTestsExtension", to: "LoginTests", kind: .extends)
        builder.symbol("LoginTests.testLogout", name: "testLogout()", kind: .method, module: "AppTests",
            parent: "LoginTestsExtension", attributes: [.unitTest])
        #expect(identifier("LoginTests.testLogout", builder) == "AppTests/LoginTests/testLogout")
    }

    @Test("하위 클래스가 있으면 상속된 실행이 빠지지 않도록 좁히지 않는다")
    func refusesClassWithSubclass() {
        var builder = builder()
        builder.symbol("AdminLoginTests", kind: .classType, module: "AppTests", attributes: [.unitTest])
        builder.reference(from: "AdminLoginTests", to: "LoginTests", kind: .inheritance)
        #expect(identifier("LoginTests.testLogin", builder) == nil)
        #expect(identifier("LoginTests", builder) == nil)
        #expect(identifier("AdminLoginTests", builder) == "AppTests/AdminLoginTests")
    }

    @Test("중첩 클래스는 런타임 이름을 증명할 수 없어 좁히지 않는다")
    func refusesNestedClass() {
        var builder = SnapshotBuilder(path: "/p/Tests/Outer.swift")
        builder.symbol("Outer", kind: .enumType, module: "AppTests")
        builder.symbol("Outer.Inner", name: "Inner", kind: .classType, module: "AppTests", parent: "Outer",
            attributes: [.unitTest])
        builder.symbol("Outer.Inner.testA", name: "testA()", kind: .method, module: "AppTests",
            parent: "Outer.Inner", attributes: [.unitTest])
        #expect(identifier("Outer.Inner.testA", builder) == nil)
        #expect(identifier("Outer.Inner", builder) == nil)
    }

    @Test("@objc 로 런타임 이름을 바꾼 클래스는 좁히지 않고 이름이 같으면 좁힌다")
    func refusesObjectiveCRenamedClass() {
        var renamed = SnapshotBuilder(path: "/p/Tests/Renamed.swift")
        renamed.symbol("c:@M@AppTests@objc(cs)SuiteRenamedTests", name: "RenamedTests", kind: .classType,
            module: "AppTests", attributes: [.unitTest])
        renamed.symbol("c:@M@AppTests@objc(cs)SuiteRenamedTests(im)testA", name: "testA()", kind: .method,
            module: "AppTests", parent: "c:@M@AppTests@objc(cs)SuiteRenamedTests", attributes: [.unitTest])
        #expect(identifier("c:@M@AppTests@objc(cs)SuiteRenamedTests(im)testA", renamed) == nil)

        var plain = SnapshotBuilder(path: "/p/Tests/Plain.swift")
        plain.symbol("c:@M@AppTests@objc(cs)PlainTests", name: "PlainTests", kind: .classType,
            module: "AppTests", attributes: [.unitTest])
        plain.symbol("c:@M@AppTests@objc(cs)PlainTests(im)testA", name: "testA()", kind: .method,
            module: "AppTests", parent: "c:@M@AppTests@objc(cs)PlainTests", attributes: [.unitTest])
        #expect(identifier("c:@M@AppTests@objc(cs)PlainTests(im)testA", plain) == "AppTests/PlainTests/testA")
        #expect(XCTestIdentifier.objectiveCClassName(usr: "c:@M@App@objc(cs)Name(im)testA") == "Name")
        #expect(XCTestIdentifier.objectiveCClassName(usr: "s:3App5NameC") == nil)
    }

    @Test("XCTest 표식이 없거나 실행 형태가 아닌 선언은 좁히지 않는다")
    func refusesNonXCTestShapes() {
        var builder = builder()
        // Swift Testing 함수는 인덱스의 unitTest 표식이 없다.
        builder.symbol("LoginTests.swiftTesting", name: "signsIn()", kind: .method, module: "AppTests",
            parent: "LoginTests")
        builder.symbol("LoginTests.helper", name: "testHelper(_:)", kind: .method, module: "AppTests",
            parent: "LoginTests", attributes: [.unitTest])
        builder.symbol("LoginTests.check", name: "check()", kind: .method, module: "AppTests",
            parent: "LoginTests", attributes: [.unitTest])
        #expect(identifier("LoginTests.swiftTesting", builder) == nil)
        #expect(identifier("LoginTests.helper", builder) == nil)
        #expect(identifier("LoginTests.check", builder) == nil)
    }

    @Test("클래스 계층을 증명할 수 없는 그래프에서는 좁히지 않는다")
    func refusesWithoutProvableHierarchy() {
        #expect(identifier("LoginTests.testLogin", builder(), canProve: false) == nil)
        #expect(XCTestIdentifier.canProveClassHierarchy(edgeKinds: [], narrowsPaths: false))
        #expect(XCTestIdentifier.canProveClassHierarchy(edgeKinds: [.call, .member, .inheritance], narrowsPaths: false))
        #expect(!XCTestIdentifier.canProveClassHierarchy(edgeKinds: [.call, .member], narrowsPaths: false))
        #expect(!XCTestIdentifier.canProveClassHierarchy(edgeKinds: [], narrowsPaths: true))
    }
}
