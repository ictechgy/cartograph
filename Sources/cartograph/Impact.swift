import ArgumentParser
import Foundation
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

            --format language-traversal emits one multi-root traversal for isthmus trace: every
            declaration argument is a root, and each reached declaration lists every root that
            reaches it. --direction dependencies follows callees instead of consumers.
            --roots-from <file|-> reads more roots from a file or stdin: one root per line (blank
            lines and lines starting with # are skipped), a JSON string array, or a bridge-facts
            document whose facts' symbol.usr become roots. They follow the positional roots;
            duplicates are dropped, the input is at most 16 MiB and the total at most 10000 roots.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Declarations to inspect, by name, qualified name or USR.")
    var symbols: [String] = []

    /// 순회 root 를 파일이나 표준 입력(`-`)에서 더 읽는다. 위치 인자 root 뒤에 붙고 같은 문자열은 한 번만 쓴다.
    ///
    /// root 가 수천 개면 argv 상한에 걸리므로 isthmus capture 가 이 옵션으로 넘긴다. 형식은 ``TraversalRootList`` 다.
    @Option(
        name: .customLong("roots-from"),
        help: """
            language-traversal only: more roots from a file, or - for stdin — one per line (# comments), \
            a JSON string array, or a bridge-facts document (its facts' symbol.usr). At most 16 MiB.
            """
    )
    var rootsFrom: String?

    @Option(name: .customLong("file"), help: "Source file to inspect; repeat for multiple files.")
    var files: [String] = []

    @Option(name: .customLong("depth"), help: "Maximum consumer depth from 1 through 128.")
    var depth: Int?

    @Option(
        name: .customLong("limit"),
        help: "Maximum affected declarations to report (default: 200; language-traversal: 100000)."
    )
    var limit: Int?

    @Option(
        name: .customLong("direction"),
        help: "language-traversal only: dependents (consumers, the default) or dependencies (callees)."
    )
    var direction: ImpactDirection?

    @Option(
        name: .customLong("generated-at"),
        help: "language-traversal only: fixed ISO-8601 UTC timestamp for byte-identical output."
    )
    var generatedAt: String?

    @Option(
        name: .customLong("revision"),
        help: "language-traversal only: source revision to record. Default: the git HEAD when the project has no uncommitted changes."
    )
    var revision: String?

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

    @Option(name: .customLong("format"), help: "text, json (change-impact v1) or language-traversal (isthmus v1).")
    var format: ImpactFormat = .text

    /// 형식마다 기본 한도와 상한이 다르다. 순회 문서는 isthmus 계약의 도달 정점 상한까지 싣는다.
    var resolvedLimit: Int {
        limit ?? (format == .languageTraversal ? 100_000 : 200)
    }

    func validate() throws {
        // `--roots-from` 도 선언 선택이다. 파일·since 와 섞으면 선택 모드 검사가 거부한다.
        let hasSymbols = !symbols.isEmpty || rootsFrom != nil
        let hasFiles = !files.isEmpty
        let hasSince = options.since != nil
        let modeCount = [hasSymbols, hasFiles, hasSince].filter { $0 }.count

        guard modeCount == 1 else {
            throw ValidationError(
                "give exactly one selector: a declaration, --file <path>, or --since <revision>"
            )
        }
        guard symbols.allSatisfy(Self.isNonEmpty), files.allSatisfy(Self.isNonEmpty),
              rootsFrom.map(Self.isNonEmpty) ?? true else {
            throw ValidationError("impact selectors cannot be empty")
        }
        guard options.since.map(Self.isNonEmpty) ?? true else {
            throw ValidationError("--since revision cannot be empty")
        }
        guard depth.map({ (1...128).contains($0) }) ?? true else {
            throw ValidationError("--depth must be between 1 and 128")
        }
        if format == .languageTraversal {
            try validateLanguageTraversal()
        } else {
            try validateChangeImpactOnlyOptions()
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

    /// 순회 문서는 선언 root 만 받는다. 파일·스냅샷·실행 근거는 `change-impact` 의 입력이다.
    private func validateLanguageTraversal() throws {
        guard !symbols.isEmpty || rootsFrom != nil else {
            throw ValidationError("--format language-traversal takes declaration roots; --file and --since are not supported")
        }
        if let bad = (symbols + (revision.map { [$0] } ?? [])).first(where: ExchangeText.containsControlCharacter) {
            throw ValidationError("--format language-traversal roots and --revision cannot contain control characters "
                + "(\(bad.debugDescription)); isthmus rejects such ids. Pass the symbol.usr from routes or bridges facts.")
        }
        guard revision.map(Self.isNonEmpty) ?? true else {
            throw ValidationError("--revision cannot be empty")
        }
        guard symbols.count <= 10_000 else {
            throw ValidationError("--format language-traversal accepts at most 10000 roots")
        }
        guard (1...100_000).contains(resolvedLimit) else {
            throw ValidationError("--limit must be between 1 and 100000 for language-traversal")
        }
        let unsupported = [("--before", before), ("--trace", trace), ("--runtime-contracts", runtimeContracts),
                           ("--coredata-build-evidence", coreDataBuildEvidence)].filter { $0.1 != nil }.map(\.0)
        guard unsupported.isEmpty else {
            throw ValidationError("\(unsupported.joined(separator: ", ")) cannot be combined with "
                + "--format language-traversal; the traversal covers the compiler graph and automatic runtime facts")
        }
        guard generatedAt.map({ Self.parseTimestamp($0) != nil }) ?? true else {
            throw ValidationError("--generated-at must be an ISO-8601 UTC timestamp such as 2026-01-01T00:00:00Z")
        }
    }

    private func validateChangeImpactOnlyOptions() throws {
        guard (1...10_000).contains(resolvedLimit) else {
            throw ValidationError("--limit must be between 1 and 10000")
        }
        guard direction == nil, generatedAt == nil, revision == nil, rootsFrom == nil else {
            throw ValidationError("--direction, --generated-at, --revision and --roots-from require --format language-traversal")
        }
    }

    /// 소수 초가 있든 없든 ISO-8601 UTC 시각을 받는다.
    static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    func run() throws {
        if format == .languageTraversal {
            try runLanguageTraversal()
            return
        }
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
            let changed = try ChangedSelectionSupport.files(
                reference: reference, projectPath: context.service.projectPath
            )
            selectedFiles.append(contentsOf: changed.files)
            selectionLimitations = changed.limitations
        }

        let runtimePath = runtimeContracts.map {
            GlobalOptions.absolutePath($0, relativeTo: context.fileSystem.currentDirectoryPath)
        }
        let outcome: CommandOutcome
        if let before {
            outcome = try context.service.compareImpact(
                symbols: symbols, files: selectedFiles,
                beforePath: GlobalOptions.absolutePath(before, relativeTo: context.fileSystem.currentDirectoryPath),
                maxDepth: depth, limit: resolvedLimit, format: format.rawValue,
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
                limit: resolvedLimit,
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

    private func runLanguageTraversal() throws {
        // root 파일은 인덱스를 열기 전에 읽고 검사한다. 색인을 다 만든 뒤에 형식 오류를 말하지 않는다.
        let roots = try TraversalRootInput.roots(positional: symbols, rootsFrom: rootsFrom, quiet: options.quiet)
        let context = try CommandSupport.makeContext(options)
        let outcome = try context.service.languageTraversal(
            symbols: roots, direction: (direction ?? .dependents).rawValue, maxDepth: depth,
            limit: resolvedLimit, generatedAt: generatedAt.flatMap(Self.parseTimestamp) ?? Date(),
            revision: revision ?? GitRevision.cleanHead(projectPath: context.service.projectPath)
        )
        try CommandSupport.emit(outcome, options: options, context: context)
    }

    private static func isNonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

}

/// `impact --format` 의 출력 형식.
enum ImpactFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json
    /// isthmus `language-traversal` v1. 다중 root 순회와 정점별 root 출처를 싣는다.
    case languageTraversal = "language-traversal"
}

/// `impact --direction` 의 값. `language-traversal` 문서의 `direction` 과 같다.
enum ImpactDirection: String, ExpressibleByArgument, CaseIterable {
    case dependents
    case dependencies
}

/// `--since` 로 시드할 파일 목록과, 모델 밖 변경을 알리는 한계 문구.
///
/// `impact` 와 `affected` 가 같은 시드를 쓰도록 절차를 한 곳에 둔다. 갈라지면
/// 같은 변경에 대해 두 명령이 다른 파일을 시작점으로 삼는다.
enum ChangedSelectionSupport {
    /// 보고서와 문서를 소스 선택으로 혼동하지 않는다. 모델 밖 변경도 응답의 limitations에 남긴다.
    static func isModeledChange(_ path: String) -> Bool {
        [".swift", ".m", ".mm", ".h"].contains { path.hasSuffix($0) }
            || RuntimeResourcePath.isSupported(path)
    }

    static func files(
        reference: String,
        projectPath: String
    ) throws -> (files: [String], limitations: [String]) {
        let changed = try ChangedFiles.since(
            reference,
            workingDirectory: projectPath,
            includingDeleted: true
        )
        let outsideModel = changed.filter { !isModeledChange($0) }.sorted()
        var limitations: [String] = []
        if !outsideModel.isEmpty {
            limitations.append("unmodeled-changed-files: \(outsideModel.count) change(s) are outside "
                + "Swift/Objective-C/runtime resource selection: " + outsideModel.prefix(10).joined(separator: ", ")
                + (outsideModel.count > 10 ? ", …" : "")
                + ". Review build scripts, configuration and resources separately; noChanges means no modeled source changes.")
        }
        return (changed.filter(isModeledChange).sorted(), limitations)
    }
}
