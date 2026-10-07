import CartographCore
@testable import CartographIndexStore
import Foundation
import Testing

@Suite("실제 컴파일러의 공유 소스 레코드", .serialized)
struct RawIndexStoreReaderTests {
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

    private struct Fixture {
        let root: URL
        let source: URL
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
}
