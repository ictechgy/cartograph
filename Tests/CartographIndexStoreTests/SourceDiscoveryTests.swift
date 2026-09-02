import CartographCore
@testable import CartographIndexStore
import CartographTestSupport
import Testing

@Suite("소스 파일 탐색")
struct SourceDiscoveryTests {
    private func makeProvider(
        fileSystem: InMemoryFileSystem,
        roots: [String],
        filter: PathFilter = .passthrough
    ) -> IndexStoreProvider {
        IndexStoreProvider(
            configuration: .init(
                storePath: "/store",
                databasePath: "/db",
                libraryPath: "/lib.dylib",
                sourceRoots: roots,
                pathFilter: filter
            ),
            fileSystem: fileSystem
        )
    }

    @Test("빌드 산출물 디렉터리에는 들어가지 않는다")
    func prunesBuildDirectories() {
        // 큰 저장소에서는 이 가지치기만으로 탐색 시간이 몇 배 차이 난다.
        let fileSystem = InMemoryFileSystem(files: [
            "/p/Sources/App/Main.swift": "",
            "/p/.build/checkouts/Yams/Node.swift": "",
            "/p/DerivedData/Index/Generated.swift": "",
            "/p/Pods/Alamofire/Session.swift": "",
            "/p/.git/hooks/pre-commit.swift": "",
        ])
        #expect(makeProvider(fileSystem: fileSystem, roots: ["/p"]).sourceFilePaths()
            == ["/p/Sources/App/Main.swift"])
    }

    @Test("Swift 파일만 후보가 된다")
    func onlySwiftFiles() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/A.swift": "",
            "/p/B.m": "",
            "/p/README.md": "",
        ])
        #expect(makeProvider(fileSystem: fileSystem, roots: ["/p"]).sourceFilePaths() == ["/p/A.swift"])
    }

    @Test("경로 필터가 적용된다")
    func appliesPathFilter() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/Sources/A.swift": "",
            "/p/Tests/ATests.swift": "",
        ])
        let provider = makeProvider(
            fileSystem: fileSystem,
            roots: ["/p"],
            filter: PathFilter(include: ["**/Sources/**"])
        )
        #expect(provider.sourceFilePaths() == ["/p/Sources/A.swift"])
    }

    @Test("여러 루트에서 중복 없이 모은다")
    func deduplicatesAcrossRoots() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/Sources/A.swift": "",
            "/p/Extra/B.swift": "",
        ])
        let provider = makeProvider(fileSystem: fileSystem, roots: ["/p", "/p/Sources"])
        #expect(provider.sourceFilePaths() == ["/p/Extra/B.swift", "/p/Sources/A.swift"])
    }

    @Test("없는 루트는 조용히 건너뛴다")
    func missingRootIsSkipped() {
        #expect(makeProvider(fileSystem: InMemoryFileSystem(), roots: ["/nope"]).sourceFilePaths().isEmpty)
    }
}
