import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("발생 출처 unknown의 제품 결과 전달")
struct SourceAttributionLimitationTests {
    @Test("기존 간선 폴백의 불확실성이 graph와 cycles와 check에 남는다")
    func preservesFallbackUncertainty() throws {
        let a = IndexedSymbol(usr: "s:A", name: "A", kind: .classType, module: "Domain",
                              location: .init(path: "/p/A.swift", line: 1, column: 1))
        let b = IndexedSymbol(usr: "s:B", name: "B", kind: .classType, module: "App",
                              location: .init(path: "/p/B.swift", line: 1, column: 1))
        let reference = IndexedReference(sourceUSR: a.usr, targetUSR: b.usr, kind: .reference,
            location: .init(path: "/p/Unknown.swift", line: 5, column: 1), origin: .compiler)
        let snapshot = IndexSnapshot(symbols: [a, b], references: [reference])
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configuration.reportFormat = .json
        let service = CartographService(configuration: configuration, environment: .init(
            fileSystem: InMemoryFileSystem(files: ["/p/A.swift": "class A {}", "/p/B.swift": "class B {}"]),
            indexProviderOverride: StaticIndexProvider(snapshot), usesSyntaxCache: false))
        let graph = try service.renderGraph(level: .module, format: .json)
        #expect(graph.notes.contains { $0.hasPrefix("source-attribution:") })
        let symbol = try service.renderGraph(level: .symbol, format: .json)
        #expect(!symbol.notes.contains { $0.hasPrefix("source-attribution:") })
        let evidence = try service.renderGraph(level: .module, format: .json, includingEvidence: true)
        #expect(evidence.output.contains("source-attribution:"))
        let cycles = try service.detectCycles(level: .module)
        #expect(cycles.output.contains("source-attribution:"))
        #expect(try service.checkDocument().limitations.contains { $0.hasPrefix("source-attribution:") })
    }
}
