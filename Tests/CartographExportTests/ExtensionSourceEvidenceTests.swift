import CartographCore
import CartographExport
import CartographTestSupport
import Foundation
import Testing

@Suite("익스텐션 출처와 그래프 근거의 일치")
struct ExtensionSourceEvidenceTests {
    @Test("같은 원본 USR의 서로 다른 발생을 각 파일에 귀속하고 진짜 역방향은 남긴다")
    func evidenceUsesTheSameOccurrenceSourceAsGraph() throws {
        var builder = SnapshotBuilder()
        builder.symbol("Type", module: "Domain", path: "/p/Domain/Type.swift")
        builder.symbol("Other", module: "Data", path: "/p/Data/Other.swift")
        builder.symbol("Extension", kind: .extensionDeclaration, module: "App", path: "/p/App/Ext.swift")
        builder.reference(from: "Type", to: "Other", path: "/p/App/Ext.swift", line: 5)
        builder.reference(from: "Type", to: "Other", path: "/p/Domain/Type.swift", line: 7)
        builder.reference(from: "Other", to: "Type", path: "/p/Data/Other.swift", line: 8)
        let snapshot = builder.build()
        for level in [GraphLevel.file, .module] {
            let result = GraphBuilder(options: .init(level: level)).buildResult(from: snapshot)
            let text = try JSONGraphEvidenceRenderer().render(result: result, snapshot: snapshot, projectPath: "/p")
            let document = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let evidence = try #require(document["evidence"] as? [[String: Any]])
            #expect(evidence.count == 3)
            let relocated = try #require(evidence.first { ($0["location"] as? [String: Any])?["line"] as? Int == 5 })
            #expect(relocated["source"] as? String == (level == .file ? "/p/App/Ext.swift" : "App"))
            #expect(relocated["sourceUSR"] as? String == "Type")
            let expected = Set(result.graph.edges.map { "\($0.source.rawValue)|\($0.target.rawValue)|\($0.kind.rawValue)" })
            let observed = Set(evidence.map { "\($0["source"]!)|\($0["target"]!)|\($0["kind"]!)" })
            #expect(observed == expected)
        }
    }

    @Test("이전 BuildResult 이니셜라이저를 쓰는 공급자의 의미 출처 계약은 유지한다")
    func previousInitializerKeepsLegacySourceMapping() {
        let result = GraphBuilder.BuildResult(graph: CodeGraph(level: .module, nodes: [], edges: []),
            nodeIDByUSR: ["type": "Domain"])
        let reference = IndexedReference(sourceUSR: "type", targetUSR: "protocol", kind: .conformance,
            location: SourceLocation(path: "/p/App/Ext.swift", line: 1, column: 1))
        #expect(result.sourceNodeID(for: reference) == "Domain")
    }
}
