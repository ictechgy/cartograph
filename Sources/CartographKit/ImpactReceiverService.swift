import CartographAnalysis
import CartographCore
import CryptoKit
import Foundation

extension CartographService {
    /// Saved snapshots deliberately have no source receiver capability. A held
    /// current context also loses precision when source bytes change, even if a
    /// caller preserved the file timestamp. Verification has a separate budget.
    func impactReceiverEvidence(context: AnalysisContext, historical: Bool,
                                changing: Set<NodeID>, graph: CodeGraph) ->
        (evidence: DispatchImpactEvidence?, limitations: [String], files: [DispatchReceiverFileFacts]) {
        guard !historical, let files = context.snapshot.dispatchReceiverFiles, !files.isEmpty else {
            return (nil, [], [])
        }
        let finalOwners = Set(files.flatMap(\.finalClassUSRs).map { NodeID($0) })
        guard changing.contains(where: { id in
            graph.semanticParent(of: id).map { finalOwners.contains($0) } == true
                && graph.outgoingEdges(from: id).contains { $0.kind == .overrides }
        }) else { return (nil, [], []) }
        var remaining = 64 * 1024 * 1024
        let maximumFileBytes = 8 * 1024 * 1024
        var verified: Set<String> = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let expected = file.sourceDigest, remaining > 0 else { continue }
            let cap = min(maximumFileBytes, remaining)
            remaining -= cap
            guard let bytes = try? environment.fileSystem.readData(at: file.path, maximumBytes: cap),
                  bytes.count <= cap else { continue }
            remaining += cap - bytes.count
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            if actual == expected { verified.insert(file.path) }
        }
        let limitations = verified.count == files.count ? [] : [
            "receiver-source-unverified: \(files.count - verified.count) file(s) lack current matching source bytes; "
                + "their paths remain conservative (8 MiB per file, 64 MiB total verification budget)"
        ]
        return (DispatchImpactEvidence(snapshot: context.snapshot, verifiedSourcePaths: verified), limitations,
            files.filter { verified.contains($0.path) })
    }

    /// Recheck the same admitted source set after traversal and output preparation.
    /// Two bounded observations detect intervening edits; they do not lock the
    /// filesystem or establish an atomic source/build snapshot.
    func impactReceiverFinalFailure(_ files: [DispatchReceiverFileFacts]) -> String? {
        var remaining = 64 * 1024 * 1024
        var failed = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let expected = file.sourceDigest, remaining > 0 else { failed += 1; continue }
            let cap = min(8 * 1024 * 1024, remaining)
            remaining -= cap
            guard let bytes = try? environment.fileSystem.readData(at: file.path, maximumBytes: cap),
                  bytes.count <= cap else { failed += 1; continue }
            remaining += cap - bytes.count
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            if actual != expected { failed += 1 }
        }
        return failed == 0 ? nil : "receiver-source-changed-during-query: \(failed) of \(files.count) "
            + "admitted source file(s) changed, became unreadable or exceeded the final verification budget; "
            + "the complete legacy candidate result was restored (8 MiB per file, 64 MiB per pass)"
    }

    static func receiverLimitations(_ report: ImpactReport) -> [String] {
        guard let precision = report.receiverPrecision else { return [] }
        return ["receiver-precision: \(precision.mode); excluded \(precision.excludedTransitions) transition(s); "
            + "state budget \(precision.stateBudget); transition budget \(precision.transitionBudget ?? 0); "
            + "examined transitions \(precision.examinedTransitions ?? 0); work budget \(precision.workBudget ?? 0); "
            + "examined work \(precision.examinedWork ?? 0); raw reference budget \(precision.referenceBudget ?? 0); "
            + "admitted references \(precision.admittedReferences ?? 0); \(precision.reason ?? "unknown")"]
    }
}
