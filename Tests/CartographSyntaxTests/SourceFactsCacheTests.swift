import CartographCore
import Foundation
import CartographSyntax
import CartographTestSupport
import Testing

@Suite("구문 분석 캐시")
struct SourceFactsCacheTests {
    private func makeCache(
        _ fileSystem: any FileSystem,
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
        // 쓰기 횟수를 세어 고정해 둔다.
        let fileSystem = CountingFileSystem(
            InMemoryFileSystem(files: ["/p/A.swift": "public struct A {}"])
        )
        var builder = SnapshotBuilder()
        builder.symbol("A", kind: .structType, path: "/p/A.swift", line: 1)
        let snapshot = builder.build()
        let enricher = SnapshotEnricher(fileSystem: fileSystem, analyzer: .init(), cache: makeCache(fileSystem))

        _ = enricher.enrich(snapshot)
        #expect(fileSystem.writeCount(for: "/cache/facts.json") == 1)
        _ = enricher.enrich(snapshot)
        // 두 번째 실행은 전부 캐시 적중이라 쓸 것이 없다.
        #expect(fileSystem.writeCount(for: "/cache/facts.json") == 1)

        // 파일이 바뀌면 다시 쓴다.
        try? fileSystem.write(text: "private struct A {}", to: "/p/A.swift")
        _ = enricher.enrich(snapshot)
        #expect(fileSystem.writeCount(for: "/cache/facts.json") == 2)
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

    @Test("안쪽 위치는 항목 경로를 다시 싣지 않고, 읽을 때 같은 사실로 되살린다")
    func omitsTheEntryPathFromInnerLocations() throws {
        // 형식 15 에서는 이 저장소 Sources 캐시 JSON 의 62% 가 위치마다 되풀이한 같은 절대 경로였다.
        let path = "/p/Sources/Rich.swift"
        let facts = SwiftSyntaxAnalyzer().analyze(source: Self.richSource, path: path)
        let fileSystem = InMemoryFileSystem()
        let cache = makeCache(fileSystem)
        cache.save([path: SourceFactsCache.Entry(fingerprint: "f", facts: facts)])

        // 입력이 위치를 실제로 많이 만드는지 먼저 본다. 그렇지 않으면 아래 단언이 아무것도 재지 않는다.
        #expect(facts.declarations.compactMap(\.nameLocation).count >= 5)
        #expect(facts.runtimeFacts?.boundaries.isEmpty == false)
        #expect(facts.localFunctionScopes?.isEmpty == false)
        #expect(facts.parameterUsages?.isEmpty == false)
        #expect(facts.imports?.isEmpty == false)
        #expect(facts.bodyRanges?.isEmpty == false)
        #expect(facts.enumDecisionFacts?.decisions.isEmpty == false)
        // 경로는 항목 키와 파일마다 한 번인 `SourceFileFacts.path`·`RuntimeFileFacts.path` 에만 남는다.
        let text = try fileSystem.readText(at: "/cache/facts.json")
        #expect(text.components(separatedBy: path).count - 1 == 3)
        #expect(cache.load()[path]?.facts == facts)
    }

    @Test("표기가 다른 안쪽 경로는 생략하지 않고 그대로 되살린다")
    func keepsInnerPathsSpelledDifferently() throws {
        // macOS 는 같은 파일을 `/tmp` 와 `/private/tmp` 로 부른다. 표기가 다르면 다른 경로로 다룬다.
        let entryPath = "/tmp/p/A.swift"
        let facts = SourceFileFacts(
            path: entryPath,
            declarations: [
                DeclarationFacts(name: "A", line: 1, accessibility: .publicLevel, attributes: [],
                    nameLocation: SourceLocation(path: "/private/tmp/p/A.swift", line: 1, column: 15)),
                DeclarationFacts(name: "B", line: 2, accessibility: .internalLevel, attributes: [],
                    nameLocation: SourceLocation(path: entryPath, line: 2, column: 8)),
            ],
            bodyRanges: [SourceRange(
                start: SourceLocation(path: entryPath, line: 3, column: 1),
                end: SourceLocation(path: "/tmp/p/Other.swift", line: 4, column: 1)
            )]
        )
        let fileSystem = InMemoryFileSystem()
        let cache = makeCache(fileSystem)
        cache.save([entryPath: SourceFactsCache.Entry(fingerprint: "f", facts: facts)])

        let text = try fileSystem.readText(at: "/cache/facts.json")
        #expect(text.contains(#""path":"/private/tmp/p/A.swift""#))
        #expect(text.contains(#""path":"/tmp/p/Other.swift""#))
        #expect(cache.load()[entryPath]?.facts == facts)
    }

    @Test("안쪽 위치마다 경로를 싣던 이전 형식(15)의 캐시는 버리고 다시 만든다")
    func discardsThePathRepeatingFormat() {
        let previous = #"{"version":15,"entries":{"/p/A.swift":{"fingerprint":"x","#
            + #""facts":{"path":"/p/A.swift","declarations":[],"ignoresEntireFile":false}}}}"#
        #expect(makeCache(InMemoryFileSystem(files: ["/cache/facts.json": previous])).load().isEmpty)
    }

    /// 사실의 모든 갈래(선언·런타임·지역 함수·파라미터·import·본문·enum 결정)에 위치를 만드는 소스.
    private static let richSource = """
        import Foundation

        public enum Mode { case on, off }

        public final class Holder: NSObject {
            public var value: Int {
                get { 1 }
                set { _ = newValue }
            }

            public func run(mode: Mode, label: String) -> Int {
                func helper() -> Int { label.count }
                switch mode {
                case .on: return helper()
                default: return 0
                }
            }

            public func check(_ mode: Mode) -> Bool {
                [Mode.on, .off].contains(mode)
            }

            @objc func observe() {
                _ = #selector(observe)
                _ = NSClassFromString("Holder")
            }
        }
        """
}

/// 경로별 쓰기 횟수를 세는 파일 시스템. 캐시가 언제 쓰이는지 고정하는 데 쓴다.
private final class CountingFileSystem: FileSystem, @unchecked Sendable {
    private let base: InMemoryFileSystem
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    init(_ base: InMemoryFileSystem) { self.base = base }

    func writeCount(for path: String) -> Int { lock.withLock { counts[path] ?? 0 } }

    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func readData(at path: String) throws -> Data { try base.readData(at: path) }
    func contentsOfDirectory(at path: String) throws -> [String] { try base.contentsOfDirectory(at: path) }
    var currentDirectoryPath: String { base.currentDirectoryPath }

    func write(_ data: Data, to path: String) throws {
        lock.withLock { counts[path, default: 0] += 1 }
        try base.write(data, to: path)
    }
    func removeItem(at path: String) throws { try base.removeItem(at: path) }
}
