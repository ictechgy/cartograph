import CartographCore
import CartographTestSupport
import Foundation
import Testing

@testable import CartographKit

@Suite("재귀 호출 그래프의 명시적 투영")
struct SelfLoopGraphTests {
    private func fixture() -> (CartographService, AnalysisContext) {
        var builder = SnapshotBuilder(path: "/p/Calls.swift")
        builder.symbol("entry", kind: .function, attributes: [.entryPoint])
        builder.symbol("recurse", kind: .function)
        builder.reference(from: "entry", to: "recurse", kind: .call, line: 2)
        builder.reference(from: "recurse", to: "recurse", kind: .call, line: 5)
        builder.reference(from: "recurse", to: "recurse", kind: .call, line: 7)
        let snapshot = builder.build()
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(
            configuration: configuration,
            environment: .init(
                fileSystem: InMemoryFileSystem(files: ["/p/Calls.swift": "func entry() {}\nfunc recurse() {}"]),
                indexProviderOverride: StaticIndexProvider(snapshot)
            ))
        return (service, AnalysisContext(snapshot: snapshot))
    }

    @Test("기본 그래프와 자기 간선 그래프는 캐시를 공유해도 서로의 투영을 바꾸지 않는다")
    func cachesSelfLoopProjectionSeparately() {
        let (_, context) = fixture()
        for _ in 0..<2 {
            let ordinary = context.buildGraph(level: .symbol).graph
            let complete = context.buildGraph(level: .symbol, includeSelfLoops: true).graph
            #expect(ordinary.edges.count == 1)
            #expect(complete.edges.count == 2)
            #expect(complete.edges.contains { $0.source == "recurse" && $0.target == "recurse" })
            #expect(context.buildGraph(level: .module, includeSelfLoops: true).graph.edges.isEmpty)
            #expect(context.buildGraph(level: .symbol).graph.edges == ordinary.edges)
        }
    }

    @Test("명시적 심볼 그래프만 재귀 호출을 내보내고 기본 그림은 바꾸지 않는다")
    func rendersOptInGraphWithoutChangingDefaults() throws {
        let (service, _) = fixture()
        let plain = try service.renderGraph(level: .symbol, format: .json)
        let complete = try service.renderGraph(
            level: .symbol, format: .json,
            includingEvidence: false, includingSelfLoops: true)
        let plainJSON = try #require(JSONSerialization.jsonObject(with: Data(plain.output.utf8)) as? [String: Any])
        let completeJSON = try #require(
            JSONSerialization.jsonObject(with: Data(complete.output.utf8)) as? [String: Any]
        )
        #expect((plainJSON["edges"] as? [[String: Any]])?.count == 1)
        #expect((completeJSON["edges"] as? [[String: Any]])?.count == 2)
        #expect(try service.renderGraph(level: .symbol, format: .json).output == plain.output)
        #expect(
            try service.renderGraph(
                level: .symbol, format: .dot,
                includingEvidence: false, includingSelfLoops: true
            ).output.contains("\"recurse\" -> \"recurse\""))
        #expect(throws: CartographError.self) {
            try service.renderGraph(
                level: .module, format: .json,
                includingEvidence: false, includingSelfLoops: true)
        }
    }

    @Test("재귀 호출의 여러 소스 위치와 스냅샷 왕복 근거를 잃지 않는다")
    func preservesOccurrenceSitesAndSnapshotRoundTrip() throws {
        let (service, context) = fixture()
        let output = try service.renderGraph(
            level: .symbol, format: .json,
            includingEvidence: true, includingSelfLoops: true)
        #expect(output.output.contains("\"evidenceCount\" : 3"))
        #expect(output.output.contains("\"line\" : 5"))
        #expect(output.output.contains("\"line\" : 7"))
        let document = try service.captureSnapshot(in: context)
        let data = try JSONEncoder.cartographDefault().encode(document)
        let restored = try JSONDecoder().decode(AnalysisSnapshotDocument.self, from: data)
        try restored.validate()
        let references = restored.snapshot.references.filter { $0.sourceUSR == $0.targetUSR }
        #expect(references.compactMap(\.location?.line).sorted() == [5, 7])
        #expect(references.allSatisfy { $0.kind == .call })
    }
}
