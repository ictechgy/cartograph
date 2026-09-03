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

    @Test("도구 버전이나 분석기 개정이 바뀌면 지문도 바뀐다")
    func fingerprintFollowsToolAndAnalyzerVersion() {
        // 이것이 없으면 업그레이드해도 손대지 않은 파일에는 수정이 적용되지 않아,
        // 고친 오탐이 그대로 되살아난다.
        let base = SourceFactsCache.analyzerIdentity(
            toolVersion: "0.2.0", analysisRevision: 1, externalTestCaseClasses: []
        )
        #expect(base != SourceFactsCache.analyzerIdentity(
            toolVersion: "0.3.0", analysisRevision: 1, externalTestCaseClasses: []
        ))
        #expect(base != SourceFactsCache.analyzerIdentity(
            toolVersion: "0.2.0", analysisRevision: 2, externalTestCaseClasses: []
        ))
        // 구분자가 이름 안에 나올 수 없어야 두 목록이 섞이지 않는다.
        #expect(SourceFactsCache.analyzerIdentity(
            toolVersion: "v", analysisRevision: 1, externalTestCaseClasses: ["A,B"]
        ) != SourceFactsCache.analyzerIdentity(
            toolVersion: "v", analysisRevision: 1, externalTestCaseClasses: ["A", "B"]
        ))
    }

    @Test("길이가 다르면 해시가 같아도 적중하지 않는다")
    func fingerprintIncludesLength() {
        // 잘못 적중하면 바뀐 파일에 예전 결과를 조용히 내놓게 되고 검출할 수 없다.
        let cache = makeCache(InMemoryFileSystem())
        #expect(cache.fingerprint(of: "ab").hasPrefix("2:"))
        #expect(cache.fingerprint(of: "abc").hasPrefix("3:"))
    }

    @Test("바뀐 것이 없으면 캐시를 다시 쓰지 않는다")
    func doesNotRewriteAnUnchangedCache() {
        // 직렬화 비용이 캐시 이득을 깎는다. 이 불변식은 눈에 잘 띄지 않으므로
        // 테스트로 고정해 둔다.
        let fileSystem = InMemoryFileSystem(files: ["/p/A.swift": "public struct A {}"])
        var builder = SnapshotBuilder()
        builder.symbol("A", kind: .structType, path: "/p/A.swift", line: 1)
        let snapshot = builder.build()
        let enricher = SnapshotEnricher(fileSystem: fileSystem, analyzer: .init(), cache: makeCache(fileSystem))

        _ = enricher.enrich(snapshot)
        let afterFirst = fileSystem.text(at: "/cache/facts.json")
        try? fileSystem.write(text: "sentinel", to: "/cache/facts.json")
        _ = enricher.enrich(snapshot)
        // 두 번째 실행은 아무것도 파싱하지 않았으므로 쓰지도 않는다.
        #expect(fileSystem.text(at: "/cache/facts.json") == "sentinel")
        #expect(afterFirst != nil)
    }

    @Test("파일이 사라지면 캐시에서도 빠진다")
    func prunesEntriesForRemovedFiles() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/A.swift": "public struct A {}", "/p/B.swift": "public struct B {}",
        ])
        var builder = SnapshotBuilder()
        builder.symbol("A", kind: .structType, path: "/p/A.swift", line: 1)
        builder.symbol("B", kind: .structType, path: "/p/B.swift", line: 1)
        let cache = makeCache(fileSystem)
        _ = SnapshotEnricher(fileSystem: fileSystem, analyzer: .init(), cache: cache).enrich(builder.build())
        #expect(cache.load().count == 2)

        var smaller = SnapshotBuilder()
        smaller.symbol("A", kind: .structType, path: "/p/A.swift", line: 1)
        _ = SnapshotEnricher(fileSystem: fileSystem, analyzer: .init(), cache: cache).enrich(smaller.build())
        #expect(cache.load().keys.sorted() == ["/p/A.swift"])
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
