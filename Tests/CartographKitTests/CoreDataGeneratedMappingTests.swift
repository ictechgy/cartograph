import CartographCore
@testable import CartographKit
import CartographSyntax
import CartographTestSupport
import Foundation
import Testing

/// 생성 소스 여러 개와 class 생성 엔티티 여러 개를 짝짓는 검증이 결과를 바꾸지 않고 반복 비용만 줄였는지.
///
/// 예전 검증은 경로 N개 × 엔티티 N개의 모든 쌍마다 파일을 다시 읽고 파싱했고, 짝이 맞을 때마다 기본
/// 스냅샷 전체를 다시 훑었다. 읽기 횟수로 반복을 고정하고, 충돌·신선도 거부가 그대로인지 함께 본다.
@Suite("Core Data 생성 클래스 매핑 검증")
struct CoreDataGeneratedMappingTests {
    private static let collisionReason = "A different indexed declaration has the same USR or runtime class name."

    @Test("엔티티 세 개의 생성 소스는 경로마다 한 번만 읽고 엔티티 순 매핑을 만든다")
    func readsEachGeneratedSourceOnce() throws {
        let fixture = try GeneratedFixture(names: ["Gamma", "Alpha", "Beta"])
        defer { fixture.remove() }
        // 같은 파일을 링크 디렉터리로 가리킨 철자도 같은 파일로 본다: 충돌이 아니고 신선도 근거로 쓰인다.
        let aliasAlpha = try #require(fixture.aliasPath(for: "Alpha"))
        let base = fixture.baseContext(symbols: [fixture.symbol("Alpha", path: aliasAlpha)])
        let snapshot = fixture.supplemental(freshnessPaths: ["Beta": try #require(fixture.aliasPath(for: "Beta"))])

        let mappings = try fixture.verify(snapshot: snapshot, base: base)

        #expect(mappings == ["Alpha", "Beta", "Gamma"].map { name in
            CoreDataDeclaredGeneratedMappingInput(
                entityName: name, sourcePath: fixture.path(for: name), module: "Probe",
                declarationUSRs: [fixture.usr(name)]
            )
        })
        #expect(fixture.fileSystem.readCounts == Dictionary(uniqueKeysWithValues: fixture.paths.map { ($0, 1) }))
    }

    @Test("다른 파일에 같은 USR 선언이 있으면 여전히 거부한다")
    func rejectsUSRCollisionInAnotherFile() throws {
        let fixture = try GeneratedFixture(names: ["Alpha", "Beta", "Gamma"])
        defer { fixture.remove() }
        let base = fixture.baseContext(symbols: [fixture.symbol("Beta", path: fixture.root + "/Other/Beta.swift")])

        #expect(throws: CartographError.invalidConfiguration(
            path: fixture.path(for: "Beta"), reason: Self.collisionReason
        )) {
            try fixture.verify(snapshot: fixture.supplemental(), base: base)
        }
    }

    @Test("다른 파일의 class 선언이 같은 런타임 이름을 드러내면 여전히 거부한다", arguments: [true, false])
    func rejectsRuntimeNameCollisionInAnotherFile(usesObjectiveCName: Bool) throws {
        let fixture = try GeneratedFixture(names: ["Alpha", "Beta", "Gamma"])
        defer { fixture.remove() }
        let other = CartographCore.SourceLocation(
            path: fixture.root + "/Other/Legacy.swift", line: 3, column: 7
        )
        // @objc 이름이 같거나, @objc 이름 없이 같은 모듈·같은 이름이면 런타임 클래스 이름이 겹친다.
        let declaration = RuntimeDeclaration(
            name: usesObjectiveCName ? "Legacy" : "Gamma", indexName: "Gamma", qualifiedName: "Gamma",
            kind: .classType, location: other, endLocation: other,
            objectiveCName: usesObjectiveCName ? "Probe.Gamma" : nil
        )
        let indexed = IndexedSymbol(usr: "s:5Probe6LegacyC", name: "Gamma", kind: .classType, module: "Probe",
            location: other)
        let base = AnalysisContext(
            snapshot: IndexSnapshot(symbols: [indexed]),
            runtimeFiles: [RuntimeFileFacts(path: other.path, declarations: [declaration])]
        )

        #expect(throws: CartographError.invalidConfiguration(
            path: fixture.path(for: "Gamma"), reason: Self.collisionReason
        )) {
            try fixture.verify(snapshot: fixture.supplemental(), base: base)
        }
    }

    @Test("인덱스 unit 보다 새 생성 소스는 여전히 거부한다")
    func rejectsGeneratedSourceNewerThanIndex() throws {
        let fixture = try GeneratedFixture(names: ["Alpha", "Beta", "Gamma"])
        defer { fixture.remove() }
        let snapshot = fixture.supplemental(staleNames: ["Alpha"])

        #expect(throws: CartographError.invalidConfiguration(
            path: fixture.path(for: "Alpha"), reason: "The generated source needs a current compiler index unit."
        )) {
            try fixture.verify(snapshot: snapshot, base: fixture.baseContext(symbols: []))
        }
    }
}

/// momc 가 만드는 모양의 생성 클래스 파일과 그 보충 인덱스를 손으로 만든다.
private struct GeneratedFixture {
    let root: String
    let names: [String]
    let fileSystem = ReadCountingFileSystem()

    init(names: [String]) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-generated-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base + "/Generated", withIntermediateDirectories: true)
        root = try LocalFileSystem().realPath(at: base)
        self.names = names
        try FileManager.default.createSymbolicLink(atPath: root + "/Alias", withDestinationPath: root + "/Generated")
        for name in names {
            try Data(Self.source(name).utf8).write(to: URL(fileURLWithPath: path(for: name)))
        }
    }

    var paths: [String] { names.map(path(for:)) }

    func path(for name: String) -> String { root + "/Generated/\(name)+CoreDataClass.swift" }

    /// 같은 파일을 링크 디렉터리로 가리키는 다른 철자.
    func aliasPath(for name: String) -> String? {
        names.contains(name) ? root + "/Alias/\(name)+CoreDataClass.swift" : nil
    }

    func usr(_ name: String) -> String { "s:5Probe\(name.utf8.count)\(name)C" }

    func remove() {
        do { try FileManager.default.removeItem(atPath: root) }
        catch { Issue.record("임시 디렉터리를 지우지 못했다: \(error)") }
    }

    static func source(_ name: String) -> String {
        "import Foundation\nimport CoreData\n\npublic typealias \(name)CoreDataClassSet = NSSet\n\n"
            + "public class \(name): NSManagedObject {\n}\n"
    }

    /// 생성 클래스 이름 토큰의 위치. 컴파일러 인덱스도 같은 자리를 기록한다.
    func location(for name: String, path: String) -> CartographCore.SourceLocation? {
        CoreDataGeneratedClassScanner.inspect(
            source: Self.source(name), path: path, expectedClassName: name,
            expectedRuntimeName: "Probe.\(name)", module: "Probe"
        ).location
    }

    func symbol(_ name: String, path: String) -> IndexedSymbol {
        let location = location(for: name, path: path)
            ?? CartographCore.SourceLocation(path: path, line: 1, column: 1)
        return IndexedSymbol(usr: usr(name), name: name, kind: .classType, module: "Probe", location: location)
    }

    func supplemental(freshnessPaths: [String: String] = [:], staleNames: Set<String> = []) -> IndexSnapshot {
        let dates = Dictionary(uniqueKeysWithValues: names.map { name in
            (freshnessPaths[name] ?? path(for: name), staleNames.contains(name) ? Date.distantPast : .distantFuture)
        })
        return IndexSnapshot(
            symbols: names.map { symbol($0, path: path(for: $0)) },
            references: names.map {
                IndexedReference(sourceUSR: usr($0), targetUSR: "c:objc(cs)NSManagedObject", kind: .inheritance)
            },
            indexedFileDates: dates
        )
    }

    func baseContext(symbols: [IndexedSymbol]) -> AnalysisContext {
        AnalysisContext(snapshot: IndexSnapshot(symbols: symbols), runtimeFiles: [])
    }

    func verify(snapshot: IndexSnapshot, base: AnalysisContext) throws -> [CoreDataDeclaredGeneratedMappingInput] {
        var configuration = CartographConfiguration.default
        configuration.projectPath = root
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(IndexSnapshot())
            )
        )
        let entities = names.map {
            CoreDataBuildEntityEvidence(
                name: $0, representedClassName: "Probe.\($0)", managedObjectClassName: "Probe.\($0)",
                codeGenerationType: "class"
            )
        }
        return try service.verifiedGeneratedMappings(
            requirements: entities, allEntities: entities, sourcePaths: paths, module: "Probe",
            snapshot: snapshot, baseContext: base
        )
    }
}

/// 실제 디스크를 그대로 읽으면서 경로마다 내용 읽기 횟수를 센다.
private final class ReadCountingFileSystem: FileSystem, @unchecked Sendable {
    private let base = LocalFileSystem()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    var readCounts: [String: Int] { lock.withLock { counts } }

    func readData(at path: String) throws -> Data {
        lock.withLock { counts[path, default: 0] += 1 }
        return try base.readData(at: path)
    }

    func readData(at path: String, maximumBytes: Int) throws -> Data {
        lock.withLock { counts[path, default: 0] += 1 }
        return try base.readData(at: path, maximumBytes: maximumBytes)
    }

    func realPath(at path: String) throws -> String { try base.realPath(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    func removeItem(at path: String) throws { try base.removeItem(at: path) }
    func contentsOfDirectory(at path: String) throws -> [String] { try base.contentsOfDirectory(at: path) }
    func directoryEntries(at path: String) throws -> [DirectoryEntry] { try base.directoryEntries(at: path) }
    func modificationDate(at path: String) -> Date? { base.modificationDate(at: path) }
    func fingerprintStamp(at path: String) -> FileFingerprintStamp? { base.fingerprintStamp(at: path) }
    var currentDirectoryPath: String { base.currentDirectoryPath }
}
