import CartographAnalysis
import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("질의 문서의 경량 도달성 투영 회귀")
struct QueryReachabilityProjectionTests {
    @Test("전체 분석을 넣은 세션과 단건·혼합 배치의 전체 JSON이 같다", arguments: [false, true])
    func fullReportOracle(withBaseline: Bool) throws {
        let service = makeService(withBaseline: withBaseline)
        if withBaseline {
            _ = try service.writeBaseline(diagnostics: try service.collectAllDiagnostics(), to: "/p/baseline.json")
        }
        let context = try service.loadContext()
        let subjects = ["Root", "Target", "Dead", "Duplicate", "Missing", "Target", "Missing", "Ignored"]
        var oracle = try service.makeQuerySession(in: context, subjects: [])
        #expect(oracle.foundFacts == nil)
        let full = service.unusedCode(in: context).report
        #expect(full.unused.contains { $0.id == "Dead" })
        oracle.installFoundFacts(.init(report: full.reachability,
            referenceEvidence: ReferenceEvidenceIndex(snapshot: context.snapshot, graph: oracle.graph)))
        let projected = try service.makeQuerySession(in: context, subjects: subjects)
        #expect(projected.foundFactsBuildCount == 1)
        #expect(oracle.foundFactsBuildCount == 1)

        for (depth, limit) in [(1, 1), (3, 50)] {
            let expected = try subjects.map {
                try service.queryDocument(symbol: $0, depth: depth, limit: limit, in: oracle)
            }
            let actual = try subjects.map {
                try service.queryDocument(symbol: $0, depth: depth, limit: limit, in: projected)
            }
            #expect(actual == expected)
            #expect(try encoded(actual) == encoded(expected))
            #expect(actual.map(\.requested) == subjects)
            #expect(actual.map(\.status) == [
                "found", "found", "found", "ambiguous", "notFound", "found", "notFound", "found",
            ])
            #expect(actual[1] == actual[5])
            #expect(actual[4] == actual[6])
            let dead = try #require(actual[2].result)
            #expect(dead.reachability.state == "unreachable")
            #expect(dead.reachability.suppressedByBaseline == withBaseline)
            let root = try #require(actual[0].result)
            #expect(root.reachability.state == "retained")
            #expect(!root.reachability.suppressedByBaseline)
            if limit == 1 { #expect(root.truncated.dependsOn) }

            let batch = try service.queryBatch(symbols: subjects, depth: depth, limit: limit)
            let document = try JSONDecoder().decode(SymbolQueryBatchDocument.self, from: Data(batch.output.utf8))
            #expect(document.results == expected)
            #expect(try encoded(document) == encoded(SymbolQueryBatchDocument(results: expected)))
            #expect(batch.subjectNotFound)
            #expect(batch.missingSubjects == ["Missing", "Missing"])
            #expect(try service.queryBatch(symbols: subjects, depth: depth, limit: limit).output == batch.output)
            for (subject, expectedDocument) in zip(subjects, expected) {
                let outcome = try service.query(symbol: subject, depth: depth, limit: limit)
                let decoded = try JSONDecoder().decode(SymbolQueryDocument.self, from: Data(outcome.output.utf8))
                #expect(decoded == expectedDocument)
                #expect(try encoded(decoded) == encoded(expectedDocument))
                #expect(outcome.subjectNotFound == (expectedDocument.status == "notFound"))
            }
        }
    }

    @Test("없는·모호한 질의는 준비하지 않고 이후 found 질의도 한 번만 준비한다")
    func lazySessionRemainsLazy() throws {
        let service = makeService(withBaseline: false)
        let context = try service.loadContext()
        var session = try service.makeQuerySession(in: context, subjects: ["Missing", "Duplicate"])
        #expect(session.foundFacts == nil)
        #expect(session.foundFactsBuildCount == 0)
        for subject in ["Missing", "Duplicate"] {
            _ = try service.queryDocument(symbol: subject, depth: 1, limit: 50, in: session)
        }
        #expect(session.foundFactsBuildCount == 0)
        service.ensureFoundQueryFacts(in: context, subjects: ["Target"], session: &session)
        service.ensureFoundQueryFacts(in: context, subjects: ["Root", "Target"], session: &session)
        #expect(session.foundFactsBuildCount == 1)
        let report = service.unusedCode(in: context).report
        let facts = try #require(session.foundFacts)
        for node in session.graph.sortedNodes {
            #expect(facts.report.explain(node.id, in: session.graph)
                == report.explain(node.id, in: session.graph))
        }
    }


    @Test("다른 모듈의 동명 타입·멤버는 모호함과 정확한 신원을 함께 보존한다")
    func moduleDistinctTypesAndMembers() throws {
        let service = makeService(withBaseline: false)
        let context = try service.loadContext()
        let subjects = ["Duplicate", "work()", "Duplicate.work",
                        "FirstDuplicate", "SecondDuplicate", "FirstMember", "SecondMember",
                        "First.Duplicate.work", "Second.Duplicate.work"]
        let projected = try service.makeQuerySession(in: context, subjects: subjects)
        var oracle = try service.makeQuerySession(in: context, subjects: [])
        oracle.installFoundFacts(.init(report: service.unusedCode(in: context).report.reachability,
            referenceEvidence: ReferenceEvidenceIndex(snapshot: context.snapshot, graph: oracle.graph)))
        for (id, module, parent) in [
            ("FirstDuplicate", "First", nil), ("SecondDuplicate", "Second", nil),
            ("FirstMember", "First", "FirstDuplicate"), ("SecondMember", "Second", "SecondDuplicate"),
        ] as [(String, String, String?)] {
            let node = try #require(projected.graph.node(NodeID(id)))
            #expect(node.usr == id && node.module == module)
            #expect(projected.graph.semanticParent(of: node.id) == parent.map { NodeID($0) })
        }
        for (depth, limit) in [(1, 1), (3, 50)] {
            let actual = try subjects.map {
                try service.queryDocument(symbol: $0, depth: depth, limit: limit, in: projected)
            }
            let expected = try subjects.map {
                try service.queryDocument(symbol: $0, depth: depth, limit: limit, in: oracle)
            }
            #expect(actual == expected)
            #expect(try encoded(actual) == encoded(expected))
            for index in 0..<3 {
                #expect(actual[index].status == "ambiguous" && actual[index].result == nil)
                let candidates = try #require(actual[index].candidates)
                #expect(candidates.count == 2)
                #expect(Set(candidates.compactMap(\.module)) == ["First", "Second"])
                #expect(Set(candidates.compactMap(\.usr)) == (index == 0
                    ? ["FirstDuplicate", "SecondDuplicate"] : ["FirstMember", "SecondMember"]))
            }
            for (index, id, module) in [
                (3, "FirstDuplicate", "First"), (4, "SecondDuplicate", "Second"),
                (5, "FirstMember", "First"), (6, "SecondMember", "Second"),
                (7, "FirstMember", "First"), (8, "SecondMember", "Second"),
            ] {
                #expect(actual[index].status == "found" && actual[index].candidates == nil)
                let result = try #require(actual[index].result)
                #expect(result.subject.usr == id && result.subject.module == module)
                if id.hasSuffix("Duplicate") {
                    #expect(result.members.compactMap(\.usr) == [module + "Member"])
                } else {
                    #expect(result.declaredIn?.usr == module + "Duplicate")
                }
            }
            let batch = try service.queryBatch(symbols: subjects, depth: depth, limit: limit)
            let document = try JSONDecoder().decode(SymbolQueryBatchDocument.self, from: Data(batch.output.utf8))
            #expect(document.results == expected)
            #expect(try encoded(document) == encoded(SymbolQueryBatchDocument(results: expected)))
        }
    }

    private func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func makeService(withBaseline: Bool) -> CartographService {
        var builder = SnapshotBuilder(module: "App", path: "/p/App.swift")
        builder.symbol("Root", kind: .function, attributes: [.entryPoint])
        builder.symbol("Left", kind: .function)
        builder.symbol("Right", kind: .function)
        builder.symbol("Target", kind: .function)
        builder.symbol("Dead", kind: .function)
        builder.symbol("Ignored", kind: .classType)
        builder.symbol("Ignored.member", name: "tap()", kind: .method,
                       parent: "Ignored", attributes: [.interfaceBuilderAction])
        builder.symbol("FirstDuplicate", name: "Duplicate", module: "First", path: "/p/First.swift")
        builder.symbol("SecondDuplicate", name: "Duplicate", module: "Second", path: "/p/Second.swift")
        builder.symbol("FirstMember", name: "work()", kind: .method, module: "First",
                       path: "/p/First.swift", parent: "FirstDuplicate")
        builder.symbol("SecondMember", name: "work()", kind: .method, module: "Second",
                       path: "/p/Second.swift", parent: "SecondDuplicate")
        builder.reference(from: "Root", to: "Left", kind: .call, line: 10, origin: .compiler)
        builder.reference(from: "Root", to: "Right", kind: .call, line: 11, origin: .compiler)
        builder.reference(from: "Left", to: "Target", kind: .call, line: 12, origin: .compiler)
        builder.reference(from: "Right", to: "Target", kind: .reference, line: 13, origin: .syntax)
        builder.reference(from: "Target", to: "Left", kind: .call, line: 14, origin: .compiler)
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        if withBaseline { configuration.baselinePath = "/p/baseline.json" }
        return CartographService(configuration: configuration, environment: CartographEnvironment(
            fileSystem: InMemoryFileSystem(), indexProviderOverride: StaticIndexProvider(builder.build()),
            usesSyntaxCache: false
        ))
    }
}
