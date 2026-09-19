import ArgumentParser
import CartographCore
import CartographKit

/// 변경에 도달하는 테스트를 답한다.
struct AffectedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "affected",
        abstract: "List the tests that reach a change.",
        discussion: """
            Answers the CI question "which tests does this change touch": starting from the changed
            declarations or files, consumers are followed until test declarations are found. Give
            exactly one selector — a declaration, --file <path>, or --since <revision>.

            The answer is static reachability over the symbol graph, not a test run. An empty list
            means no test declaration was found on a consumer path; it does not prove that existing
            tests cover the change. `impact` remains the wider report of every affected declaration.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Declarations to start from, by name, qualified name or USR.")
    var symbols: [String] = []

    @Option(name: .customLong("file"), help: "Source file to start from; repeat for multiple files.")
    var files: [String] = []

    @Option(name: .customLong("depth"), help: "Maximum consumer depth from 1 through 128.")
    var depth: Int?

    @Option(name: .customLong("limit"), help: "Maximum test declarations to report (default: 200).")
    var limit: Int = 200

    @Option(name: .customLong("format"), help: "text or json.")
    var format: AffectedFormat = .text

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
            throw ValidationError("affected selectors cannot be empty")
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
            throw ValidationError("--level cannot be combined with affected; test reachability follows symbol consumers")
        }
        guard options.reportFormat == nil else {
            throw ValidationError("--report-format cannot be combined with affected; use --format")
        }
        guard !options.strict else {
            throw ValidationError("--strict cannot be combined with affected; affected reports facts, not findings")
        }
    }

    func run() throws {
        // `--since` 는 순회의 입력 시드다. 전역 범위를 그대로 넘기면 결과
        // 소비자까지 변경 파일로 잘려, 바깥의 테스트가 사라진다.
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
        let outcome = try context.service.affected(
            symbols: symbols,
            files: selectedFiles,
            maxDepth: depth,
            limit: limit,
            format: format.rawValue,
            fileSelectionIsDerived: options.since != nil,
            selectionLimitations: selectionLimitations
        )
        try CommandSupport.emit(outcome, options: contextOptions, context: context)
    }

    private static func isNonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// `affected --format` 의 출력 형식.
enum AffectedFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json
}
