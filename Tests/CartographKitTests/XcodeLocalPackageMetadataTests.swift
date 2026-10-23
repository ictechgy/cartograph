import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("빈 Xcode package metadata의 유한 관측 계약")
struct XcodeLocalPackageMetadataTests {
    private static let packageRoot = "/p/Packages/LocalMath"
    private static let metadata = packageRoot + "/.swiftpm"
    private static let xcode = metadata + "/xcode"

    @Test("부재와 정확한 빈 쌍의 관측값만 검증된 scope에 남긴다",
        arguments: ["absent", "preexisting", "capture-created"])
    func admittedOrigins(origin: String) throws {
        let (fixture, fs, service) = try fixture(origin: origin)
        let inventory = try XcodeLocalPackageInputs.inventory(root: Self.packageRoot,
            module: "ArithmeticCore", fileSystem: fs)
        let metadata = inventory.filter { $0.key == ".swiftpm" || $0.key.hasPrefix(".swiftpm/") }
        #expect(metadata == (origin == "absent" ? [:] : [".swiftpm": "directory", ".swiftpm/xcode": "directory"]))
        let scope = service.targetScope(path: "/p/scope.json", fingerprint: fixture.base.fingerprint,
            context: AnalysisContext(snapshot: fixture.base.snapshot), limit: 200)
        #expect(scope.evidenceStatus == "matched-capture")
        #expect(scope.xcode?.selectionStatus == "review-candidates")
        #expect(scope.xcode?.generatedMetadataOrigin == origin)
        #expect(scope.limitations.contains { $0.contains("not a signed receipt") })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(scope)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        #expect((object["xcode"] as? [String: Any])?["generatedMetadataOrigin"] as? String == origin)
        #expect(try JSONDecoder().decode(TargetScopeDocument.self, from: encoded) == scope)
    }

    @Test("v1 scope의 새 선택 필드는 생략되고 예전 JSON은 그대로 읽힌다")
    func versionOneRemainsUnchanged() throws {
        let scope = try XcodeTargetScopeTests().fixture().scope()
        #expect(scope.evidenceStatus == "matched-capture")
        #expect(scope.xcode?.generatedMetadataOrigin == nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(scope)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((object["xcode"] as? [String: Any])?["generatedMetadataOrigin"] == nil)
        #expect(try JSONDecoder().decode(TargetScopeDocument.self, from: data) == scope)
    }

    @Test("v2의 누락 unknown 및 inventory와 반대인 origin은 거부한다",
        arguments: ["missing", "unknown", "absent-with-pair", "preexisting-without-pair", "created-without-pair"])
    func refusesInvalidOrigin(kind: String) throws {
        var (fixture, fs, _) = try fixture(origin: kind == "absent-with-pair" ? "preexisting" : "absent")
        try fixture.changePackage { value in
            switch kind {
            case "missing": value.removeValue(forKey: "generatedMetadataOrigin")
            case "unknown": value["generatedMetadataOrigin"] = "generated"
            case "absent-with-pair": value["generatedMetadataOrigin"] = "absent"
            case "preexisting-without-pair": value["generatedMetadataOrigin"] = "preexisting"
            default: value["generatedMetadataOrigin"] = "capture-created"
            }
        }
        #expect(throws: (any Error).self) {
            try XcodeTargetScopeStore(fileSystem: fs).read(path: "/p/scope.json", root: "/p",
                fingerprint: fixture.base.fingerprint)
        }
    }

    @Test("단독 metadata 디렉터리와 파일 하위 디렉터리 링크 및 불완전 열거는 허용하지 않는다",
        arguments: ["lone", "file", "deeper", "sibling", "symlink-root", "symlink-xcode", "unreadable"])
    func refusesNonemptyOrUnknownMetadata(kind: String) throws {
        let (_, fs, _) = try fixture(origin: "preexisting")
        switch kind {
        case "lone": fs.replaceDirectories([Self.metadata])
        case "file": try fs.write(text: "", to: Self.xcode + "/Package.resolved")
        case "deeper": fs.replaceDirectories([Self.metadata, Self.xcode, Self.xcode + "/empty"])
        case "sibling": fs.replaceDirectories([Self.metadata, Self.xcode, Self.metadata + "/other"])
        case "symlink-root": fs.markSymbolicLink(Self.metadata)
        case "symlink-xcode": fs.markSymbolicLink(Self.xcode)
        default: fs.refuseListing(Self.xcode)
        }
        #expect(throws: (any Error).self) {
            try XcodeLocalPackageInputs.inventory(root: Self.packageRoot, module: "ArithmeticCore", fileSystem: fs)
        }
    }

    @Test("캡처 후 metadata의 생성 삭제 파일 하위 디렉터리 및 링크 변경은 final proof를 무효화한다",
        arguments: ["created-pair", "removed-pair", "file", "deeper", "symlink"])
    func postCaptureMutation(kind: String) throws {
        let (fixture, fs, _) = try fixture(origin: kind == "created-pair" ? "absent" : "capture-created")
        let bytes = try fs.readData(at: "/p/scope.json")
        let proof = XcodeLocalPackageProof(path: "/p/scope.json", root: "/p", fingerprint: fixture.base.fingerprint,
            receiptDigest: TargetScopeStore.digest(bytes), indexStore: "/capture/DerivedData/Index.noindex/DataStore")
        try proof.verify(fileSystem: fs)
        switch kind {
        case "created-pair": fs.replaceDirectories([Self.metadata, Self.xcode])
        case "removed-pair": fs.replaceDirectories([])
        case "file": try fs.write(text: "unexpected", to: Self.xcode + "/metadata.json")
        case "deeper": fs.replaceDirectories([Self.metadata, Self.xcode, Self.xcode + "/empty"])
        default: fs.markSymbolicLink(Self.xcode)
        }
        #expect(throws: (any Error).self) { try proof.verify(fileSystem: fs) }
    }

    @Test("최초 package inventory 뒤 map을 읽는 중 생긴 metadata 파일도 마지막 대조가 거부한다")
    func mutationDuringVerification() throws {
        let (fixture, fs, _) = try fixture(origin: "preexisting")
        fs.writeOnRead(trigger: fixture.map, destination: Self.xcode + "/late.json")
        #expect(throws: (any Error).self) {
            try XcodeTargetScopeStore(fileSystem: fs).read(path: "/p/scope.json", root: "/p",
                fingerprint: fixture.base.fingerprint)
        }
        #expect(fs.didMutate)
    }

    private func fixture(origin: String) throws
        -> (XcodeLocalPackageEvidenceTests.Fixture, MetadataDirectoryFileSystem, CartographService) {
        var fixture = try XcodeLocalPackageEvidenceTests().fixture()
        let fs = MetadataDirectoryFileSystem(base: fixture.base.fs)
        if origin != "absent" { fs.replaceDirectories([Self.metadata, Self.xcode]) }
        let inventory = try XcodeLocalPackageInputs.inventory(root: Self.packageRoot,
            module: "ArithmeticCore", fileSystem: fs)
        try fixture.changePackage { $0["inventory"] = inventory; $0["generatedMetadataOrigin"] = origin }
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration, environment: .init(fileSystem: fs,
            indexProviderOverride: StaticIndexProvider(fixture.base.snapshot), usesSyntaxCache: false))
        fixture.base.receipt["inputFingerprint"] = try service.sessionInputFingerprint()
        try fixture.base.write()
        return (fixture, fs, service)
    }
}

/// 메모리 filesystem이 표현하지 않는 빈 디렉터리와 링크/열거 실패만 명시적으로 덧붙인다.
private final class MetadataDirectoryFileSystem: FileSystem, @unchecked Sendable {
    let base: InMemoryFileSystem
    private let lock = NSLock()
    private var directories: Set<String> = []
    private var links: Set<String> = []
    private var refused: Set<String> = []
    private var readMutation: (trigger: String, destination: String)?
    private var mutated = false
    var didMutate: Bool { lock.withLock { mutated } }
    init(base: InMemoryFileSystem) { self.base = base }
    func replaceDirectories(_ paths: Set<String>) { lock.withLock { directories = paths } }
    func markSymbolicLink(_ path: String) { lock.withLock { _ = links.insert(path) } }
    func refuseListing(_ path: String) { lock.withLock { _ = refused.insert(path) } }
    func writeOnRead(trigger: String, destination: String) {
        lock.withLock { readMutation = (trigger, destination) }
    }
    func realPath(at path: String) throws -> String {
        if lock.withLock({ links.contains(path) }) { return "/outside/linked-directory" }
        return try base.realPath(at: path)
    }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool {
        lock.withLock { directories.contains(path) } || base.directoryExists(at: path)
    }
    func contentsOfDirectory(at path: String) throws -> [String] {
        try directoryEntries(at: path, maximumEntries: Int.max).map(\.path)
    }
    func directoryEntries(at path: String, maximumEntries: Int) throws -> [DirectoryEntry] {
        let (extra, symbolic, unavailable) = lock.withLock { (directories, links, refused.contains(path)) }
        guard !unavailable else { throw CocoaError(.fileReadNoPermission) }
        var entries = Dictionary(uniqueKeysWithValues: try base.directoryEntries(at: path,
            maximumEntries: maximumEntries).map { ($0.path, $0) })
        for child in extra where (child as NSString).deletingLastPathComponent == path {
            entries[child] = .init(path: child, isDirectory: true, isRegularFile: false,
                isSymbolicLink: symbolic.contains(child))
        }
        guard entries.count <= maximumEntries else { throw CocoaError(.fileReadTooLarge) }
        return entries.values.sorted { $0.path < $1.path }
    }
    func readData(at path: String) throws -> Data { try readData(at: path, maximumBytes: Int.max - 1) }
    func readData(at path: String, maximumBytes: Int) throws -> Data {
        let bytes = try base.readData(at: path, maximumBytes: maximumBytes)
        let destination = lock.withLock { () -> String? in
            guard !mutated, let readMutation, readMutation.trigger == path else { return nil }
            mutated = true
            return readMutation.destination
        }
        if let destination { try base.write(text: "created during proof read", to: destination) }
        return bytes
    }
    func modificationDate(at path: String) -> Date? { base.modificationDate(at: path) }
    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    var currentDirectoryPath: String { base.currentDirectoryPath }
}
