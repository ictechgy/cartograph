import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("보존 규칙")
struct RetentionPolicyTests {
    private func reasons(
        _ snapshot: IndexSnapshot,
        options: RetentionOptions = .default
    ) -> [NodeID: RetentionReason] {
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        return RetentionPolicy(options: options).retainedNodes(in: graph, snapshot: snapshot)
    }

    @Test("진입점은 항상 보존된다")
    func entryPointIsAlwaysRetained() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        #expect(reasons(builder.build())["App"] == .entryPoint)
    }

    @Test("테스트 선언은 기본으로 보존되고 끌 수 있다")
    func testDeclarationsAreRetainedByDefault() {
        var builder = SnapshotBuilder()
        builder.symbol("SpecCase", kind: .classType, attributes: [.unitTest])
        builder.symbol("suite", kind: .structType, attributes: [.testSuite])
        builder.symbol("check", kind: .function, attributes: [.testFunction])
        let snapshot = builder.build()

        let retained = reasons(snapshot)
        #expect(retained["SpecCase"] == .xcTest)
        #expect(retained["suite"] == .swiftTesting)
        #expect(retained["check"] == .swiftTesting)

        var disabled = RetentionOptions.default
        disabled.retainTests = false
        #expect(reasons(snapshot, options: disabled).isEmpty)
    }

    @Test("public 보존은 기본으로 꺼져 있다")
    func publicRetentionIsOptIn() {
        var builder = SnapshotBuilder()
        builder.symbol("API", kind: .structType, accessibility: .publicLevel)
        builder.symbol("Internal", kind: .structType, accessibility: .internalLevel)
        let snapshot = builder.build()

        #expect(reasons(snapshot).isEmpty)

        var enabled = RetentionOptions.default
        enabled.retainPublic = true
        let retained = reasons(snapshot, options: enabled)
        #expect(retained["API"] == .publicAPI)
        #expect(retained["Internal"] == nil)
    }

    @Test("Objective-C 노출은 기본으로 보존된다")
    func objectiveCAccessibleIsRetainedByDefault() {
        // Periphery 는 기본값이 꺼짐이라 혼합 언어 프로젝트에서 거짓 양성이 잦았다.
        // UIKit 앱은 셀렉터와 KVO 사용이 흔하므로 기본값을 켬으로 둔다.
        var builder = SnapshotBuilder()
        builder.symbol("Annotated", kind: .method, attributes: [.objc])
        builder.symbol("c:objc(cs)Legacy", name: "Legacy", kind: .classType)
        let snapshot = builder.build()

        let retained = reasons(snapshot)
        #expect(retained["Annotated"] == .objectiveCAccessible)
        #expect(retained["c:objc(cs)Legacy"] == .objectiveCAccessible)

        var disabled = RetentionOptions.default
        disabled.retainObjectiveCAccessible = false
        #expect(reasons(snapshot, options: disabled).isEmpty)
    }

    @Test("Interface Builder 연결 후보를 보존한다")
    func interfaceBuilderMembersAreRetained() {
        var builder = SnapshotBuilder()
        builder.symbol("outlet", kind: .property, attributes: [.interfaceBuilderOutlet])
        builder.symbol("action", kind: .method, attributes: [.interfaceBuilderAction])
        builder.symbol("inspect", kind: .property, attributes: [.interfaceBuilderInspectable])
        let snapshot = builder.build()
        let retained = reasons(snapshot)
        #expect(retained.count == 3)
        #expect(retained.values.allSatisfy { $0 == .interfaceBuilder })
    }

    @Test("원시값 열거형의 케이스는 보존하고 일반 열거형은 보고한다")
    func rawRepresentableEnumCasesAreRetained() {
        var builder = SnapshotBuilder()
        builder.symbol("Status", kind: .enumType, attributes: [.rawRepresentable])
        builder.symbol("Status.active", name: "active", kind: .enumCase, parent: "Status")
        builder.symbol("Plain", kind: .enumType)
        builder.symbol("Plain.one", name: "one", kind: .enumCase, parent: "Plain")
        let snapshot = builder.build()

        let retained = reasons(snapshot)
        #expect(retained["Status.active"] == .rawRepresentableEnumCase)
        #expect(retained["Plain.one"] == nil)

        var disabled = RetentionOptions.default
        disabled.retainRawRepresentableEnumCases = false
        #expect(reasons(snapshot, options: disabled)["Status.active"] == nil)
    }

    @Test("CodingKey 케이스는 항상 보존된다")
    func codingKeyCasesAreRetained() {
        var builder = SnapshotBuilder()
        builder.symbol("CodingKeys", kind: .enumType, attributes: [.codingKey, .rawRepresentable])
        builder.symbol("CodingKeys.name", name: "name", kind: .enumCase, parent: "CodingKeys")
        #expect(reasons(builder.build())["CodingKeys.name"] == .codingKey)
    }

    @Test("프로퍼티 래퍼와 결과 빌더의 규약 멤버를 보존한다")
    func propertyWrapperAndResultBuilderMembers() {
        var builder = SnapshotBuilder()
        builder.symbol("Wrapper", kind: .structType, attributes: [.propertyWrapper])
        builder.symbol("Wrapper.wrappedValue", name: "wrappedValue", kind: .property, parent: "Wrapper")
        builder.symbol("Wrapper.projectedValue", name: "projectedValue", kind: .property, parent: "Wrapper")
        builder.symbol("Wrapper.helper", name: "helper", kind: .method, parent: "Wrapper")
        builder.symbol("Builder", kind: .enumType, attributes: [.resultBuilder])
        builder.symbol("Builder.buildBlock", name: "buildBlock", kind: .method, parent: "Builder")

        let retained = reasons(builder.build())
        #expect(retained["Wrapper.wrappedValue"] == .propertyWrapperRequirement)
        #expect(retained["Wrapper.projectedValue"] == .propertyWrapperRequirement)
        #expect(retained["Wrapper.helper"] == nil)
        #expect(retained["Builder.buildBlock"] == .resultBuilderRequirement)
    }

    @Test("Codable 타입의 저장 프로퍼티를 보존한다")
    func codablePropertiesAreRetained() {
        var builder = SnapshotBuilder()
        builder.symbol("User", kind: .structType, attributes: [.codable])
        builder.symbol("User.name", name: "name", kind: .property, parent: "User")
        builder.symbol("User.compute", name: "compute", kind: .method, parent: "User")
        let snapshot = builder.build()

        #expect(reasons(snapshot)["User.name"] == .codableProperty)
        #expect(reasons(snapshot)["User.compute"] == nil)

        var disabled = RetentionOptions.default
        disabled.retainCodableProperties = false
        #expect(reasons(snapshot, options: disabled)["User.name"] == nil)
    }

    @Test("외부 선언 오버라이드와 외부 프로토콜 구현을 보존한다")
    func externalRelationsAreRetained() {
        // 그래프는 양쪽 끝이 모두 있는 간선만 남기므로, 외부로 향하는 관계는
        // 원본 스냅샷에서 읽어야 한다. 이 규칙이 없으면 viewDidLoad 가
        // 전부 미사용으로 보고된다.
        var builder = SnapshotBuilder()
        builder.symbol("viewDidLoad", kind: .method, attributes: [.overrideDeclaration])
        builder.symbol("Model", kind: .structType)
        builder.reference(from: "viewDidLoad", to: "c:objc(cs)UIViewController(im)viewDidLoad", kind: .overrides)
        builder.reference(from: "Model", to: "s:SE", kind: .conformance)

        let retained = reasons(builder.build())
        #expect(retained["viewDidLoad"] == .externalOverride)
        #expect(retained["Model"] == .externalConformance)
    }

    @Test("내부 선언을 오버라이드하는 것만으로는 보존되지 않는다")
    func internalOverridesAreNotRetained() {
        var builder = SnapshotBuilder()
        builder.symbol("Base.run", name: "run", kind: .method)
        builder.symbol("Derived.run", name: "run", kind: .method, attributes: [.overrideDeclaration])
        builder.reference(from: "Derived.run", to: "Base.run", kind: .overrides)
        #expect(reasons(builder.build()).isEmpty)
    }

    @Test("동적 디스패치 관련 선언을 보존한다")
    func dynamicDeclarationsAreRetained() {
        var builder = SnapshotBuilder()
        builder.symbol("subscriptDynamic", kind: .subscriptDeclaration, attributes: [.dynamicMemberLookup])
        builder.symbol("replaced", kind: .function, attributes: [.dynamicReplacement])
        builder.symbol("dyn", kind: .method, attributes: [.dynamicDispatch])
        let retained = reasons(builder.build())
        #expect(retained.count == 3)
        #expect(retained.values.allSatisfy { $0 == .dynamicDispatch })
    }

    @Test("무시 주석이 가장 우선한다")
    func ignoreCommentWinsOverEverything() {
        var builder = SnapshotBuilder()
        builder.symbol("Thing", kind: .structType, attributes: [.ignoreComment, .entryPoint])
        #expect(reasons(builder.build())["Thing"] == .ignoreComment)
    }

    @Test("설정의 이름/파일 보존 목록이 적용된다")
    func userConfiguredRetention() {
        var builder = SnapshotBuilder()
        builder.symbol("Container", kind: .classType, path: "/p/DI/Container.swift")
        builder.symbol("Other", kind: .structType, path: "/p/App/Other.swift")

        var byName = RetentionOptions.default
        byName.retainedNames = ["Contain*"]
        #expect(reasons(builder.build(), options: byName)["Container"] == .userConfigured)

        var byFile = RetentionOptions.default
        byFile.retainedFiles = ["**/DI/**"]
        let retained = reasons(builder.build(), options: byFile)
        #expect(retained["Container"] == .userConfigured)
        #expect(retained["Other"] == nil)
    }

    @Test("SwiftUI 프리뷰는 기본으로 보존되고 끌 수 있다")
    func previewRetention() {
        var builder = SnapshotBuilder()
        builder.symbol("HomePreview", kind: .structType, attributes: [.preview])
        let snapshot = builder.build()
        #expect(reasons(snapshot)["HomePreview"] == .preview)

        var disabled = RetentionOptions.default
        disabled.retainPreviews = false
        #expect(reasons(snapshot, options: disabled)["HomePreview"] == nil)
    }

    @Test("모든 보존 근거는 설명 문장을 가진다")
    func allReasonsHaveExplanations() {
        for reason in RetentionReason.allCases {
            #expect(!reason.explanation.isEmpty)
        }
    }
}
