import ArgumentParser
import CartographKit

/// 안전한 기계적 수정을 계획하고, 요청하면 적용한다.
struct FixCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fix",
        abstract: "Plan or apply the safe mechanical fixes for unused imports and unused parameters.",
        discussion: """
            Only two warning classes are fixed: `unused-import` removes the import declaration, and
            `unused-parameter` drops the parameter's internal name while keeping its argument label.
            The default is a dry run that writes nothing; pass --apply to edit the files.

            Every edit is located in the current source and the rewritten file must parse before it
            is written. A declaration whose position no longer matches, a line carrying other code,
            and a result that does not parse are reported as skipped, never guessed at. Writes are
            atomic per file.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Flag(
        name: .customLong("apply"),
        help: "Write the fixes. Without it, print the plan and change nothing."
    )
    var apply: Bool = false

    @Option(name: .customLong("format"), help: "text or json.")
    var format: FixFormat = .text

    func validate() throws {
        guard options.level == nil else {
            throw ValidationError(
                "--level cannot be combined with fix; the fixer works on symbol-level findings"
            )
        }
        guard options.reportFormat == nil else {
            throw ValidationError("--report-format cannot be combined with fix; use --format")
        }
    }

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        try CommandSupport.emit(
            try context.service.mechanicalFixes(apply: apply, format: format.rawValue),
            options: options,
            context: context
        )
    }
}

/// `fix --format` 의 출력 형식.
enum FixFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json
}
