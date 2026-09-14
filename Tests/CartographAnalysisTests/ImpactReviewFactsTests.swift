import CartographCore
import CartographTestSupport
@testable import CartographAnalysis
import Testing

@Suite("영향 검토 보존 근거")
struct ImpactReviewFactsTests {
    private func review(
        _ snapshot: IndexSnapshot,
        options: RetentionOptions = .default,
        retentions: [ExternalRetention] = []
    ) -> [NodeID: Set<RetentionReason>] {
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        return RetentionPolicy(
            options: options,
            externalRetentions: ExternalRetentionIndex(retentions)
        ).reviewReasons(in: graph, snapshot: snapshot)
    }

    @Test("테스트 근거는 무시 주석에 가려지지 않는다")
    func testAndIgnoreKeepBothFactsVisible() {
        var builder = SnapshotBuilder()
        builder.symbol("Spec", kind: .function, attributes: [.testFunction, .ignoreComment])

        let facts = review(builder.build())[NodeID("Spec")] ?? []
        #expect(facts == [.swiftTesting])
        #expect(!facts.contains(.ignoreComment))
    }

    @Test("진입점은 소스를 읽지 못해도 근거로 남는다")
    func entryPointSurvivesSourceUnavailableMask() {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint, .sourceUnavailable])

        let facts = review(builder.build())[NodeID("App")] ?? []
        #expect(facts == [.entryPoint])
        #expect(!facts.contains(.sourceUnavailable))
    }

    @Test("부모 기반 Codable 근거와 외부 브리지 근거를 함께 보존한다")
    func parentAndExternalBridgeFactsAreCombined() {
        var builder = SnapshotBuilder()
        builder.symbol("User", kind: .structType, attributes: [.codable])
        builder.symbol("User.name", name: "name", kind: .property, parent: "User")
        let retention = ExternalRetention(
            symbol: .init(usr: "User.name", qualifiedName: nil), reason: "bridge", evidence: nil
        )

        let facts = review(builder.build(), retentions: [retention])[NodeID("User.name")] ?? []
        #expect(facts.contains(.codableProperty))
        #expect(facts.contains(.externalBridge))
    }

    @Test("모든 브리지 채널 근거를 입력 순서대로 보존한다")
    func matchingRetentionsKeepsEveryBridgeRecord() {
        var builder = SnapshotBuilder()
        builder.symbol("handler", name: "handle", kind: .method)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let records = [
            ExternalRetention(
                symbol: .init(usr: "handler", qualifiedName: nil), reason: "bridge",
                evidence: .init(channel: "camera", method: "takePhoto", caller: nil)
            ),
            ExternalRetention(
                symbol: .init(usr: "handler", qualifiedName: nil), reason: "bridge",
                evidence: .init(channel: "gallery", method: "pickPhoto", caller: nil)
            ),
            ExternalRetention(
                symbol: .init(usr: nil, qualifiedName: "App.handle"), reason: "bridge",
                evidence: .init(channel: "legacy", method: "legacyPhoto", caller: nil)
            ),
        ]
        let index = ExternalRetentionIndex(records)

        let matches = index.matchingRetentions(for: graph.node(NodeID("handler"))!)
        #expect(matches.map { $0.evidence?.channel } == ["camera", "gallery", "legacy"])
        #expect(matches.map { $0.evidence?.method } == ["takePhoto", "pickPhoto", "legacyPhoto"])
        #expect(review(snapshot, retentions: records)[NodeID("handler")]?.contains(.externalBridge) == true)
    }

    @Test("USR이 다른 이름만 같은 외부 근거는 맞지 않는다")
    func wrongUSRDoesNotMatchByName() {
        var builder = SnapshotBuilder()
        builder.symbol("s:handler", name: "handle", kind: .method)
        let retention = ExternalRetention(
            symbol: .init(usr: "s:other", qualifiedName: "App.handle"), reason: "bridge", evidence: nil
        )
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)

        #expect(
            ExternalRetentionIndex([retention])
                .matchingRetentions(for: graph.node(NodeID("s:handler"))!, names: ["App.handle"])
                .isEmpty
        )
        #expect(!(review(snapshot, retentions: [retention])[NodeID("s:handler")] ?? []).contains(.externalBridge))
    }

    @Test("보존 토글은 영향 검토 근거를 숨기지 않는다")
    func retentionTogglesDoNotHideReviewFacts() {
        var builder = SnapshotBuilder()
        builder.symbol("Tests", kind: .function, attributes: [.unitTest])
        builder.symbol("Preview", kind: .structType, attributes: [.preview])
        builder.symbol("ObjC", kind: .method, attributes: [.objc])
        builder.symbol("Outlet", kind: .property, attributes: [.interfaceBuilderOutlet])
        builder.symbol("Status", kind: .enumType, attributes: [.rawRepresentable, .caseIterable, .codingKey])
        builder.symbol("Status.active", name: "active", kind: .enumCase, parent: "Status")
        builder.symbol("User", kind: .structType, attributes: [.codable])
        builder.symbol("User.name", name: "name", kind: .property, parent: "User")
        builder.symbol("Wrapper", kind: .structType, attributes: [.propertyWrapper])
        builder.symbol("Wrapper.wrappedValue", name: "wrappedValue", kind: .property, parent: "Wrapper")
        builder.symbol("Builder", kind: .structType, attributes: [.resultBuilder])
        builder.symbol("Builder.buildBlock", name: "buildBlock(_:)", kind: .method, parent: "Builder")
        builder.symbol("Managed", kind: .structType, attributes: [.runtimeManaged])
        builder.symbol("Managed.value", name: "value", kind: .property, parent: "Managed")
        builder.symbol("Main", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Main.main", name: "main()", kind: .method, parent: "Main")
        let snapshot = builder.build()
        let options = RetentionOptions(
            retainObjectiveCAccessible: false,
            retainInterfaceBuilder: false,
            retainTests: false,
            retainPreviews: false,
            retainCodableProperties: false,
            retainRawRepresentableEnumCases: false
        )

        let facts = review(snapshot, options: options)
        #expect(facts[NodeID("Tests")] == [.xcTest])
        #expect(facts[NodeID("Preview")] == [.preview])
        #expect(facts[NodeID("ObjC")] == [.objectiveCAccessible])
        #expect(facts[NodeID("Outlet")] == [.interfaceBuilder])
        #expect(facts[NodeID("Status.active")] == [.codingKey, .caseIterableEnumCase, .rawRepresentableEnumCase])
        #expect(facts[NodeID("User.name")] == [.codableProperty])
        #expect(facts[NodeID("Wrapper.wrappedValue")] == [.propertyWrapperRequirement])
        #expect(facts[NodeID("Builder.buildBlock")] == [.resultBuilderRequirement])
        #expect(facts[NodeID("Managed.value")] == [.runtimeManaged])
        #expect(facts[NodeID("Main.main")] == [.entryPoint])
    }

    @Test("외부 오버라이드와 준수 관계를 각각 런타임 근거로 남긴다")
    func externalOverrideAndConformanceFactsAreCollected() {
        var builder = SnapshotBuilder()
        builder.symbol("viewDidLoad", kind: .method, attributes: [.overrideDeclaration])
        builder.symbol("encode", kind: .method)
        builder.reference(from: "viewDidLoad", to: "c:UIKit.viewDidLoad", kind: .overrides)
        builder.reference(from: "encode", to: "s:Encodable.encode", kind: .conformance)
        let facts = review(builder.build())

        #expect(facts[NodeID("viewDidLoad")] == [.externalOverride])
        #expect(facts[NodeID("encode")] == [.externalConformance])
    }

    @Test("다중 근거를 추가해도 대표 보존 사유의 우선순위는 유지된다")
    func primaryRetentionReasonRemainsStable() {
        var builder = SnapshotBuilder()
        builder.symbol("Status", kind: .enumType, attributes: [.rawRepresentable, .caseIterable, .codingKey])
        builder.symbol("Status.active", name: "active", kind: .enumCase, parent: "Status")
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)

        #expect(RetentionPolicy().retainedNodes(in: graph, snapshot: snapshot)[NodeID("Status.active")] == .codingKey)
        var disabled = RetentionOptions.default
        disabled.retainRawRepresentableEnumCases = false
        #expect(RetentionPolicy(options: disabled).retainedNodes(in: graph, snapshot: snapshot)[NodeID("Status.active")] == .codingKey)
    }
}
