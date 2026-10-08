import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("프로젝트 파일 inventory")
struct ProjectFileInventoryTests {
    @Test("한 번의 프로젝트 walk가 소스와 런타임 파일을 같은 범위로 모은다")
    func oneWalkBuildsRelevantViews() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/Sources/App.swift": "struct App {}",
            "/p/Views/Main.storyboard": "<document/>",
            "/p/Models/Model.xcdatamodel/contents": "<model/>",
            "/p/.build/checkouts/Noise.swift": "struct Noise {}",
        ])

        let inventory = ProjectFileInventory(
            fileSystem: fileSystem, projectPath: "/p", pathFilter: .passthrough
        )

        #expect(inventory.sourceFiles == ["/p/Sources/App.swift"])
        #expect(inventory.interfaceBuilderFiles == ["/p/Views/Main.storyboard"])
        #expect(inventory.runtimeFiles == [
            "/p/Models/Model.xcdatamodel/contents", "/p/Views/Main.storyboard",
        ])
    }

    @Test("loadContext는 인덱스·구문·리소스·한계 수집이 같은 디렉터리 walk를 공유한다")
    func loadContextSharesTheInventoryWalk() throws {
        let base = InMemoryFileSystem(files: [
            "/p/Sources/App.swift": "struct App {}",
            "/p/Views/Main.storyboard": "<document/>",
            "/p/Models/Model.xcdatamodel/contents": "<model/>",
            "/p/.build/checkouts/Noise.swift": "struct Noise {}",
        ])
        let fileSystem = CountingFileSystem(base)
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, path: "/p/Sources/App.swift")
        let service = CartographService(
            configuration: CartographConfiguration(projectPath: "/p"),
            environment: CartographEnvironment(
                fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(builder.build())
            )
        )

        let context = try service.loadContext()
        _ = service.analysisLimitations(context: context)

        #expect(fileSystem.directoryReadCount == 5)
    }

    @Test("routeCalls도 인덱스와 소스 목록에 같은 inventory를 재사용한다")
    func routeCallsSharesTheInventoryWalk() throws {
        let base = InMemoryFileSystem(files: [
            "/p/Sources/Client.swift": "let url = URL(string: \"https://example.com/users\")",
            "/p/Views/Main.storyboard": "<document/>",
            "/p/Models/Model.xcdatamodel/contents": "<model/>",
            "/p/.build/checkouts/Noise.swift": "let ignored = 1",
        ])
        let fileSystem = CountingFileSystem(base)
        let service = CartographService(
            configuration: CartographConfiguration(projectPath: "/p"),
            environment: CartographEnvironment(
                fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(IndexSnapshot())
            )
        )

        _ = try service.routeCalls(generatedAt: Date(timeIntervalSince1970: 1))

        #expect(fileSystem.directoryReadCount == 5)
    }
}

private final class CountingFileSystem: FileSystem, @unchecked Sendable {
    private let base: InMemoryFileSystem
    private let lock = NSLock()
    private var directoryReads = 0

    init(_ base: InMemoryFileSystem) { self.base = base }

    var directoryReadCount: Int { lock.withLock { directoryReads } }
    var currentDirectoryPath: String { base.currentDirectoryPath }
    func realPath(at path: String) throws -> String { try base.realPath(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func readData(at path: String) throws -> Data { try base.readData(at: path) }
    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    func removeItem(at path: String) throws { try base.removeItem(at: path) }
    func contentsOfDirectory(at path: String) throws -> [String] {
        lock.withLock { directoryReads += 1 }
        return try base.contentsOfDirectory(at: path)
    }
    func directoryEntries(at path: String) throws -> [DirectoryEntry] {
        try contentsOfDirectory(at: path).map { entry in
            DirectoryEntry(
                path: entry,
                isDirectory: base.directoryExists(at: entry),
                isRegularFile: base.fileExists(at: entry),
                isSymbolicLink: false
            )
        }
    }
    func modificationDate(at path: String) -> Date? { base.modificationDate(at: path) }
    func fingerprintStamp(at path: String) -> FileFingerprintStamp? { base.fingerprintStamp(at: path) }
    func directoryListingStamp(at path: String) -> DirectoryListingStamp? {
        base.directoryListingStamp(at: path)
    }
}
