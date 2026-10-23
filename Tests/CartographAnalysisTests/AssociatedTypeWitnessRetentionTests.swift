import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("외부 associatedtype의 compiler 증인 별칭")
struct AssociatedTypeWitnessRetentionTests {
    private func fixture(
        live: Bool = true, nested: Bool = false, inExtension: Bool = false,
        origin: ReferenceOrigin = .compiler, targetKind: SymbolKind? = .associatedType,
        relationKind: EdgeKind = .overrides, withOwner: Bool = true
    ) -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        if nested { builder.symbol("Namespace", kind: .enumType) }
        if withOwner {
            builder.symbol("Forwarder", kind: .structType, parent: nested ? "Namespace" : nil)
            builder.reference(from: "Forwarder", to: "external.Publisher", kind: .conformance,
                targetKind: .protocolType, origin: .compiler)
            if inExtension {
                builder.symbol("Extension", kind: .extensionDeclaration)
                builder.reference(from: "Extension", to: "Forwarder", kind: .extends, origin: .compiler)
            }
            if live {
                builder.reference(from: "App", to: "Forwarder", origin: .compiler)
                if nested { builder.reference(from: "App", to: "Namespace", origin: .compiler) }
            }
        }
        builder.symbol("Output", kind: .typeAlias, parent: withOwner ? (inExtension ? "Extension" : "Forwarder") : nil)
        builder.reference(from: "Output", to: "external.Publisher.Output", kind: relationKind,
            targetKind: targetKind, origin: origin)
        builder.symbol("Unrelated", kind: .structType)
        builder.symbol("Unrelated.Output", name: "Output", kind: .typeAlias, parent: "Unrelated")
        builder.reference(from: "App", to: "Unrelated", origin: .compiler)
        return builder.build()
    }

    private func analyze(_ snapshot: IndexSnapshot) -> (CodeGraph, UnusedCodeReport) {
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        return (graph, ReachabilityAnalyzer(policy: RetentionPolicy()).analyze(graph: graph, snapshot: snapshot))
    }

    @Test("살아 있는 최상위·중첩 타입의 실제 증인만 보존하고 동명 별칭은 보고한다")
    func liveCompilerWitnessIsConditionalMember() {
        for nested in [false, true] {
            let snapshot = fixture(nested: nested)
            let (graph, report) = analyze(snapshot)
            #expect(report.unused.map(\.id) == [NodeID("Unrelated.Output")])
            #expect(report.retentions["Output"] == .externalConformance)
            #expect(report.explain("Output", in: graph) == .retained(.externalConformance))
            #expect(report.inheritedRetentions["Forwarder"] == nil)
            #expect(RetentionPolicy().reviewReasons(in: graph, snapshot: snapshot)["Output"] == [.externalConformance])
            #expect(RetentionPolicy().reviewReasons(in: graph, snapshot: snapshot)["Unrelated.Output"] == nil)
        }
    }

    @Test("증인 별칭 때문에 사용하지 않는 소유 타입이나 바깥 타입을 되살리지 않는다")
    func deadOwnerAndNamespaceStayDead() {
        for nested in [false, true] {
            let (graph, report) = analyze(fixture(live: false, nested: nested))
            #expect(report.retentions["Output"] == nil)
            #expect(report.explain("Output", in: graph) == .unreachable)
            #expect(report.explain("Forwarder", in: graph) == .unreachable)
            if nested { #expect(report.explain("Namespace", in: graph) == .unreachable) }
            #expect(report.inheritedRetentions["Forwarder"] == nil)
        }
    }

    @Test("익스텐션 증인도 실제 확장 대상이 살아 있어야 보존한다")
    func extensionOwnerGateIsPreserved() {
        for live in [false, true] {
            let (graph, report) = analyze(fixture(live: live, inExtension: true))
            #expect(report.retentions["Output"] == (live ? .externalConformance : nil))
            #expect(report.explain("Forwarder", in: graph) != .unreachable || !live)
            #expect(report.inheritedRetentions["Forwarder"] == nil)
        }
    }

    @Test("compiler 출처와 associatedtype 대상이 없는 관계를 증인으로 승격하지 않는다")
    func incompleteOrInferredEvidenceDoesNotBecomeWitness() {
        let snapshots = [
            fixture(origin: .unknown), fixture(origin: .inferred),
            fixture(targetKind: nil), fixture(targetKind: .typeAlias),
            fixture(relationKind: .conformance), fixture(relationKind: .reference),
        ]
        for snapshot in snapshots {
            let (graph, report) = analyze(snapshot)
            #expect(report.retentions["Output"] == nil)
            #expect(report.explain("Output", in: graph) == .unreachable)
            #expect(RetentionPolicy().reviewReasons(in: graph, snapshot: snapshot)["Output"] == nil)
        }
    }

    @Test("잘린 소유자 관계를 무조건 보존 뿌리로 바꾸지 않는다")
    func missingOwnerDoesNotBecomeUnconditionalRoot() {
        let (graph, report) = analyze(fixture(withOwner: false))
        #expect(report.retentions["Output"] == nil)
        #expect(report.explain("Output", in: graph) == .unreachable)
    }
}
