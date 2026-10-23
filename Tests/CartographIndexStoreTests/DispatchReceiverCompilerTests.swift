import CartographCore
@testable import CartographIndexStore
import Foundation
import IndexStoreDB
import Testing

@Suite("dispatch receiver의 실제 컴파일러 기록", .serialized)
struct DispatchReceiverCompilerTests {
    @Test("형제와 실제 다형 호출의 receiver 관계를 매핑 전에 보존한다")
    func capturesReceiverEvidence() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = repo.appendingPathComponent("Fixtures/FalsePositiveCorpus/DispatchReceivers")
        let evidencePath = ProcessInfo.processInfo.environment["CARTOGRAPH_DISPATCH_RECEIVER_EVIDENCE"]
        let evidenceParent = evidencePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        let logs = (evidenceParent ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("cartograph-dispatch-receiver-\(UUID().uuidString)")
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
        try #require(files.count == 3)
        let store = root.appendingPathComponent("IndexStore")
        let arguments = ["-module-name", "DispatchReceivers", "-index-store-path", store.path]
            + files.map(\.path) + ["-o", root.appendingPathComponent("DispatchReceivers").path]
        try CompilerEvidenceSupport.phase("toolchain-lookup-and-compiler-start-deadline-240s", logs: logs)
        let selectedLibrary = try CompilerEvidenceSupport.compile(arguments, in: root, repo: repo, logs: logs)
        let library = try IndexStoreLocator().locateLibrary(explicitPath: selectedLibrary, developerDirectory: nil)
        try CompilerEvidenceSupport.phase("raw-index-read-start", logs: logs)
        let result = try RawIndexStoreReader(storePath: store.path, libraryPath: library,
            fileSystem: LocalFileSystem()).read(in: Set(files.map(\.path)))
        try CompilerEvidenceSupport.phase("raw-index-read-complete-occurrences-\(result.occurrences.count)", logs: logs)
        let records = result.occurrences.map(CompilerEvidenceSupport.Record.init).sorted {
            ($0.path, $0.line, $0.column, $0.usr, $0.roles) < ($1.path, $1.line, $1.column, $1.usr, $1.roles)
        }
        // Export first, so a compiler-format change remains inspectable after an assertion failure.
        if let path = evidencePath {
            let destination = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: destination)
        }
        let definitions = result.occurrences.filter { $0.roles.contains(.definition) }
        let names = Set(definitions.map(\.symbol.name))
        let expected: Set<String> = ["Base", "Changed", "Sibling", "Sender", "sharedSelf()",
            "sharedExplicitSelf()", "sharedAlias()", "sharedOther(_:)", "siblingShared()",
            "changedShared()", "factorySiblingShared()", "polymorphic(_:)", "siblingOtherChanged()",
            "existential(_:)", "siblingExistential()", "changedExistential()"]
        try #require(expected.isSubset(of: names))
        try #require(result.occurrences.contains { $0.roles.contains(.call) && $0.symbol.name == "send()" })
        try #require(result.occurrences.contains { occurrence in
            occurrence.symbol.name == "send()" && occurrence.relations.contains { $0.roles.contains(.overrideOf) }
        })
        // No assertion invents a receiver relation the selected compiler did not produce.
        // The records are evidence for a subsequent bounded implementation, not precision proof.
        try CompilerEvidenceSupport.phase("receiver-assertions-complete", logs: logs)
        completed = true
    }
}
