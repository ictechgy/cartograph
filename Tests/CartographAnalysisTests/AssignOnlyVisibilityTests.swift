import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("읽기 경로를 확인할 수 없는 저장소의 assign-only 판정")
struct AssignOnlyVisibilityTests {
    @Test("외부 요구사항을 구현한 프로퍼티는 대입만 보여도 보고하지 않는다", arguments: [false, true])
    func excludesExternalWitnesses(hasOverrideModifier: Bool) {
        var builder = liveProperties(attributes: hasOverrideModifier ? [.overrideDeclaration] : [])
        builder.reference(from: "Box.value", to: "external.value", kind: .overrides)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let report = ReachabilityAnalyzer().analyze(graph: graph, snapshot: snapshot)

        #expect(!graph.contains("external.value"))
        #expect(graph.outgoingEdges(from: "Box.value").allSatisfy { $0.kind != .overrides })
        #expect(report.retentions["Box.value"] == (
            hasOverrideModifier ? .externalOverride : .externalConformance
        ))
        #expect(report.assignOnly.map(\.id) == ["Box.plain"])
        #expect(report.unused.isEmpty)
    }

    @Test("필터된 내부 요구사항의 읽기도 원본 관계로 보수적으로 처리한다")
    func excludesWitnessOfFilteredRequirement() {
        var builder = liveProperties()
        addRequirement(to: &builder)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(
            level: .symbol,
            pathFilter: PathFilter(exclude: ["Contract.swift"], basePath: "/project")
        )).build(from: snapshot)
        let report = ReachabilityAnalyzer().analyze(graph: graph, snapshot: snapshot)

        #expect(snapshot.symbols.contains { $0.usr == "P.value" })
        #expect(!graph.contains("P.value"))
        #expect(report.retentions["Box.value"] == .externalConformance)
        #expect(report.assignOnly.map(\.id) == ["Box.plain"])
        #expect(report.unused.isEmpty)
    }

    @Test("오버라이드 간선을 제외해도 원본 증인 관계를 잃지 않는다")
    func excludesWitnessWhenRelationKindIsFiltered() {
        var builder = liveProperties()
        addRequirement(to: &builder)
        builder.reference(from: "Entry", to: "P", kind: .reference)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(
            level: .symbol, edgeKinds: [.member, .reference, .call]
        )).build(from: snapshot)
        let report = ReachabilityAnalyzer().analyze(graph: graph, snapshot: snapshot)

        #expect(graph.contains("P.value"))
        #expect(graph.outgoingEdges(from: "Box.value").allSatisfy { $0.kind != .overrides })
        #expect(report.retentions["Box.value"] == .externalConformance)
        #expect(report.assignOnly.map(\.id) == ["Box.plain"])
    }

    @Test("소스를 읽지 못한 프로퍼티의 보존 표식은 assign-only에서도 존중한다")
    func excludesPropertiesWithUnavailableSource() {
        let snapshot = liveProperties(attributes: [.sourceUnavailable]).build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let report = ReachabilityAnalyzer().analyze(graph: graph, snapshot: snapshot)

        #expect(snapshot.propertyAccesses["Box.value"]?.isAssignOnly == true)
        #expect(report.retentions["Box.value"] == .sourceUnavailable)
        #expect(report.assignOnly.map(\.id) == ["Box.plain"])
        #expect(report.unused.isEmpty)
    }

    @Test("새로운 제외 근거가 없으면 일반 대입 전용 프로퍼티는 그대로 보고한다")
    func ordinaryWriteOnlyPropertiesRemainReportable() {
        let snapshot = liveProperties().build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let report = ReachabilityAnalyzer().analyze(graph: graph, snapshot: snapshot)

        #expect(report.assignOnly.map(\.id) == ["Box.plain", "Box.value"])
        #expect(report.unused.isEmpty)
    }


    @Test("동명 타입의 다른 모듈 프로퍼티까지 외부 증인이나 불완전 소스로 묶지 않는다",
          arguments: [false, true])
    func preservesSameNamedPropertyInAnotherModule(sourceUnavailable: Bool) throws {
        let left = "s:4Left3BoxV5valueSSvp"
        let right = "s:5Right3BoxV5valueSSvp"
        var builder = SnapshotBuilder(module: "Main")
        builder.symbol("Entry", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Left.Box", name: "Box", kind: .structType, module: "Left",
                       path: "/project/Left/Box.swift")
        builder.symbol("Right.Box", name: "Box", kind: .structType, module: "Right",
                       path: "/project/Right/Box.swift")
        builder.symbol(left, name: "value", kind: .property, module: "Left",
                       path: "/project/Left/Box.swift", parent: "Left.Box",
                       attributes: sourceUnavailable ? [.sourceUnavailable] : [])
        builder.symbol(right, name: "value", kind: .property, module: "Right",
                       path: "/project/Right/Box.swift", parent: "Right.Box")
        for target in ["Left.Box", "Right.Box", left, right] {
            builder.reference(from: "Entry", to: target)
        }
        if !sourceUnavailable {
            builder.reference(from: left, to: "external.requirement.value", kind: .overrides)
        }
        builder.propertyAccess(left, write: true)
        builder.propertyAccess(right, write: true)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let leftNode = try #require(graph.node(NodeID(left)))
        let rightNode = try #require(graph.node(NodeID(right)))
        #expect(leftNode.name == rightNode.name)
        #expect(leftNode.module == "Left")
        #expect(rightNode.module == "Right")
        #expect(leftNode.id != rightNode.id)
        #expect(snapshot.references.allSatisfy {
            $0.kind != .overrides || $0.sourceUSR == left
        })

        let report = ReachabilityAnalyzer().analyze(graph: graph, snapshot: snapshot)
        #expect(report.retentions[NodeID(left)] == (
            sourceUnavailable ? .sourceUnavailable : .externalConformance
        ))
        #expect(report.assignOnly == [rightNode])
        #expect(report.unused.isEmpty)
    }

    private func liveProperties(attributes: Set<SymbolAttribute> = []) -> SnapshotBuilder {
        var builder = SnapshotBuilder()
        builder.symbol("Entry", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Box", kind: .structType)
        builder.symbol("Box.value", name: "value", kind: .property, parent: "Box", attributes: attributes)
        builder.symbol("Box.plain", name: "plain", kind: .property, parent: "Box")
        builder.reference(from: "Entry", to: "Box", kind: .reference)
        builder.reference(from: "Entry", to: "Box.value", kind: .reference)
        builder.reference(from: "Entry", to: "Box.plain", kind: .reference)
        builder.propertyAccess("Box.value", write: true)
        builder.propertyAccess("Box.plain", write: true)
        return builder
    }

    private func addRequirement(to builder: inout SnapshotBuilder) {
        builder.symbol("P", kind: .protocolType, path: "/project/Contract.swift")
        builder.symbol("P.value", kind: .property, path: "/project/Contract.swift", parent: "P")
        builder.reference(from: "Box.value", to: "P.value", kind: .overrides)
    }
}
