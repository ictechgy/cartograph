import CartographCore
@testable import CartographIndexStore
import CartographTestSupport
import Foundation
import Testing

@Suite("소스 파일 탐색")
struct SourceDiscoveryTests {
    @Test("선언 파일 목록과 별개인 의존 범위는 헤더·삭제 소스만 추적하고 외부·빌드·제외 경로는 거부한다")
    func dependencyScopeDoesNotBroadenDeclarationDiscovery() {
        let fs = InMemoryFileSystem(files: ["/p/A.swift": "", "/p/API.h": ""])
        let provider = IndexStoreProvider(configuration: .init(storePath: "/s", databasePath: "/d",
            libraryPath: "/l", sourceRoots: ["/p/A.swift"], pathFilter: PathFilter(exclude: ["**/Excluded/**"]),
            includeObjectiveCSources: true, dependencyRoots: ["/p"]), fileSystem: fs)
        #expect(provider.sourceFilePaths() == ["/p/A.swift"])
        #expect(provider.trackedSourcePathPredicate()("/p/API.h"))
        #expect(provider.trackedSourcePathPredicate()("/p/Deleted.swift"))
        for path in ["/elsewhere/API.h", "/prefix/API.h", "/p/Excluded/API.h", "/p/.build/API.h",
            "/p/.build-custom/API.h", "/p/DerivedData/API.h", "/p/../elsewhere/API.h", "/p/data.txt"] {
            #expect(!provider.trackedSourcePathPredicate()(path), "\(path)")
        }
    }

    @Test("삭제 경로는 살아 있는 조상의 링크를 풀어 범위를 유지하고 외부 링크는 거부한다")
    func missingDependencyResolvesExistingAncestorAliases() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let real = root.appendingPathComponent("Real")
        let alias = root.appendingPathComponent("Alias")
        let outside = root.appendingPathComponent("Outside")
        try manager.createDirectory(at: real.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: alias, withDestinationURL: real)
        try manager.createSymbolicLink(at: real.appendingPathComponent("Escaping"), withDestinationURL: outside)
        let header = alias.appendingPathComponent("Sources/API.h")
        try Data("int api(void);".utf8).write(to: header)
        let fileSystem = LocalFileSystem()
        let physical = try fileSystem.realPath(at: header.path)
        let provider = IndexStoreProvider(configuration: .init(storePath: "/s", databasePath: "/d",
            libraryPath: "/l", sourceRoots: [], includeObjectiveCSources: true, dependencyRoots: [alias.path]))
        #expect(provider.trackedSourcePathPredicate()(header.path))
        try manager.removeItem(at: header)
        #expect(provider.trackedSourcePathPredicate()(header.path))
        #expect(provider.trackedSourcePathPredicate()(physical))
        #expect(RawIndexStoreReader.sourceLocationPath(header.path, fileSystem: fileSystem) == physical)
        #expect(!provider.trackedSourcePathPredicate()(alias.appendingPathComponent("Escaping/Missing.h").path))
        try manager.removeItem(at: real.appendingPathComponent("Sources"))
        #expect(provider.trackedSourcePathPredicate()(header.path))
        #expect(RawIndexStoreReader.sourceLocationPath(header.path, fileSystem: fileSystem) == physical)
    }

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

    @Test("브리지 전용 탐색은 Objective-C 구현을 포함하고 헤더는 제외한다")
    func objectiveCOptIn() {
        let fs = InMemoryFileSystem(files: ["/p/A.swift": "", "/p/B.m": "", "/p/C.mm": "", "/p/D.h": ""])
        let provider = IndexStoreProvider(configuration: .init(storePath: "/s", databasePath: "/d",
            libraryPath: "/l", sourceRoots: ["/p"], includeObjectiveCSources: true), fileSystem: fs)
        #expect(provider.sourceFilePaths() == ["/p/A.swift", "/p/B.m", "/p/C.mm"])
        #expect(makeProvider(fileSystem: fs, roots: ["/p"]).sourceFilePaths() == ["/p/A.swift"])
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
