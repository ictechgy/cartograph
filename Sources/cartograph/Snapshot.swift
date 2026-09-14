import ArgumentParser
import CartographCore
import CartographKit
import Foundation

/// 현재 분석 입력을 자체 포함 스냅샷으로 저장한다.
struct SnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Capture an analysis snapshot for historical impact comparison."
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .customLong("revision"), help: "Optional user-supplied revision label.")
    var revision: String?

    @Option(name: .customLong("runtime-contracts"), help: "runtime-contracts v1 JSON to carry into impact comparisons.")
    var runtimeContracts: String?

    @Option(
        name: .customLong("coredata-build-evidence"),
        help: "Verified coredata-build-evidence v1 used only for this snapshot."
    )
    var coreDataBuildEvidence: String?

    func validate() throws {
        guard options.since == nil else {
            throw ValidationError("--since cannot be combined with snapshot; snapshot captures the whole index")
        }
        guard options.level == nil else {
            throw ValidationError("--level cannot be combined with snapshot; snapshots always capture the symbol graph")
        }
        guard options.reportFormat == nil else {
            throw ValidationError("--report-format cannot be combined with snapshot; output is always JSON")
        }
        guard !options.strict else {
            throw ValidationError("--strict cannot be combined with snapshot; it records facts, not findings")
        }
        guard options.baselinePath == nil else {
            throw ValidationError("--baseline cannot be combined with snapshot; baselines do not affect captured facts")
        }
        guard revision.map(Self.nonEmpty) ?? true else {
            throw ValidationError("--revision cannot be empty")
        }
        guard coreDataBuildEvidence.map(Self.nonEmpty) ?? true else {
            throw ValidationError("--coredata-build-evidence cannot be empty")
        }
    }

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        let contracts = try runtimeContracts.map {
            try RuntimeEvidenceStore(fileSystem: context.fileSystem).contracts(
                at: GlobalOptions.absolutePath($0, relativeTo: context.fileSystem.currentDirectoryPath)
            )
        }
        let coreDataContext = try coreDataBuildEvidence.map {
            try context.service.coreDataRuntimeContext(
                evidencePath: GlobalOptions.absolutePath($0, relativeTo: context.fileSystem.currentDirectoryPath)
            )
        }
        let document = try context.service.captureSnapshot(
            revision: revision,
            runtimeContracts: contracts,
            in: coreDataContext
        )
        try CommandSupport.emit(
            CommandOutcome(output: try Self.encode(document)),
            options: options,
            context: context
        )
    }

    private static func nonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func encode(_ document: AnalysisSnapshotDocument) throws -> String {
        let data = try JSONEncoder.cartographDefault().encode(document)
        guard data.count <= AnalysisSnapshotDocument.maximumByteCount else {
            throw CartographError.invalidConfiguration(path: document.projectRoot,
                reason: "Snapshot exceeds 128 MiB. Narrow the documented analysis scope before capture.")
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
