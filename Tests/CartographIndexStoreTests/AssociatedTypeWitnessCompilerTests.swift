import CartographCore
@testable import CartographIndexStore
import Foundation
import IndexStoreDB
import Testing

@Suite("associatedtype witness의 실제 컴파일러 기록", .serialized)
struct AssociatedTypeWitnessCompilerTests {
    @Test("별칭 이름 참조가 없는 Combine 준수의 원시 근거를 보존한다")
    func capturesCombineWitnessEvidence() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = repo.appendingPathComponent(
            "Fixtures/FalsePositiveCorpus/AssociatedWitness/Sources/WitnessApp")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-associated-witness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        #expect(files.count == 5)
        let store = root.appendingPathComponent("IndexStore")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.currentDirectoryURL = root
        process.arguments = ["swiftc", "-module-name", "WitnessApp", "-index-store-path", store.path]
            + files.map(\.path) + ["-o", root.appendingPathComponent("WitnessApp").path]
        let diagnostics = Pipe()
        process.standardError = diagnostics
        try process.run()
        let message = String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(message)")
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        let library = try IndexStoreLocator().locateLibrary(explicitPath: nil, developerDirectory: nil)
        let result = try RawIndexStoreReader(storePath: store.path, libraryPath: library,
            fileSystem: LocalFileSystem()).read(in: Set(files.map(\.path)))
        let aliases = result.occurrences.filter {
            $0.roles.contains(.definition) && $0.symbol.kind == .typealias && $0.symbol.subKind == .none
        }
        #expect(aliases.count == 8)
        #expect(Set(aliases.map(\.location.moduleName)) == ["WitnessApp"])

        // 현재 compiler가 제공한 사실을 잃기 전에 보존한다. 이 진단 자체는 보존 수정의 통과가 아니다.
        if let path = ProcessInfo.processInfo.environment["CARTOGRAPH_ASSOCIATED_WITNESS_EVIDENCE"] {
            let destination = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let records = result.occurrences.map(Record.init).sorted {
                ($0.path, $0.line, $0.column, $0.usr, $0.roles) < ($1.path, $1.line, $1.column, $1.usr, $1.roles)
            }
            try encoder.encode(records).write(to: destination)
        }

        let snapshot = IndexStoreProvider.snapshot(from: result.occurrences, includeExternalSymbols: false)
        let witnesses = Set(snapshot.references.filter {
            $0.origin == .compiler && $0.kind == .overrides && $0.targetKind == .associatedType
        }.map(\.sourceUSR))
        let publisherAliases = Set(aliases.filter {
            URL(fileURLWithPath: $0.location.path).lastPathComponent != "Unrelated.swift"
        }.map { $0.symbol.usr })
        let unrelatedAliases = Set(aliases.filter {
            URL(fileURLWithPath: $0.location.path).lastPathComponent == "Unrelated.swift"
        }.map { $0.symbol.usr })
        #expect(publisherAliases.count == 6)
        #expect(publisherAliases.isSubset(of: witnesses))
        #expect(unrelatedAliases.isDisjoint(with: witnesses))
    }

    private struct Record: Encodable {
        let usr: String
        let name: String
        let kind: String
        let subKind: String
        let path: String
        let module: String
        let line: Int
        let column: Int
        let roles: UInt64
        let roleNames: [String]
        let relations: [Relation]

        init(_ occurrence: SymbolOccurrence) {
            usr = occurrence.symbol.usr
            name = occurrence.symbol.name
            kind = String(describing: occurrence.symbol.kind)
            subKind = String(describing: occurrence.symbol.subKind)
            path = URL(fileURLWithPath: occurrence.location.path).lastPathComponent
            module = occurrence.location.moduleName
            line = occurrence.location.line
            column = occurrence.location.utf8Column
            roles = UInt64(occurrence.roles.rawValue)
            roleNames = Self.names(occurrence.roles)
            relations = occurrence.relations.map {
                Relation(usr: $0.symbol.usr, name: $0.symbol.name,
                    kind: String(describing: $0.symbol.kind), subKind: String(describing: $0.symbol.subKind),
                    roles: UInt64($0.roles.rawValue), roleNames: Self.names($0.roles))
            }.sorted { ($0.usr, $0.roles) < ($1.usr, $1.roles) }
        }

        private static func names(_ roles: SymbolRole) -> [String] {
            let known: [(SymbolRole, String)] = [
                (.declaration, "declaration"), (.definition, "definition"), (.reference, "reference"),
                (.implicit, "implicit"), (.childOf, "childOf"), (.baseOf, "baseOf"),
                (.overrideOf, "overrideOf"), (.containedBy, "containedBy"), (.calledBy, "calledBy"),
                (.extendedBy, "extendedBy"), (.receivedBy, "receivedBy"),
            ]
            return known.filter { roles.contains($0.0) }.map(\.1)
        }
    }

    private struct Relation: Encodable {
        let usr: String
        let name: String
        let kind: String
        let subKind: String
        let roles: UInt64
        let roleNames: [String]
    }
}
