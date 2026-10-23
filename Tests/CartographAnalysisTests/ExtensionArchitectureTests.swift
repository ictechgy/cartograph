import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("익스텐션 출처 수정의 순환과 규칙 대조군")
struct ExtensionArchitectureTests {
    @Test("가짜 도메인 역방향만 없어지고 실제 프레젠테이션 데이터 위반은 남는다")
    func realViolationSurvivesArchitecturalCorrection() {
        var builder = SnapshotBuilder()
        builder.symbol("Domain", module: "Domain", path: "/p/Domain.swift")
        builder.symbol("Protocol", kind: .protocolType, module: "Presentation", path: "/p/Extension.swift")
        builder.symbol("Extension", kind: .extensionDeclaration, module: "Presentation", path: "/p/Extension.swift")
        builder.symbol("Data", module: "Data", path: "/p/Data.swift")
        builder.reference(from: "Extension", to: "Domain", kind: .extends, path: "/p/Extension.swift")
        builder.reference(from: "Domain", to: "Protocol", kind: .conformance, path: "/p/Extension.swift")
        builder.reference(from: "Domain", to: "Data", path: "/p/Extension.swift")
        let graph = GraphBuilder().build(from: builder.build())
        #expect(CycleDetector().detectCycles(in: graph).isEmpty)
        let violations = LayerRuleEvaluator(layers: [
            LayerDefinition(name: "Presentation", patterns: ["Presentation"]),
            LayerDefinition(name: "Data", patterns: ["Data"]),
        ], rules: [LayerRule(from: "Presentation", deny: ["Data"])]).evaluate(graph: graph)
        #expect(violations.count == 1)
        #expect(violations.first?.edge.source == "Presentation")
        #expect(violations.first?.edge.target == "Data")
    }

    @Test("실제 파일과 타입의 상호 참조 순환은 유지한다")
    func actualCyclesRemainVisible() {
        var builder = SnapshotBuilder()
        builder.symbol("Left", kind: .classType, path: "/p/Left.swift")
        builder.symbol("Right", kind: .classType, path: "/p/Right.swift")
        builder.reference(from: "Left", to: "Right", path: "/p/Left.swift")
        builder.reference(from: "Right", to: "Left", path: "/p/Right.swift")
        for level in [GraphLevel.file, .type] {
            let graph = GraphBuilder(options: .init(level: level)).build(from: builder.build())
            #expect(CycleDetector().detectCycles(in: graph).count == 1)
        }
    }
}
