import CartographCore
import CartographAnalysis
import CartographSyntax
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
        var mapped = IndexStoreProvider.snapshot(from: result.occurrences, includeExternalSymbols: false)
        mapped.indexedFileDates = result.indexedFileDates
        mapped.oldestIndexedFileDates = result.oldestIndexedFileDates
        let snapshot = SnapshotEnricher().enrich(mapped)
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let changedType = try #require(snapshot.symbols.first { $0.name == "Changed" && $0.kind == .classType })
        let changed = try #require(snapshot.symbols.first { $0.name == "send()" && $0.parentUSR == changedType.usr })
        let seed: Set<NodeID> = [NodeID(changed.usr)]
        let original = ImpactAnalyzer().analyze(changing: seed, in: graph)
        // These files were just compiled from the repository checkout and read by
        // SnapshotEnricher. Ordinary product queries additionally rehash their bytes.
        let evidence = DispatchImpactEvidence(snapshot: snapshot,
            verifiedSourcePaths: Set(files.map(\.path)))
        let refined = ImpactAnalyzer().analyze(changing: seed, in: graph, receiverEvidence: evidence)
        func affectedNames(_ report: ImpactReport) -> Set<String> {
            Set(report.affected.compactMap { graph.node($0.node)?.name })
        }
        let before = affectedNames(original)
        let after = affectedNames(refined)
        let callableType = try #require(snapshot.symbols.first { $0.name == "CallableChanged" && $0.kind == .classType })
        let callable = try #require(snapshot.symbols.first {
            $0.name == "callAsFunction()" && $0.parentUSR == callableType.usr
        })
        let callableOriginal = ImpactAnalyzer().analyze(changing: [NodeID(callable.usr)], in: graph)
        let callableRefined = ImpactAnalyzer().analyze(changing: [NodeID(callable.usr)], in: graph,
            receiverEvidence: evidence)
        let callableOccurrences = result.occurrences.filter {
            $0.roles.contains(.call) && $0.symbol.name == "callAsFunction()"
        }
        if let evidenceParent {
            let comparison: [String: Any] = [
                "baseline": before.sorted(), "refined": after.sorted(),
                "mode": refined.receiverPrecision?.mode ?? "unavailable",
                "excludedTransitions": refined.receiverPrecision?.excludedTransitions ?? 0,
                "boundSelfCalls": (snapshot.dispatchReceiverFiles ?? []).flatMap(\.selfCalls).count,
                "finalClasses": (snapshot.dispatchReceiverFiles ?? []).flatMap(\.finalClassUSRs),
                "callableBaseline": affectedNames(callableOriginal).sorted(),
                "callableRefined": affectedNames(callableRefined).sorted(),
                "callableCallOccurrences": callableOccurrences.count,
                "callableReceivedByOccurrences": callableOccurrences.filter {
                    $0.relations.contains { $0.roles.contains(.receivedBy) }
                }.count,
                "runtimeExecuted": false,
            ]
            try JSONSerialization.data(withJSONObject: comparison, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidenceParent.appendingPathComponent("receiver-comparison.json"))
        }
        let excluded: Set<String> = ["siblingShared()", "factorySiblingShared()", "explicitSiblingShared()",
            "siblingConstructor()"]
        try #require(excluded.isSubset(of: before), "Legacy graph did not reproduce the sibling candidates")
        #expect(excluded.isDisjoint(with: after), "\(after.sorted())")
        #expect(refined.receiverPrecision?.mode == "bounded-final-self")
        let retained: Set<String> = ["changedShared()", "polymorphic(_:)", "aliasSiblingShared()",
            "siblingOtherChanged()", "nonfinalSiblingShared()", "existential(_:)"]
        #expect(retained.isSubset(of: after), "\(after.sorted())")
        let callableRetained: Set<String> = ["callableSiblingLocal()", "callableSiblingProperty()",
            "callableSiblingNamedValue()", "callableChangedSelf()", "callableSiblingWrapper()"]
        #expect(callableRetained.isSubset(of: affectedNames(callableOriginal)))
        #expect(callableRetained.isSubset(of: affectedNames(callableRefined)))
        #expect(affectedNames(callableOriginal).contains("callableSiblingSelf()"))
        // Even explicit self.callAsFunction() can name a callable property.
        // This first capability therefore leaves all callAsFunction paths intact.
        #expect(affectedNames(callableRefined).contains("callableSiblingSelf()"))
        #expect(!callableOccurrences.isEmpty)
        // Same captured topology without ephemeral source joins remains conservative.
        let encoded = try JSONEncoder().encode(snapshot)
        let historical = try JSONDecoder().decode(IndexSnapshot.self, from: encoded)
        let historicalReport = ImpactAnalyzer().analyze(changing: seed, in: graph,
            receiverEvidence: DispatchImpactEvidence(snapshot: historical,
                verifiedSourcePaths: Set(files.map(\.path))))
        #expect(historicalReport.affected == original.affected)
        try CompilerEvidenceSupport.phase("receiver-assertions-complete", logs: logs)
        completed = true
    }
}
