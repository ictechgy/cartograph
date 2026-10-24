import ArgumentParser
import CartographKit
import Foundation

/// 안전한 기계적 수정을 계획하고, 요청하면 적용한다.
struct FixCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fix",
        abstract: "Plan or apply mechanical edits for unused imports and unused parameters; rebuild to verify.",
        discussion: """
            Only two warning classes are fixed: `unused-import` removes the import declaration, and
            `unused-parameter` drops the parameter's internal name while keeping its argument label.
            The default is a dry run that writes nothing; pass --apply to edit the files.

            Every edit is located in the current source and the rewritten file must parse before it
            is written. A declaration whose position no longer matches, a line carrying other code,
            and a result that does not parse are reported as skipped, never guessed at. Writes are
            atomic per file.
            Parsing does not prove type correctness or build compatibility. Review the plan and
            rebuild all relevant targets after applying it. Optionally pass --verify-command as a JSON argv
            array with --apply to run one trusted command at the project root. Failure, timeout or SIGINT/SIGTERM
            restores unchanged Cartograph-owned edits. Conflicting edits are retained with private recovery backups.
            The verifier inherits the environment and is not a sandbox; its other side effects are not reverted.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Flag(
        name: .customLong("apply"),
        help: "Write the fixes. Without it, print the plan and change nothing."
    )
    var apply: Bool = false

    @Option(name: .customLong("verify-command"),
            help: "Explicit verification argv as a JSON string array; requires --apply. No shell is used.")
    var verifyCommand: String?

    @Option(name: .customLong("verify-timeout"), help: "Verification timeout in seconds (0.1...86400; default: 600).")
    var verifyTimeout: Double?

    @Option(name: .customLong("recovery-directory"),
            help: "New private directory outside the project for original bytes, journal and verifier logs.")
    var recoveryDirectory: String?

    @Option(name: .customLong("format"), help: "text or json.")
    var format: FixFormat = .text

    func validate() throws {
        if verifyCommand != nil {
            guard apply else { throw ValidationError("--verify-command requires --apply") }
            _ = try verificationArguments()
        } else if verifyTimeout != nil || recoveryDirectory != nil {
            throw ValidationError("--verify-timeout and --recovery-directory require --verify-command")
        }
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
        let context = try CommandSupport.makeContext(options, readsBaseline: true)
        let signals = verifyCommand == nil ? nil : FixSignalGuard()
        defer { withExtendedLifetime(signals) {} }
        let verification = try verifyCommand.map { _ in
            MechanicalFixVerification(arguments: try verificationArguments(), timeoutSeconds: verifyTimeout ?? 600,
                                      recoveryDirectory: recoveryDirectory, interruption: { signals?.interruption },
                                      beginInterruptionHandling: { signals?.activate() })
        }
        try CommandSupport.emit(
            try context.service.mechanicalFixes(apply: apply, format: format.rawValue, verification: verification),
            options: options,
            context: context
        )
    }

    private func verificationArguments() throws -> [String] {
        guard let verifyCommand, let data = verifyCommand.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String].self, from: data),
              !arguments.isEmpty, !arguments[0].isEmpty,
              arguments.allSatisfy({ !$0.utf8.contains(0) }),
              (verifyTimeout ?? 600).isFinite, (0.1...86_400).contains(verifyTimeout ?? 600) else {
            throw ValidationError("--verify-command must be a nonempty JSON argv array without NUL; "
                + "--verify-timeout must be 0.1...86400")
        }
        return arguments
    }
}

/// `fix --format` 의 출력 형식.
enum FixFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json
}
