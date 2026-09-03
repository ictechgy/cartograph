import CartographCore
import CartographSyntax
import CartographTestSupport
import Testing

@Suite("구문 분석 캐시")
struct SourceFactsCacheTests {
    private func makeCache(
        _ fileSystem: InMemoryFileSystem,
        identity: String = ""
    ) -> SourceFactsCache {
        SourceFactsCache(fileSystem: fileSystem, path: "/cache/facts.json", analyzerIdentity: identity)
    }

    @Test("저장한 항목을 그대로 읽는다")
    func roundTripsEntries() {
        let fileSystem = InMemoryFileSystem()
        let cache = makeCache(fileSystem)
        let facts = SourceFileFacts(
            path: "/p/A.swift",
            declarations: [
                DeclarationFacts(name: "A", line: 1, accessibility: .publicLevel, attributes: [.entryPoint])
            ]
        )
        cache.save(["/p/A.swift": SourceFactsCache.Entry(fingerprint: "abc", facts: facts)])

        let loaded = cache.load()
        #expect(loaded["/p/A.swift"]?.fingerprint == "abc")
        #expect(loaded["/p/A.swift"]?.facts == facts)
    }

    @Test("캐시가 없거나 깨졌으면 빈 값으로 시작한다")
    func startsEmptyWhenUnusable() {
        #expect(makeCache(InMemoryFileSystem()).load().isEmpty)
        #expect(makeCache(InMemoryFileSystem(files: ["/cache/facts.json": "not json"])).load().isEmpty)
    }

    @Test("형식 버전이 다르면 통째로 버린다")
    func discardsOtherSchemaVersions() {
        // 버전을 올리는 것을 잊으면 낡은 결과로 조용히 틀린 분석을 하게 된다.
        let stale = #"{"version":0,"entries":{"/p/A.swift":{"fingerprint":"x","facts":{"path":"/p/A.swift","declarations":[],"ignoresEntireFile":false}}}}"#
        #expect(makeCache(InMemoryFileSystem(files: ["/cache/facts.json": stale])).load().isEmpty)
    }

    @Test("분석기 설정이 바뀌면 지문도 바뀐다")
    func fingerprintFollowsAnalyzerConfiguration() {
        // 설정이 결과를 바꾸므로, 지문이 같으면 예전 결과가 되살아난다.
        let fileSystem = InMemoryFileSystem()
        let source = "struct A {}"
        #expect(makeCache(fileSystem, identity: "").fingerprint(of: source)
            != makeCache(fileSystem, identity: "BaseTestCase").fingerprint(of: source))
        // 같은 입력이면 실행마다 같은 값이어야 한다.
        #expect(makeCache(fileSystem).fingerprint(of: source) == makeCache(fileSystem).fingerprint(of: source))
        #expect(makeCache(fileSystem).fingerprint(of: source) != makeCache(fileSystem).fingerprint(of: "struct B {}"))
    }

    @Test("내용이 그대로면 다시 파싱하지 않고 같은 결과를 준다")
    func reusesFactsForUnchangedFiles() {
        let fileSystem = InMemoryFileSystem(files: ["/p/A.swift": "public struct A {}"])
        var builder = SnapshotBuilder()
        builder.symbol("A", kind: .structType, path: "/p/A.swift", line: 1)
        let snapshot = builder.build()
        let cache = makeCache(fileSystem)
        let enricher = SnapshotEnricher(fileSystem: fileSystem, analyzer: .init(), cache: cache)

        let first = enricher.enrich(snapshot)
        #expect(!cache.load().isEmpty)
        // 두 번째 실행은 캐시에서 읽는다. 결과가 같아야 한다.
        let second = enricher.enrich(snapshot)
        #expect(first.symbols == second.symbols)
        #expect(second.symbols.first?.accessibility == .publicLevel)
    }

    @Test("파일이 바뀌면 캐시를 무시한다")
    func invalidatesChangedFiles() {
        let fileSystem = InMemoryFileSystem(files: ["/p/A.swift": "public struct A {}"])
        var builder = SnapshotBuilder()
        builder.symbol("A", kind: .structType, path: "/p/A.swift", line: 1)
        let snapshot = builder.build()
        let enricher = SnapshotEnricher(fileSystem: fileSystem, analyzer: .init(), cache: makeCache(fileSystem))

        #expect(enricher.enrich(snapshot).symbols.first?.accessibility == .publicLevel)
        try? fileSystem.write(text: "private struct A {}", to: "/p/A.swift")
        #expect(enricher.enrich(snapshot).symbols.first?.accessibility == .privateLevel)
    }

    @Test("캐시를 주지 않으면 예전처럼 매번 분석한다")
    func worksWithoutACache() {
        let fileSystem = InMemoryFileSystem(files: ["/p/A.swift": "public struct A {}"])
        var builder = SnapshotBuilder()
        builder.symbol("A", kind: .structType, path: "/p/A.swift", line: 1)
        let enriched = SnapshotEnricher(fileSystem: fileSystem).enrich(builder.build())
        #expect(enriched.symbols.first?.accessibility == .publicLevel)
        #expect(fileSystem.writtenPaths == ["/p/A.swift"])
    }
}
