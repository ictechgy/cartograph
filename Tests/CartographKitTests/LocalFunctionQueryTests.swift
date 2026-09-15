import CartographAnalysis
import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("지역 함수의 질의 계약")
struct LocalFunctionQueryTests {
    private let path = "/p/Calls.swift"
    private let source = """
        func target() {}
        func outer() {
            func handler() { leaf() }
            @Sendable func leaf() { target() }
            let work = { handler() }; work()
        }
        """

    @Test("직접 소비자는 지역 함수이고 바깥 함수는 실제 깊이로 남는다")
    func exactConsumersAndTransitiveOuter() throws {
        let (service, raw) = fixture(source)
        let result = try #require(service.queryDocument(symbol: "target").result)
        #expect(result.usedBy.map(\.name) == ["leaf()"])
        #expect(result.usedBy.first?.location?.line == 4)
        let transitive = try #require(service.queryDocument(symbol: "target", depth: 3).result)
        #expect(transitive.usedBy.map(\.name) == ["leaf()", "handler()", "outer()"])
        #expect(transitive.usedBy.map(\.depth) == [1, 2, 3])
        let impact = try service.impactDocument(symbols: ["target"], maxDepth: 3)
        #expect(impact.affected.map { $0.symbol.name } == ["leaf()", "handler()", "outer()"])
        #expect(impact.affected.map(\.depth) == [1, 2, 3])
        let localKey = try #require(result.usedBy.first?.usr)
        let local = try #require(service.queryDocument(symbol: localKey).result)
        #expect(local.subject.name == "leaf()")
        #expect(local.declaredIn?.usr == "outer")
        #expect(local.usedBy.map(\.name) == ["handler()"])
        let context = try service.loadContext()
        let beforeGraph = GraphBuilder(options: .init(level: .symbol)).build(from: raw)
        let before = ReachabilityAnalyzer().analyze(graph: beforeGraph, snapshot: raw)
        let after = service.unusedCode(in: context)
        for symbol in raw.symbols {
            #expect((before.explain(NodeID(symbol.usr), in: beforeGraph) != .unreachable)
                == (after.report.explain(NodeID(symbol.usr), in: after.graph) != .unreachable))
        }
    }

    @Test("같은 대상을 바깥과 지역에서 함께 쓰면 두 직접 소비자를 보존한다")
    func preservesMixedReferences() throws {
        let (service, _) = fixture(source.replacingOccurrences(of: "let work", with: "target(); let work"))
        let result = try #require(service.queryDocument(symbol: "target").result)
        #expect(Set(result.usedBy.map(\.name)) == ["leaf()", "outer()"])
    }

    @Test("타입·파일·모듈 그래프의 정점과 간선 가중치는 바뀌지 않는다", arguments: ["top", "nominal", "extension"])
    func preservesRollups(_ shape: String) throws {
        let framed: String
        switch shape {
        case "nominal": framed = "struct Host {\n\(source)\n}"
        case "extension": framed = "struct Host {}\nextension Host {\n\(source)\n}"
        default: framed = source
        }
        let (service, raw) = fixture(framed, shape: shape)
        let refined = try service.loadSnapshot()
        #expect(refined.symbols.count > raw.symbols.count)
        for level in [GraphLevel.type, .file, .module] {
            let builder = GraphBuilder(options: .init(level: level))
            let before = builder.build(from: raw)
            let after = builder.build(from: refined)
            #expect(before.sortedNodes == after.sortedNodes)
            #expect(before.edges == after.edges)
        }
    }

    @Test("도달하지 않는 바깥 함수의 지역 함수를 중복 미사용으로 보고하지 않는다", arguments: [false, true])
    func groupsLocalsUnderDeadOwner(_ liveType: Bool) throws {
        let framed = liveType ? "struct Host {\n\(source)\n}" : source
        let (service, raw) = fixture(framed, shape: liveType ? "nominal" : "top", entry: false)
        let baseline = ReachabilityAnalyzer().analyze(graph: GraphBuilder(options: .init(level: .symbol))
            .build(from: raw), snapshot: raw)
        let context = try service.loadContext()
        let revised = service.unusedCode(in: context)
        #expect(Set(baseline.unused.map(\.id)) == Set(revised.report.unused.map(\.id)))
        #expect(context.snapshot.symbols.contains { SourceLocalSymbol.contains($0.usr) })
    }

    @Test("구분 못한 지역 함수는 찾지 못한 질의에도 실제 개수로 알린다")
    func reportsFallbackInNotFound() throws {
        let uncalled = "func target() {}\nfunc outer() { func unused() { target() } }"
        let (service, _) = fixture(uncalled)
        let document = try service.queryDocument(symbol: "missing")
        #expect(document.status == "notFound")
        #expect(document.limitations.contains { $0.hasPrefix("local-function-projection: 1 ") })
        let (supported, _) = fixture(source)
        #expect(try !supported.queryDocument(symbol: "target").limitations.contains {
            $0.hasPrefix("local-function-projection:")
        })
    }

    private func fixture(_ source: String, shape: String = "top", entry: Bool = true)
        -> (CartographService, IndexSnapshot) {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        func location(_ text: String) -> CartographCore.SourceLocation {
            let index = lines.firstIndex { $0.contains(text) }!
            let range = lines[index].range(of: text)!
            return SourceLocation(path: path, line: index + 1, column: lines[index][..<range.lowerBound].utf8.count + 1)
        }
        let parent = shape == "top" ? nil : (shape == "extension" ? "extension" : "Host")
        var symbols = [
            IndexedSymbol(usr: "target", name: "target()", kind: .function, module: "App",
                location: location("target()"), parentUSR: parent),
            IndexedSymbol(usr: "outer", name: "outer()", kind: shape == "top" ? .function : .method, module: "App",
                location: location("outer()"), parentUSR: parent, attributes: entry ? [.entryPoint] : []),
        ]
        if shape != "top" {
            symbols.append(IndexedSymbol(usr: "Host", name: "Host", kind: .structType, module: "App",
                location: location("Host"), attributes: [.entryPoint]))
        }
        if shape == "extension" {
            symbols.append(IndexedSymbol(usr: "extension", name: "Host", kind: .extensionDeclaration, module: "App",
                location: SourceLocation(path: path, line: 2, column: 11)))
        }
        var references = lines.enumerated().compactMap { index, line -> IndexedReference? in
            guard !line.hasPrefix("func target"), let range = line.range(of: "target()") else { return nil }
            return IndexedReference(sourceUSR: "outer", targetUSR: "target", kind: .call,
                location: SourceLocation(path: path, line: index + 1, column: line[..<range.lowerBound].utf8.count + 1))
        }
        if shape == "extension" {
            references.append(IndexedReference(sourceUSR: "extension", targetUSR: "Host", kind: .extends))
        }
        let raw = IndexSnapshot(symbols: symbols, references: references,
            indexedFileDates: [path: Date(timeIntervalSince1970: 20)])
        let fileSystem = InMemoryFileSystem(files: [path: source])
        fileSystem.setModificationDate(Date(timeIntervalSince1970: 10), for: path)
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        return (CartographService(configuration: configuration, environment: .init(fileSystem: fileSystem,
            indexProviderOverride: StaticIndexProvider(raw))), raw)
    }
}
