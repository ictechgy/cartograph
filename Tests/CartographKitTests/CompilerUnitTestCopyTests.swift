import CartographCore
import CartographSyntax
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("컴파일러 테스트 표식의 복사와 구문 캐시")
struct CompilerUnitTestCopyTests {
    @Test("스냅샷 왕복과 루트 재배치가 세 관찰 상태를 보존한다")
    func snapshotRoundTripAndRebase() throws {
        let snapshot = makeSnapshot(path: "/old/Tests.swift")
        let document = AnalysisSnapshotDocument(projectRoot: "/old", snapshot: snapshot)
        let restored = try AnalysisSnapshotDocument.decode(from: JSONEncoder().encode(document))
        #expect(restored.version == 2)
        #expect(restored.snapshot.symbols.map(\.compilerUnitTest) == [nil, false, true])
        let rebased = restored.rebased(to: "/new")
        #expect(rebased.snapshot.symbols.map(\.compilerUnitTest) == [nil, false, true])
        #expect(rebased.snapshot.symbols.allSatisfy { $0.location.path == "/new/Tests.swift" })
    }

    @Test("값 흐름의 경로 정규화에서도 출처를 잃지 않는다")
    func canonicalizationPreservesEvidence() {
        let snapshot = makeSnapshot(path: "/p/sub/../Tests.swift")
        let loader = ValueFlowSourceLoader(fileSystem: InMemoryFileSystem(), projectPath: "/p",
            pathFilter: .passthrough)
        let loaded = loader.load(snapshot: snapshot)
        #expect(loaded.snapshot.symbols.map(\.compilerUnitTest) == [nil, false, true])
        #expect(loaded.snapshot.symbols.allSatisfy { $0.location.path == "/p/Tests.swift" })
    }

    @Test("구문에서 얻은 unitTest와 캐시 적중은 컴파일러 관찰을 만들거나 덮지 않는다")
    func enrichmentCacheHitPreservesEvidence() throws {
        let path = "/p/Runner.swift"
        let source = "class Runner {\n    func testConnection() {}\n}\n"
        let fileSystem = InMemoryFileSystem(files: [path: source])
        let cache = SourceFactsCache(fileSystem: fileSystem, path: "/p/cache.json", analyzerIdentity: "provenance")
        let enricher = SnapshotEnricher(fileSystem: fileSystem, cache: cache)
        for value in [nil, false, true] as [Bool?] {
            let snapshot = IndexSnapshot(symbols: [
                .init(usr: "runner", name: "Runner", kind: .classType, module: "App",
                    location: .init(path: path, line: 1, column: 7)),
                .init(usr: "method", name: "testConnection()", kind: .method, module: "App",
                    location: .init(path: path, line: 2, column: 10), parentUSR: "runner",
                    compilerUnitTest: value),
            ])
            let first = enricher.enrich(snapshot)
            let cached = try #require(cache.load()[path])
            #expect(cached.fingerprint == cache.fingerprint(of: source))
            let hit = enricher.enrich(snapshot)
            for result in [first, hit] {
                let method = try #require(result.symbolsByUSR()["method"])
                #expect(method.attributes.contains(.unitTest))
                #expect(method.compilerUnitTest == value)
                #expect(result.symbolsByUSR()["runner"]?.compilerUnitTest == nil)
            }
        }
    }

    private func makeSnapshot(path: String) -> IndexSnapshot {
        let values: [Bool?] = [nil, false, true]
        return IndexSnapshot(symbols: values.enumerated().map { index, value in
            .init(usr: "method\(index)", name: "test\(index)()", kind: .method, module: "Tests",
                location: .init(path: path, line: index + 1, column: 1),
                attributes: [.unitTest], compilerUnitTest: value)
        })
    }
}
