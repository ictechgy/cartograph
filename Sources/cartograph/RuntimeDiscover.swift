import ArgumentParser
import CartographCore
import CartographKit
import Foundation

/// 수동 계약 없이 발견한 연결과 미해결 경계를 점검한다.
struct RuntimeDiscoverCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "discover",
        abstract: "Discover runtime dependencies from indexed Swift source and Interface Builder resources.")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Maximum displayed boundaries and target/candidate subjects (1...10000).")
    var limit: Int = 200
    @Option(name: .customLong("trace"), help: "runtime-trace v1 JSON produced by `runtime collect`.")
    var tracePath: String?
    @Option(name: .customLong("executable"), help: "Exact executable used to produce --trace.")
    var executablePath: String?
    @Option(
        name: .customLong("coredata-build-evidence"),
        help: "Verified coredata-build-evidence v1 used only for this discovery."
    )
    var coreDataBuildEvidencePath: String?

    func validate() throws {
        guard (1...10_000).contains(limit) else { throw ValidationError("--limit must be between 1 and 10000") }
        guard (tracePath == nil) == (executablePath == nil) else {
            throw ValidationError("--trace and --executable must be supplied together")
        }
        guard tracePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true,
              executablePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else {
            throw ValidationError("--trace and --executable cannot be empty")
        }
        guard coreDataBuildEvidencePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else {
            throw ValidationError("--coredata-build-evidence cannot be empty")
        }
        guard tracePath == nil || coreDataBuildEvidencePath == nil else {
            throw ValidationError("--trace cannot be combined with --coredata-build-evidence")
        }
        guard options.level == nil, options.since == nil, options.reportFormat == nil,
              options.baselinePath == nil else {
            throw ValidationError("runtime discover uses the complete symbol graph and JSON; "
                + "--level, --since, --report-format and --baseline are not supported")
        }
    }

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        if let tracePath, let executablePath {
            let cwd = context.fileSystem.currentDirectoryPath
            let document = try context.service.runtimeTraceDiscoveryDocument(
                tracePath: GlobalOptions.absolutePath(tracePath, relativeTo: cwd),
                executablePath: GlobalOptions.absolutePath(executablePath, relativeTo: cwd),
                limit: limit
            )
            let data = try JSONEncoder.cartographDefault().encode(document)
            let incomplete = document.observed.status == "partial"
                ? "runtime trace evidence is incomplete or stale; no observed edges were accepted"
                : nil
            try CommandSupport.emit(
                .init(
                    output: String(decoding: data, as: UTF8.self) + "\n",
                    findingCount: document.needsReviewCount,
                    incompleteAnalysis: incomplete
                ),
                options: options,
                context: context
            )
            return
        }
        let evidence = try coreDataBuildEvidencePath.map {
            try context.service.coreDataRuntimeContext(
                evidencePath: GlobalOptions.absolutePath($0, relativeTo: context.fileSystem.currentDirectoryPath)
            )
        }
        let document = try context.service.runtimeDiscoveryDocument(limit: limit, in: evidence)
        let data = try JSONEncoder.cartographDefault().encode(document)
        try CommandSupport.emit(.init(output: String(decoding: data, as: UTF8.self) + "\n",
            findingCount: document.unresolvedCount), options: options, context: context)
    }
}
