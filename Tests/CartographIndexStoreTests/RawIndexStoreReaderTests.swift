import CartographCore
@testable import CartographIndexStore
import Foundation
import Testing

@Suite("실제 컴파일러의 공유 소스 레코드", .serialized)
struct RawIndexStoreReaderTests {
    @Test("공개 구성의 기본 판독기 모드는 기존 databaseBacked이고 raw를 명시할 수 있다")
    func readerModeDefaultsAndOverrides() {
        let base = IndexStoreProvider.Configuration(
            storePath: "/store", databasePath: "/db", libraryPath: "/lib", sourceRoots: []
        )
        let raw = IndexStoreProvider.Configuration(
            storePath: "/store", databasePath: "/db", libraryPath: "/lib", sourceRoots: [], readerMode: .raw
        )

        #expect(base.readerMode == .databaseBacked)
        #expect(raw.readerMode == .raw)
    }

    @Test("알 수 없는 컴파일러 언어를 Swift로 추측하지 않는다")
    func unknownLanguageFails() {
        #expect(throws: (any Error).self) { try RawIndexStoreReader.language(.init(rawValue: 255)) }
    }

    @Test("읽을 수 없는 유닛은 요청 파일과의 관계를 확인할 수 없어 전체 읽기에 실패한다")
    func unclassifiableUnitFails() throws {
        let fixture = try makeFixture()
        try Data("invalid unit metadata".utf8).write(to: fixture.store
            .appendingPathComponent("v5/units/unrelated.o-CORRUPT"))
        let reader = RawIndexStoreReader(
            storePath: fixture.store.path, libraryPath: fixture.library, fileSystem: LocalFileSystem()
        )
        #expect(throws: (any Error).self) { try reader.occurrences(in: [fixture.source.path]) }
    }
    @Test("상대 소스와 링크 경로를 두 모듈의 실제 선언 위치에 결합한다")
    func sharedRecordsKeepCanonicalLocations() throws {
        let fixture = try makeFixture()
        let fileSystem = LocalFileSystem()
        let physicalPath = try fileSystem.realPath(at: fixture.source.path)
        let link = fixture.root.appendingPathComponent("Linked.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
        let reader = RawIndexStoreReader(
            storePath: fixture.store.path, libraryPath: fixture.library, fileSystem: fileSystem
        )
        for path in [fixture.source.path, link.path, fileSystem.canonicalPath(physicalPath)] {
            let occurrences = try reader.occurrences(in: [path])
            let definitions = occurrences.filter { $0.roles.contains(.definition) && $0.symbol.name == "Payload" }
            #expect(Set(definitions.map(\.location.moduleName)) == ["SyntheticAlpha", "SyntheticBeta"])
            #expect(definitions.count == 2)
            #expect(definitions.allSatisfy { $0.location.path == physicalPath })
            let snapshot = IndexStoreProvider.snapshot(from: occurrences, includeExternalSymbols: false)
            #expect(snapshot.fileModuleUsages[physicalPath]?.owningModule == nil)
            #expect(snapshot.fileModuleUsages[physicalPath]?.hasUnattributedReferences == true)
            for module in ["SyntheticAlpha", "SyntheticBeta"] {
                let payload = try #require(snapshot.symbols.first { $0.module == module && $0.name == "Payload" })
                let owner = try #require(snapshot.symbols.first { $0.module == module && $0.kind == .enumCase })
                #expect(snapshot.references.contains { $0.sourceUSR == owner.usr && $0.targetUSR == payload.usr })
                #expect(!snapshot.references.contains {
                    $0.sourceUSR == owner.usr && $0.targetUSR != payload.usr && $0.targetKind == .structType
                })
            }
        }
        #expect(try reader.occurrences(in: [fixture.root.appendingPathComponent("Unrequested.swift").path]).isEmpty)
        let provider = IndexStoreProvider(configuration: .init(
            storePath: fixture.store.path, databasePath: fixture.root.appendingPathComponent("ReaderDB").path,
            libraryPath: fixture.library, sourceRoots: [link.path]
        ))
        let snapshot = try provider.loadSnapshot()
        #expect(snapshot.symbols.contains { $0.name == "Payload" && $0.location.path == physicalPath })
        #expect(snapshot.indexedFileDates?[physicalPath] != nil)
    }

    @Test("raw 결과는 발생이 있는 파일의 유닛 최신 시각을 함께 반환한다")
    func rawReadResultCarriesIndexedFileDates() throws {
        let fixture = try makeFixture()
        let fileSystem = LocalFileSystem()
        let physicalPath = try fileSystem.realPath(at: fixture.source.path)
        let reader = RawIndexStoreReader(
            storePath: fixture.store.path, libraryPath: fixture.library, fileSystem: fileSystem
        )

        let result = try reader.read(in: [fixture.source.path])

        #expect(!result.occurrences.isEmpty)
        #expect(result.indexedFileDates[physicalPath] != nil)
    }

    @Test("raw 모드는 기존 DB 모드와 공유 소스의 그래프와 날짜를 맞춘다")
    func rawModeMatchesDatabaseMode() throws {
        let fixture = try makeFixture()
        let fileSystem = LocalFileSystem()
        let makeProvider: (IndexStoreProvider.ReaderMode) -> IndexStoreProvider = { mode in
            IndexStoreProvider(configuration: .init(
                storePath: fixture.store.path,
                databasePath: fixture.root.appendingPathComponent("Reader-\(mode)").path,
                libraryPath: fixture.library,
                sourceRoots: [fixture.root.path],
                readerMode: mode
            ), fileSystem: fileSystem)
        }

        let database = try makeProvider(.databaseBacked).loadSnapshot()
        let raw = try makeProvider(.raw).loadSnapshot()

        #expect(raw.symbols == database.symbols)
        #expect(Set(raw.references) == Set(database.references))
        #expect(datesMatch(raw.indexedFileDates, database.indexedFileDates))
        let unitDates = try FileManager.default.contentsOfDirectory(at: fixture.store
            .appendingPathComponent("v5/units"), includingPropertiesForKeys: [.contentModificationDateKey])
            .compactMap { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let physicalPath = try fileSystem.realPath(at: fixture.source.path)
        #expect(closeEnough(raw.indexedFileDates?[physicalPath], unitDates.max()))
    }

    @Test(
        "raw 모드는 판독기 캐시를 만들지 않고 잘못된 라이브러리를 전용 오류로 보고한다"
    )
    func rawModeSkipsDatabaseAndPreservesLibraryError() throws {
        let fixture = try makeFixture()
        let databasePath = fixture.root.appendingPathComponent("ReaderDB").path
        let invalidLibrary = fixture.root.appendingPathComponent("missing-libIndexStore.dylib").path
        let provider = IndexStoreProvider(configuration: .init(
            storePath: fixture.store.path,
            databasePath: databasePath,
            libraryPath: invalidLibrary,
            sourceRoots: [fixture.root.path],
            readerMode: .raw
        ))

        #expect(throws: CartographError.indexStoreLibraryNotFound(searchedPaths: [invalidLibrary])) {
            try provider.loadSnapshot()
        }
        #expect(!FileManager.default.fileExists(atPath: databasePath))
    }

    @Test("유닛이 하나도 없어도 raw 결과는 지원되는 빈 날짜 사전을 반환한다")
    func emptyRawStoreReturnsNonNilDates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-raw-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("IndexStore")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let library = try IndexStoreLocator().locateLibrary(explicitPath: nil, developerDirectory: nil)
        let reader = RawIndexStoreReader(
            storePath: store.path, libraryPath: library, fileSystem: LocalFileSystem()
        )

        let result = try reader.read(in: [root.appendingPathComponent("Missing.swift").path])

        #expect(result.occurrences.isEmpty)
        #expect(result.indexedFileDates.isEmpty)
    }

    @Test("발생이 없는 실제 Swift 레코드도 유닛 시각을 보존한다")
    func emptySwiftRecordKeepsIndexedDate() throws {
        let fixture = try makeEmptySwiftFixture()
        let fileSystem = LocalFileSystem()
        let physicalPath = try fileSystem.realPath(at: fixture.source.path)
        let reader = RawIndexStoreReader(
            storePath: fixture.store.path, libraryPath: fixture.library, fileSystem: fileSystem
        )

        let result = try reader.read(in: [fixture.source.path])

        #expect(result.occurrences.isEmpty)
        #expect(result.indexedFileDates[physicalPath] != nil)
    }

    @Test("Objective-C의 사용자 레코드와 SDK file 의존성 날짜를 실제 인덱스에서 보존한다")
    func objectiveCFileDependencyKeepsSystemDate() throws {
        let fixture = try makeObjectiveCFixture()
        let fileSystem = LocalFileSystem()
        let paths = [fixture.source.path, fixture.header.path, fixture.systemHeader]
        let reader = RawIndexStoreReader(
            storePath: fixture.store.path, libraryPath: fixture.library, fileSystem: fileSystem
        )

        let result = try reader.read(in: Set(paths))
        let physicalSystemHeader = try fileSystem.realPath(at: fixture.systemHeader)

        #expect(result.indexedFileDates[physicalSystemHeader] != nil)
        #expect(!result.occurrences.contains { $0.location.path == physicalSystemHeader })

        let database = try IndexStoreProvider(configuration: .init(
            storePath: fixture.store.path,
            databasePath: fixture.root.appendingPathComponent("ReaderDB").path,
            libraryPath: fixture.library,
            sourceRoots: [fixture.root.path],
            includeObjectiveCSources: true
        )).loadSnapshot()
        let physicalSource = try fileSystem.realPath(at: fixture.source.path)
        #expect(closeEnough(result.indexedFileDates[physicalSource], database.indexedFileDates?[physicalSource]))
    }

    @Test("Objective-C 파일 root의 raw 공급자는 디렉터리 root의 기존 공급자와 같다")
    func objectiveCFileRootsMatchDatabaseProvider() throws {
        let fixture = try makeObjectiveCFixture()
        let fileSystem = LocalFileSystem()
        let baseline = try IndexStoreProvider(configuration: .init(
            storePath: fixture.store.path,
            databasePath: fixture.root.appendingPathComponent("ParityDB").path,
            libraryPath: fixture.library,
            sourceRoots: [fixture.root.path],
            includeObjectiveCSources: true
        )).loadSnapshot()
        let raw = try IndexStoreProvider(configuration: .init(
            storePath: fixture.store.path,
            databasePath: fixture.root.appendingPathComponent("UnusedRawDB").path,
            libraryPath: fixture.library,
            sourceRoots: [fixture.source.path],
            includeObjectiveCSources: true,
            readerMode: .raw
        )).loadSnapshot()
        #expect(!raw.symbols.isEmpty)
        #expect(raw.symbols == baseline.symbols)
        #expect(raw.references == baseline.references)
        #expect(raw.parameters == baseline.parameters)
        #expect(raw.fileModuleUsages == baseline.fileModuleUsages)
        #expect(Set(raw.indexedFileDates?.keys ?? Dictionary<String, Date>().keys)
            == Set(baseline.indexedFileDates?.keys ?? Dictionary<String, Date>().keys))
        for (path, date) in raw.indexedFileDates ?? [:] {
            #expect(closeEnough(date, baseline.indexedFileDates?[path]))
        }
        let physicalHeader = try fileSystem.realPath(at: fixture.header.path)
        // .h와 SDK 헤더는 기존 sourceFilePaths의 분석 대상에 포함되지 않는다.
        #expect(raw.indexedFileDates?[physicalHeader] == nil)
        #expect(baseline.indexedFileDates?[physicalHeader] == nil)
        #expect(!FileManager.default.fileExists(atPath:
            fixture.root.appendingPathComponent("UnusedRawDB").path))
    }

    @Test("요청한 컴파일 레코드가 깨졌으면 부분 스냅샷을 성공으로 반환하지 않는다")
    func unreadableRequestedRecordFails() throws {
        let fixture = try makeFixture()
        let records = fixture.store.appendingPathComponent("v5/records")
        let enumerator = try #require(FileManager.default.enumerator(at: records, includingPropertiesForKeys: nil))
        let record = try #require(enumerator.compactMap { $0 as? URL }.first {
            $0.lastPathComponent.hasPrefix("Shared.swift-")
        })
        try Data("invalid requested compiler record".utf8).write(to: record)
        let reader = RawIndexStoreReader(
            storePath: fixture.store.path, libraryPath: fixture.library, fileSystem: LocalFileSystem()
        )
        #expect(throws: (any Error).self) { try reader.occurrences(in: [fixture.source.path]) }
    }

    @Test("많은 공유 레코드도 bounded cache 안에서 두 모듈 문맥을 모두 보존한다")
    func sharedRecordsStayWithinBoundedCache() throws {
        let fixture = try makeManySharedRecordsFixture(count: 70)
        let reader = RawIndexStoreReader(
            storePath: fixture.store.path, libraryPath: fixture.library, fileSystem: LocalFileSystem()
        )
        var peakReaders = 0
        var peakQueue = 0

        let result = try reader.read(in: Set(fixture.sources)) { readers, queue in
            peakReaders = max(peakReaders, readers)
            peakQueue = max(peakQueue, queue)
        }
        let definitions = result.occurrences.filter { $0.roles.contains(.definition) }
        let sharedDefinitions = definitions.filter { $0.symbol.name.hasPrefix("Shared") }

        #expect(peakReaders <= 64)
        #expect(peakQueue <= 64)
        #expect(sharedDefinitions.count == fixture.sources.count * 2)
        #expect(Set(definitions.map(\.location.moduleName)) == ["SyntheticAlpha", "SyntheticBeta"])

        let baseline = try IndexStoreProvider(configuration: .init(
            storePath: fixture.store.path,
            databasePath: fixture.root.appendingPathComponent("ExternalParityDB").path,
            libraryPath: fixture.library,
            sourceRoots: [fixture.root.path],
            includeExternalSymbols: true,
            includeSelfReferences: true
        )).loadSnapshot()
        let raw = try IndexStoreProvider(configuration: .init(
            storePath: fixture.store.path,
            databasePath: fixture.root.appendingPathComponent("UnusedExternalRawDB").path,
            libraryPath: fixture.library,
            sourceRoots: fixture.sources,
            includeExternalSymbols: true,
            includeSelfReferences: true,
            readerMode: .raw
        )).loadSnapshot()
        #expect(raw.symbols == baseline.symbols)
        #expect(raw.references == baseline.references)
        #expect(raw.parameters == baseline.parameters)
        #expect(raw.fileModuleUsages == baseline.fileModuleUsages)
        #expect(Set(raw.indexedFileDates?.keys ?? Dictionary<String, Date>().keys)
            == Set(baseline.indexedFileDates?.keys ?? Dictionary<String, Date>().keys))
        for (path, date) in raw.indexedFileDates ?? [:] {
            #expect(closeEnough(date, baseline.indexedFileDates?[path]))
        }
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let store: URL
        let library: String
    }

    private struct ObjectiveCFixture {
        let root: URL
        let source: URL
        let header: URL
        let store: URL
        let library: String
        let systemHeader: String
    }

    private struct ManySharedRecordsFixture {
        let root: URL
        let sources: [String]
        let store: URL
        let library: String
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-raw-records-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Shared.swift")
        try Data("public struct Payload {}\npublic enum Endpoint { case payload(Payload) }\n".utf8).write(to: source)
        let store = root.appendingPathComponent("IndexStore")
        for module in ["SyntheticAlpha", "SyntheticBeta"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.currentDirectoryURL = root
            process.arguments = [
                "swiftc", "-module-name", module, "-parse-as-library", "-emit-object", "Shared.swift",
                "-o", root.appendingPathComponent("\(module).o").path, "-index-store-path", store.path,
            ]
            let diagnostics = Pipe()
            process.standardError = diagnostics
            try process.run()
            let message = String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(message)")
            guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        }
        let library = try IndexStoreLocator().locateLibrary(explicitPath: nil, developerDirectory: nil)
        return Fixture(root: root, source: source, store: store, library: library)
    }

    private func datesMatch(_ lhs: [String: Date]?, _ rhs: [String: Date]?) -> Bool {
        guard let lhs, let rhs, lhs.keys == rhs.keys else { return lhs == nil && rhs == nil }
        return lhs.allSatisfy { closeEnough($0.value, rhs[$0.key]) }
    }

    private func closeEnough(_ lhs: Date?, _ rhs: Date?, tolerance: TimeInterval = 1e-6) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) <= tolerance
    }

    private func makeEmptySwiftFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-raw-empty-swift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Empty.swift")
        try Data("// no declarations\n".utf8).write(to: source)
        let store = root.appendingPathComponent("IndexStore")
        try runCompiler(
            executable: "/usr/bin/xcrun",
            arguments: ["swiftc", "-module-name", "EmptySwift", "-parse-as-library", "-emit-object",
                        source.lastPathComponent, "-o", "EmptySwift.o", "-index-store-path", store.path],
            in: root
        )
        let library = try IndexStoreLocator().locateLibrary(explicitPath: nil, developerDirectory: nil)
        return Fixture(root: root, source: source, store: store, library: library)
    }

    private func makeObjectiveCFixture() throws -> ObjectiveCFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-raw-objective-c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Caller.m")
        let header = root.appendingPathComponent("Header.h")
        let sourceText = "#include \"Header.h\"\n#include <stdio.h>\n"
            + "int readHeader(void) { return headerValue() + EOF; }\n"
        try Data(sourceText.utf8).write(to: source)
        try Data("#define HEADER_VALUE 7\nstatic inline int headerValue(void) { return HEADER_VALUE; }\n".utf8)
            .write(to: header)
        let store = root.appendingPathComponent("IndexStore")
        try runCompiler(
            executable: "/usr/bin/xcrun",
            arguments: ["clang", "-c", source.lastPathComponent, "-o", "Caller.o", "-index-store-path", store.path],
            in: root
        )
        let sdk = try runCompiler(
            executable: "/usr/bin/xcrun", arguments: ["--sdk", "macosx", "--show-sdk-path"], in: root
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let systemHeader = (sdk as NSString).appendingPathComponent("usr/include/stdio.h")
        let library = try IndexStoreLocator().locateLibrary(explicitPath: nil, developerDirectory: nil)
        return ObjectiveCFixture(
            root: root, source: source, header: header, store: store, library: library, systemHeader: systemHeader
        )
    }

    private func makeManySharedRecordsFixture(count: Int) throws -> ManySharedRecordsFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-raw-many-records-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let names = (0..<count).map { "Shared\($0).swift" }
        for (index, name) in names.enumerated() {
            try Data("public struct Shared\(index) {}\n".utf8)
                .write(to: root.appendingPathComponent(name))
        }
        let store = root.appendingPathComponent("IndexStore")
        for module in ["SyntheticAlpha", "SyntheticBeta"] {
            let outputMap = Dictionary(uniqueKeysWithValues: names.map {
                ($0, ["object": "\(module)-\($0).o"])
            })
            let outputMapData = try JSONSerialization.data(withJSONObject: outputMap, options: [.sortedKeys])
            let outputMapPath = root.appendingPathComponent("\(module)-output-map.json")
            try outputMapData.write(to: outputMapPath)
            try runCompiler(
                executable: "/usr/bin/xcrun",
                arguments: ["swiftc", "-module-name", module, "-parse-as-library", "-emit-object",
                            "-output-file-map", outputMapPath.lastPathComponent]
                    + names + ["-index-store-path", store.path],
                in: root
            )
        }
        let library = try IndexStoreLocator().locateLibrary(explicitPath: nil, developerDirectory: nil)
        return ManySharedRecordsFixture(
            root: root,
            sources: names.map { root.appendingPathComponent($0).path },
            store: store,
            library: library
        )
    }

    @discardableResult
    private func runCompiler(executable: String, arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = directory
        process.arguments = arguments
        let diagnostics = Pipe()
        process.standardError = diagnostics
        process.standardOutput = diagnostics
        try process.run()
        let output = String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RawIndexStoreReaderTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: output,
            ])
        }
        return output
    }
}
