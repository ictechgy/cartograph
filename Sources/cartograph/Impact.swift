import ArgumentParser
import CartographCore
import CartographKit

/// 변경 전 영향 범위를 계산한다.
struct ImpactCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "impact",
        abstract: "Find the declarations and files affected by a change.",
        discussion: """
            Select one or more declarations, source files, or files changed since a git revision.
            The result follows direct and transitive consumers so a person or coding agent can
            review the likely effect before editing. A git selection includes deleted paths and
            both sides of a rename.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Declarations to inspect, by name, qualified name or USR.")
    var symbols: [String] = []

    @Option(name: .customLong("file"), help: "Source file to inspect; repeat for multiple files.")
    var files: [String] = []

    @Option(name: .customLong("depth"), help: "Maximum consumer depth from 1 through 128.")
    var depth: Int?

    @Option(name: .customLong("limit"), help: "Maximum affected declarations to report (default: 200).")
    var limit: Int = 200

    @Option(name: .customLong("runtime-contracts"), help: "Include declared runtime dependencies from runtime-contracts v1 JSON.")
    var runtimeContracts: String?

    @Option(name: .customLong("trace"), help: "Include automatically collected runtime-trace JSON.")
    var trace: String?
    @Option(name: .customLong("executable"), help: "Executable that produced --trace; required with --trace.")
    var runtimeExecutable: String?

    @Option(
        name: .customLong("coredata-build-evidence"),
        help: "Verified coredata-build-evidence v1 used only for current-build impact."
    )
    var coreDataBuildEvidence: String?

    @Option(name: .customLong("before"), help: "An analysis-snapshot v1 or v2 file captured before the change.")
    var before: String?

    @Option(name: .customLong("format"), help: "text or json.")
    var format: ImpactFormat = .text

    func validate() throws {
        let hasSymbols = !symbols.isEmpty
        let hasFiles = !files.isEmpty
        let hasSince = options.since != nil
        let modeCount = [hasSymbols, hasFiles, hasSince].filter { $0 }.count

        guard modeCount == 1 else {
            throw ValidationError(
                "give exactly one selector: a declaration, --file <path>, or --since <revision>"
            )
        }
        guard symbols.allSatisfy(Self.isNonEmpty), files.allSatisfy(Self.isNonEmpty) else {
            throw ValidationError("impact selectors cannot be empty")
        }
        guard options.since.map(Self.isNonEmpty) ?? true else {
            throw ValidationError("--since revision cannot be empty")
        }
        guard depth.map({ (1...128).contains($0) }) ?? true else {
            throw ValidationError("--depth must be between 1 and 128")
        }
        guard (1...10_000).contains(limit) else {
            throw ValidationError("--limit must be between 1 and 10000")
        }
        guard options.level == nil else {
            throw ValidationError("--level cannot be combined with impact; impact follows symbol consumers")
        }
        guard options.reportFormat == nil else {
            throw ValidationError("--report-format cannot be combined with impact; use --format")
        }
        guard !options.strict else {
            throw ValidationError("--strict cannot be combined with impact; impact reports facts, not findings")
        }
        guard (trace == nil) == (runtimeExecutable == nil) else {
            throw ValidationError("--trace and --executable must be supplied together")
        }
        guard before == nil || trace == nil else {
            throw ValidationError("--trace cannot be combined with --before; trace evidence belongs to one build")
        }
        guard trace == nil || coreDataBuildEvidence == nil else {
            throw ValidationError("--trace cannot be combined with --coredata-build-evidence")
        }
        guard coreDataBuildEvidence.map(Self.isNonEmpty) ?? true else {
            throw ValidationError("--coredata-build-evidence cannot be empty")
        }
    }

    func run() throws {
        // `--since` 는 영향 분석의 입력 시드다. 전역 옵션을 그대로 넘기면
        // 결과 소비자까지 변경 파일로 잘려, 바뀐 파일 밖의 영향이 사라진다.
        var contextOptions = options
        contextOptions.since = nil
        let context = try CommandSupport.makeContext(contextOptions)
        var selectedFiles = files.map {
            GlobalOptions.absolutePath($0, relativeTo: context.fileSystem.currentDirectoryPath)
        }
        var selectionLimitations: [String] = []
        if let reference = options.since {
            let changed = try ChangedFiles.since(
                reference,
                workingDirectory: context.service.projectPath,
                includingDeleted: true
            )
            selectedFiles.append(contentsOf: changed.filter(Self.isModeledChange).sorted())
            let outsideModel = changed.filter { !Self.isModeledChange($0) }.sorted()
            if !outsideModel.isEmpty {
                selectionLimitations.append("unmodeled-changed-files: \(outsideModel.count) change(s) are outside "
                    + "Swift/Objective-C/runtime resource selection: " + outsideModel.prefix(10).joined(separator: ", ")
                    + (outsideModel.count > 10 ? ", …" : "")
                    + ". Review build scripts, configuration and resources separately; noChanges means no modeled source changes.")
            }
        }

        let runtimePath = runtimeContracts.map {
            GlobalOptions.absolutePath($0, relativeTo: context.fileSystem.currentDirectoryPath)
        }
        let outcome: CommandOutcome
        if let before {
            outcome = try context.service.compareImpact(
                symbols: symbols, files: selectedFiles,
                beforePath: GlobalOptions.absolutePath(before, relativeTo: context.fileSystem.currentDirectoryPath),
                maxDepth: depth, limit: limit, format: format.rawValue,
                fileSelectionIsDerived: options.since != nil, runtimeContractsPath: runtimePath,
                selectionLimitations: selectionLimitations,
                coreDataBuildEvidencePath: coreDataBuildEvidence.map {
                    GlobalOptions.absolutePath($0, relativeTo: context.fileSystem.currentDirectoryPath)
                }
            )
        } else {
            outcome = try context.service.impact(
                symbols: symbols,
                files: selectedFiles,
                maxDepth: depth,
                limit: limit,
                format: format.rawValue,
                fileSelectionIsDerived: options.since != nil,
                runtimeContractsPath: runtimePath,
                selectionLimitations: selectionLimitations,
                runtimeTracePath: trace.map { GlobalOptions.absolutePath($0, relativeTo: context.fileSystem.currentDirectoryPath) },
                runtimeExecutablePath: runtimeExecutable.map {
                    GlobalOptions.absolutePath($0, relativeTo: context.fileSystem.currentDirectoryPath)
                },
                coreDataBuildEvidencePath: coreDataBuildEvidence.map {
                    GlobalOptions.absolutePath($0, relativeTo: context.fileSystem.currentDirectoryPath)
                }
            )
        }
        try CommandSupport.emit(
            outcome,
            options: contextOptions,
            context: context
        )
    }

    private static func isNonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 보고서와 문서를 소스 선택으로 혼동하지 않는다. 모델 밖 변경도 응답의 limitations에 남긴다.
    static func isModeledChange(_ path: String) -> Bool {
        [".swift", ".m", ".mm", ".h"].contains { path.hasSuffix($0) }
            || RuntimeResourcePath.isSupported(path)
    }
}

/// `impact --format` 의 출력 형식.
enum ImpactFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json
}
