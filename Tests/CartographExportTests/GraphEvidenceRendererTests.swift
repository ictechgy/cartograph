import CartographCore
@testable import CartographExport
import Foundation
import Testing

@Suite("그래프 occurrence 근거 JSON")
struct GraphEvidenceRendererTests {
    @Test("200건을 넘는 multi-unit occurrence와 별도 import·inventory 사실을 빠짐없이 보존한다")
    func preservesEveryOccurrenceAndSeparateFacts() throws {
        let symbols = [
            IndexedSymbol(usr: "s:A", name: "A", kind: .classType, module: "App",
                location: .init(path: "/p/Sources/A.swift", line: 1, column: 1)),
            IndexedSymbol(usr: "s:B", name: "B", kind: .classType, module: "Domain",
                location: .init(path: "/p/Sources/B.swift", line: 1, column: 1)),
        ]
        var references = (1...250).map { line in
            IndexedReference(sourceUSR: "s:A", targetUSR: "s:B", kind: .call,
                location: .init(path: "/p/Sources/A.swift", line: line, column: 7),
                origin: .compiler, position: .body)
        }
        references.append(references[4])
        references.append(IndexedReference(sourceUSR: "s:A", targetUSR: "s:B", kind: .call,
            location: .init(path: "/generated/A.swift", line: 1, column: 1), origin: .inferred))
        let snapshot = IndexSnapshot(
            symbols: symbols,
            references: references,
            indexedFileDates: [
                "/p/Sources/A.swift": Date(timeIntervalSince1970: 1),
                "/generated/A.swift": Date(timeIntervalSince1970: 2),
            ],
            imports: [
                IndexedImport(modulePath: ["Foundation"], isConditional: true,
                    location: .init(path: "/p/Sources/A.swift", line: 1, column: 1)),
            ]
        )
        let result = GraphBuilder(options: .init(level: .module)).buildResult(from: snapshot)
        let output = try JSONGraphEvidenceRenderer(prettyPrinted: false).render(
            result: result,
            snapshot: snapshot,
            projectPath: "/p",
            sourceFiles: ["/p/Sources/A.swift", "/p/Sources/B.swift", "/generated/A.swift"]
        )
        let document = try object(output)
        let evidence = try #require(document["evidence"] as? [[String: Any]])
        #expect(document["evidenceCount"] as? Int == 252)
        #expect(evidence.count == 252)
        #expect(evidence.allSatisfy { $0["source"] as? String == "App" })
        #expect(evidence.allSatisfy { $0["target"] as? String == "Domain" })
        #expect(evidence.filter { ($0["location"] as? [String: Any])?["line"] as? Int == 5 }.count == 2)
        #expect(document["unlocatedEvidenceCount"] as? Int == 1)

        let inventory = try #require(document["inventory"] as? [String: Any])
        let source = try #require(inventory["source"] as? [String: Any])
        #expect(source["totalCount"] as? Int == 3)
        #expect(source["files"] as? [String] == ["Sources/A.swift", "Sources/B.swift"])
        #expect(source["omittedCount"] as? Int == 1)
        let indexed = try #require(inventory["index"] as? [String: Any])
        #expect(indexed["totalCount"] as? Int == 2)
        #expect(indexed["files"] as? [String] == ["Sources/A.swift"])
        #expect(indexed["omittedCount"] as? Int == 1)

        let imports = try #require(document["moduleImports"] as? [[String: Any]])
        #expect(document["moduleImportCount"] as? Int == 1)
        #expect(imports.first?["modulePath"] as? [String] == ["Foundation"])
        #expect((imports.first?["location"] as? [String: Any])?["path"] as? String == "Sources/A.swift")
        #expect(imports.first?["isConditional"] as? Bool == true)
        let limitations = try #require(document["limitations"] as? [String])
        #expect(limitations == [
            "module-import-topology: 1 import declaration(s) are exported as separate facts; "
                + "the graph has no importDeclaration edges, so imports are not represented as topology"
        ])
    }

    @Test("final graph의 roll-up과 필터를 재사용하고 synthetic edge의 위치를 만들지 않는다")
    func reusesFinalGraphMappingWithoutSyntheticEvidence() throws {
        let symbols = [
            IndexedSymbol(usr: "s:P", name: "P", kind: .structType, module: "App",
                location: .init(path: "/p/P.swift", line: 1, column: 1)),
            IndexedSymbol(usr: "s:P.f", name: "f()", kind: .method, module: "App",
                location: .init(path: "/p/P.swift", line: 2, column: 5), parentUSR: "s:P"),
            IndexedSymbol(usr: "s:Q", name: "Q", kind: .classType, module: "Domain",
                location: .init(path: "/p/Q.swift", line: 1, column: 1)),
        ]
        let snapshot = IndexSnapshot(symbols: symbols, references: [
            IndexedReference(sourceUSR: "s:P.f", targetUSR: "s:Q", kind: .call,
                location: .init(path: "/p/P.swift", line: 3, column: 9)),
            IndexedReference(sourceUSR: "s:P.f", targetUSR: "s:Q", kind: .reference,
                location: .init(path: "/p/P.swift", line: 4, column: 9)),
        ])
        let result = GraphBuilder(options: .init(level: .type, edgeKinds: [.call])).buildResult(from: snapshot)
        let renderer = JSONGraphEvidenceRenderer(prettyPrinted: false)
        let first = try renderer.render(result: result, snapshot: snapshot, projectPath: "/p")
        let second = try renderer.render(result: result, snapshot: snapshot, projectPath: "/p")
        #expect(first == second)
        let evidence = try #require(try object(first)["evidence"] as? [[String: Any]])
        #expect(evidence.count == 1)
        #expect(evidence[0]["source"] as? String == "s:P")
        #expect(evidence[0]["target"] as? String == "s:Q")
        #expect(evidence[0]["kind"] as? String == "call")

        let memberResult = GraphBuilder(options: .init(level: .symbol)).buildResult(
            from: IndexSnapshot(symbols: Array(symbols.prefix(2)))
        )
        let memberDocument = try object(try renderer.render(
            result: memberResult, snapshot: IndexSnapshot(symbols: Array(symbols.prefix(2))), projectPath: "/p"
        ))
        #expect(memberResult.graph.edges.contains { $0.kind == .member })
        #expect((memberDocument["evidence"] as? [Any])?.isEmpty == true)
        #expect(memberDocument["unlocatedEvidenceCount"] as? Int == 0)
        let inventory = try #require(memberDocument["inventory"] as? [String: Any])
        #expect(inventory["index"] == nil)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
