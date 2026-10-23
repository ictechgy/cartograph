import CartographCore
@testable import CartographIndexStore
import Dispatch
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
        let evidencePath = ProcessInfo.processInfo.environment["CARTOGRAPH_ASSOCIATED_WITNESS_EVIDENCE"]
        let evidenceParent = evidencePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        let logs = (evidenceParent ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("cartograph-associated-witness-\(UUID().uuidString)")
        let root = logs.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var completed = false
        defer {
            if completed {
                try? FileManager.default.removeItem(at: evidencePath == nil ? logs : root)
            } else {
                try? CompilerEvidenceSupport.phase("fixture-preserved-after-failure-or-unknown-cleanup", logs: logs)
            }
        }
        try CompilerEvidenceSupport.phase("fixture-created", logs: logs)
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        try #require(files.count == 5)
        let store = root.appendingPathComponent("IndexStore")
        let arguments = ["-module-name", "WitnessApp", "-index-store-path", store.path]
            + files.map(\.path) + ["-o", root.appendingPathComponent("WitnessApp").path]
        try CompilerEvidenceSupport.phase("toolchain-lookup-and-compiler-start-deadline-240s", logs: logs)
        let selectedLibrary = try CompilerEvidenceSupport.compile(arguments, in: root, repo: repo, logs: logs)
        try CompilerEvidenceSupport.phase("compiler-complete", logs: logs)
        try CompilerEvidenceSupport.phase("validate-selected-index-library-start", logs: logs)
        let library = try IndexStoreLocator().locateLibrary(explicitPath: selectedLibrary, developerDirectory: nil)
        try CompilerEvidenceSupport.phase("raw-index-read-start", logs: logs)
        let result = try RawIndexStoreReader(storePath: store.path, libraryPath: library,
            fileSystem: LocalFileSystem()).read(in: Set(files.map(\.path)))
        try CompilerEvidenceSupport.phase("raw-index-read-complete-occurrences-\(result.occurrences.count)", logs: logs)
        let aliases = result.occurrences.filter {
            $0.roles.contains(.definition) && $0.symbol.kind == .typealias && $0.symbol.subKind == .none
        }

        // 현재 compiler가 제공한 사실을 잃기 전에 보존한다. 이 진단 자체는 보존 수정의 통과가 아니다.
        if let path = evidencePath {
            let destination = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let records = result.occurrences.map(CompilerEvidenceSupport.Record.init).sorted {
                ($0.path, $0.line, $0.column, $0.usr, $0.roles) < ($1.path, $1.line, $1.column, $1.usr, $1.roles)
            }
            try encoder.encode(records).write(to: destination)
        }

        try #require(aliases.count == 8)
        try #require(Set(aliases.map(\.location.moduleName)) == ["WitnessApp"])
        try CompilerEvidenceSupport.phase("snapshot-mapping-start", logs: logs)
        let snapshot = IndexStoreProvider.snapshot(from: result.occurrences, includeExternalSymbols: false)
        try CompilerEvidenceSupport.phase("snapshot-mapping-complete", logs: logs)
        let witnesses = Set(snapshot.references.filter {
            $0.origin == .compiler && $0.kind == .overrides && $0.targetKind == .associatedType
        }.map(\.sourceUSR))
        let publisherAliases = Set(aliases.filter {
            URL(fileURLWithPath: $0.location.path).lastPathComponent != "Unrelated.swift"
        }.map { $0.symbol.usr })
        let unrelatedAliases = Set(aliases.filter {
            URL(fileURLWithPath: $0.location.path).lastPathComponent == "Unrelated.swift"
        }.map { $0.symbol.usr })
        try #require(publisherAliases.count == 6)
        try #require(publisherAliases.isSubset(of: witnesses))
        try #require(unrelatedAliases.isDisjoint(with: witnesses))
        try CompilerEvidenceSupport.phase("witness-assertions-complete", logs: logs)
        completed = true
    }

}
