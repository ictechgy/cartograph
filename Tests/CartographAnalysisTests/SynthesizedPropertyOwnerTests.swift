import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("합성 프로퍼티 보존의 소유 타입 조건")
struct SynthesizedPropertyOwnerTests {
    private func analyze(_ snapshot: IndexSnapshot) -> UnusedCodeReport {
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        return ReachabilityAnalyzer(policy: RetentionPolicy()).analyze(graph: graph, snapshot: snapshot)
    }

    private func nested(_ attribute: SymbolAttribute, live: Bool, inExtension: Bool = false) -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Outer", kind: .classType)
        builder.symbol("State", kind: .structType, parent: "Outer", attributes: inExtension ? [] : [attribute])
        builder.symbol("value", kind: .property, parent: "State")
        if inExtension {
            builder.symbol("Ext", kind: .extensionDeclaration, attributes: [attribute])
            builder.reference(from: "Ext", to: "State", kind: .extends)
        }
        if live {
            // 실제 Nested.Type 사용은 타입 이름의 두 구성요소에 compiler 참조를 남긴다.
            builder.reference(from: "App", to: "Outer", kind: .reference)
            builder.reference(from: "App", to: "State", kind: .reference)
        }
        return builder.build()
    }

    @Test("죽은 중첩 Equatable·Hashable 프로퍼티는 바깥 타입을 보존하지 않는다")
    func deadNestedOwnersStayUnreachable() {
        for attribute in [SymbolAttribute.equatable, .hashable] {
            for inExtension in [false, true] {
                let report = analyze(nested(attribute, live: false, inExtension: inExtension))
                #expect(report.unused.map(\.name) == ["Outer"])
                #expect(report.retentions["value"] == nil)
                #expect(report.inheritedRetentions["Outer"] == nil)
            }
        }
    }

    @Test("실제로 도달한 소유 타입의 합성 프로퍼티와 중첩 타입은 보존한다")
    func liveNestedOwnersPreserveSynthesizedProperties() {
        for attribute in [SymbolAttribute.equatable, .hashable] {
            for inExtension in [false, true] {
                let report = analyze(nested(attribute, live: true, inExtension: inExtension))
                #expect(report.unused.isEmpty)
                #expect(report.retentions["value"] == (attribute == .hashable ? .hashableProperty : .equatableProperty))
            }
        }
    }

    @Test("일반 중첩 타입도 같은 죽은 바깥 타입 한 건으로 보고한다")
    func plainNestedOwnerIsNegativeControl() {
        var builder = SnapshotBuilder()
        builder.symbol("Outer", kind: .classType)
        builder.symbol("State", kind: .structType, parent: "Outer")
        builder.symbol("value", kind: .property, parent: "State")
        #expect(analyze(builder.build()).unused.map(\.name) == ["Outer"])
    }

    @Test("명시적 보존과 Codable의 기존 조상 전파는 바꾸지 않는다")
    func unrelatedRetentionReasonsRemainUnchanged() {
        for reason in [RetentionReason.interfaceBuilder, .userConfigured, .codableProperty] {
            #expect(!reason.needsReachableOwner)
            #expect(reason.retainsContainingType)
        }
        var builder = SnapshotBuilder()
        builder.symbol("Outer", kind: .classType)
        builder.symbol("State", kind: .structType, parent: "Outer", attributes: [.equatable])
        builder.symbol("value", kind: .property, parent: "State", attributes: [.interfaceBuilderOutlet])
        #expect(analyze(builder.build()).unused.isEmpty)
    }
}
