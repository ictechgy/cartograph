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

    @Test("헤더의 인덱스 불확실성을 소스 진입점 목록과 구분해 전달한다")
    func headersAreCoverageInputs() {
        let fileSystem = InMemoryFileSystem(files: ["/p/Handler.h": "", "/p/Handler.m": ""])
        let inventory = ProjectFileInventory(fileSystem: fileSystem, projectPath: "/p", pathFilter: .passthrough)
        #expect(inventory.sourceFiles == ["/p/Handler.m"])
        #expect(inventory.limitationFiles == ["/p/Handler.h", "/p/Handler.m"])
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

    @Test("루트 밖을 가리키는 디렉터리 링크 뒤의 소스·헤더·IB 문서는 inventory에 담지 않는다")
    func externalDirectoryLinkIsLeftOutOfInventory() throws {
        let fixture = try ExternalDirectoryLinkFixture(
            inside: ["Sources/App/App.swift": "struct App {}"],
            outside: ["Vendor.swift": "struct Vendor {}", "Vendor.h": "int f(void);", "Main.storyboard": "<document/>"]
        )
        defer { fixture.remove() }
        let fileSystem = LocalFileSystem()

        let inventory = ProjectFileInventory(
            fileSystem: fileSystem, projectPath: fixture.root,
            pathFilter: CartographConfiguration(projectPath: fixture.root).pathFilter
        )

        let app = try fileSystem.realPath(at: fixture.root + "/Sources/App/App.swift")
        #expect(inventory.allSourceFiles == [app])
        #expect(inventory.limitationFiles == [app])
        #expect(inventory.runtimeFiles.isEmpty)
        let resolvedRoot = try fileSystem.realPath(at: fixture.root)
        #expect(inventory.externalDirectoryLinks == [resolvedRoot + "/" + ExternalDirectoryLinkFixture.linkPath])
    }

    @Test("제외 글롭에 걸린 위치의 루트 밖 디렉터리 링크는 세지 않는다")
    func excludedExternalDirectoryLinkIsNotCounted() throws {
        let fixture = try ExternalDirectoryLinkFixture(
            inside: ["Sources/App/App.swift": "struct App {}"], outside: ["Vendor.swift": "struct Vendor {}"]
        )
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            atPath: fixture.root + "/Tests/Fixtures", withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: fixture.root + "/Tests/Fixtures/vendor", withDestinationPath: fixture.outside
        )
        let fileSystem = LocalFileSystem()
        let filter = CartographConfiguration(projectPath: fixture.root, exclude: ["Tests/**"]).pathFilter

        let inventory = ProjectFileInventory(fileSystem: fileSystem, projectPath: fixture.root, pathFilter: filter)

        // 범위 밖 위치의 링크까지 알리면 매번 붙는 경보가 된다. 범위 안 링크는 그대로 센다.
        let resolvedRoot = try fileSystem.realPath(at: fixture.root)
        #expect(inventory.externalDirectoryLinks == [resolvedRoot + "/" + ExternalDirectoryLinkFixture.linkPath])
    }

    @Test("routes·bridges·schema 문서는 루트 밖 디렉터리 링크 뒤 소스를 읽지 않고 그 수를 한계로 싣는다")
    func exchangeDocumentsSkipExternalDirectoryLinks() throws {
        let fixture = try ExternalDirectoryLinkFixture(
            inside: ["Sources/App/Visible.swift": Self.exchangeSource(name: "visible")],
            outside: ["Hidden.swift": Self.exchangeSource(name: "hidden")]
        )
        defer { fixture.remove() }
        var configuration = CartographConfiguration.default
        configuration.projectPath = fixture.root
        let service = CartographService(configuration: configuration, environment: CartographEnvironment(
            indexProviderOverride: StaticIndexProvider(IndexSnapshot()), usesSyntaxCache: false
        ))
        let date = Date(timeIntervalSince1970: 1_788_480_000)
        let prefix = "symlinked-directories-outside-root: 1 directory symlink(s) "

        let routes = try service.routeCalls(generatedAt: date)
        #expect(routes.facts.map(\.channel) == ["/api/visible"])
        #expect(routes.limitations.contains { $0.hasPrefix(prefix) })
        let bridges = try service.bridgeFacts(generatedAt: date)
        #expect(Set(bridges.facts.compactMap(\.channel)) == ["dev.example/visible"])
        #expect(bridges.limitations.contains { $0.hasPrefix(prefix) })
        let events = try service.bridgeFacts(generatedAt: date, rnEvents: true)
        #expect(events.limitations.contains { $0.hasPrefix(prefix) })
        let schema = try service.schemaFacts(generatedAt: date)
        #expect(Set(schema.facts.compactMap(\.channel)) == ["visible_table"])
        #expect(schema.limitations.contains { $0.hasPrefix(prefix) })
    }

    /// HTTP 호출·Flutter 채널·SQL 관계를 하나씩 내는 소스. 이름으로 어느 파일의 사실인지 가른다.
    private static func exchangeSource(name: String) -> String {
        """
        import Flutter
        import Foundation
        import SQLite3

        func load\(name)() -> URLRequest { URLRequest(url: URL(string: "https://example.com/api/\(name)")!) }

        public final class \(name.capitalized)Plugin: NSObject, FlutterPlugin {
            public static func register(with registrar: FlutterPluginRegistrar) {
                let channel = FlutterMethodChannel(name: "dev.example/\(name)", binaryMessenger: registrar.messenger())
                registrar.addMethodCallDelegate(\(name.capitalized)Plugin(), channel: channel)
            }
            public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
                switch call.method {
                case "ping": result(nil)
                default: result(FlutterMethodNotImplemented)
                }
            }
        }

        func purge\(name)(db: OpaquePointer) {
            sqlite3_exec(db, "DELETE FROM \(name)_table", nil, nil, nil)
        }
        """
    }

    @Test("교환 문서가 중첩 저장소 제외를 모두 전달한다")
    func exchangeDocumentsPreserveRepositoryBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/.git"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(Self.exchangeSource(name: "visible").utf8).write(to: root.appendingPathComponent("Visible.swift"))
        try Data(Self.exchangeSource(name: "hidden").utf8).write(to: root.appendingPathComponent("nested/Hidden.swift"))
        var configuration = CartographConfiguration.default
        configuration.projectPath = root.path
        let service = CartographService(configuration: configuration, environment: CartographEnvironment(
            indexProviderOverride: StaticIndexProvider(IndexSnapshot()), usesSyntaxCache: false
        ))
        let date = Date(timeIntervalSince1970: 1_788_480_000)
        let routes = try service.routeCalls(generatedAt: date)
        let bridges = try service.bridgeFacts(generatedAt: date)
        let events = try service.bridgeFacts(generatedAt: date, rnEvents: true)
        let schema = try service.schemaFacts(generatedAt: date)
        #expect(routes.facts.map(\.channel) == ["/api/visible"])
        #expect(Set(bridges.facts.compactMap(\.channel)) == ["dev.example/visible"])
        #expect(Set(schema.facts.compactMap(\.channel)) == ["visible_table"])
        for limits in [routes.limitations, bridges.limitations, events.limitations, schema.limitations] {
            #expect(limits.contains { $0.hasPrefix("source-discovery-exclusions: 1 ") && $0.contains("nested") })
        }
    }
}

/// 루트 안 디렉터리 링크(`Sources/App/vendor`)가 루트 밖 디렉터리를 가리키는 실제 임시 트리.
///
/// 메모리 파일 시스템은 링크를 모델링하지 않는다. 임시 경로는 `/var` → `/private/var` 처럼 링크가 낀 조상을
/// 그대로 두어, 탐색이 돌려주는 실제 경로 철자와 다른 표기의 프로젝트 경로로도 상대화되는지 함께 본다.
struct ExternalDirectoryLinkFixture {
    /// 루트 기준 링크 위치.
    static let linkPath = "Sources/App/vendor"
    let base: String
    var root: String { base + "/root" }
    var outside: String { base + "/outside" }

    /// - Parameters:
    ///   - inside: 루트 기준 상대 경로와 내용.
    ///   - outside: 링크가 가리키는 루트 밖 디렉터리 기준 상대 경로와 내용.
    init(inside: [String: String], outside: [String: String]) throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-external-link-\(UUID().uuidString)").path
        for (path, text) in inside { try Self.write(text, to: base + "/root/" + path) }
        for (path, text) in outside { try Self.write(text, to: base + "/outside/" + path) }
        try FileManager.default.createDirectory(
            atPath: base + "/outside", withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: base + "/root/Sources/App", withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: base + "/root/" + Self.linkPath, withDestinationPath: base + "/outside"
        )
    }

    func remove() {
        do { try FileManager.default.removeItem(atPath: base) } catch {
            Issue.record("임시 디렉터리를 지우지 못했다: \(error)")
        }
    }

    private static func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
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
