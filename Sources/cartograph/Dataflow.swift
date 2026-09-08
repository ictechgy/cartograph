import ArgumentParser
import CartographCore
import CartographKit

/// 심볼 관계와 구별되는 호출별 값·부수 효과를 JSON으로 전달한다.
struct DataflowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dataflow",
        abstract: "Trace values across function calls and memory effects as JSON.",
        discussion: """
            The symbol graph remains unchanged. This command builds a separate, bounded value graph for one
            function and reports context summaries, argument/return links, callback and inout propagation,
            and field aliases. Unknown external calls, stale or ambiguous declarations, unsupported syntax,
            and exhausted budgets remain explicit in the JSON instead of being treated as constants.

            The subject is a function or method name, qualified name, or USR. If the requested function has
            no known entry context, the response reports an unknown root rather than silently choosing one.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "The function or method to analyze, by name, qualified name or USR.")
    var subject: String

    @Option(name: .customLong("max-contexts"), help: "Maximum call contexts to retain (default: 512).")
    var maxContexts: Int = 512

    @Option(name: .customLong("max-iterations"), help: "Maximum fixed-point iterations (default: 10000).")
    var maxIterations: Int = 10_000

    @Option(name: .customLong("max-values"), help: "Maximum values retained per node (default: 32).")
    var maxValues: Int = 32

    @Option(name: .customLong("max-heap-cells"), help: "Maximum heap cells retained (default: 10000).")
    var maxHeapCells: Int = 10_000

    @Option(name: .customLong("call-depth"), help: "Call-string depth from 1 through 8 (default: 2).")
    var callDepth: Int = 2

    func validate() throws {
        guard maxContexts > 0 else { throw ValidationError("--max-contexts must be positive") }
        guard maxIterations > 0 else { throw ValidationError("--max-iterations must be positive") }
        guard maxValues > 0 else { throw ValidationError("--max-values must be positive") }
        guard maxHeapCells > 0 else { throw ValidationError("--max-heap-cells must be positive") }
        guard (1...8).contains(callDepth) else {
            throw ValidationError("--call-depth must be between 1 and 8")
        }
        guard options.level == nil else {
            throw ValidationError(
                "--level cannot be combined with dataflow; value analysis has its own context graph"
            )
        }
        guard options.since == nil else {
            throw ValidationError(
                "--since cannot be combined with dataflow; value analysis answers one function context"
            )
        }
        guard options.reportFormat == nil else {
            throw ValidationError("--report-format cannot be combined with dataflow; output is always JSON")
        }
    }

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        try CommandSupport.emit(
            try context.service.dataflow(
                symbol: subject,
                limits: ValueFlowLimits(
                    contexts: maxContexts,
                    iterations: maxIterations,
                    valuesPerNode: maxValues,
                    heapCells: maxHeapCells,
                    callStringDepth: callDepth
                )
            ),
            options: options,
            context: context
        )
    }
}
