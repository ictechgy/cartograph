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

    // 기본값은 ValueFlowLimits.standard 하나가 근원이다. 여기에 숫자를 또 적으면
    // 구현이 바뀔 때 도움말과 한도가 갈라진다.
    @Option(name: .customLong("max-contexts"), help: "Maximum call contexts to retain (default: \(ValueFlowLimits.standard.contexts)).")
    var maxContexts: Int?

    @Option(name: .customLong("max-iterations"), help: "Maximum fixed-point iterations (default: \(ValueFlowLimits.standard.iterations)).")
    var maxIterations: Int?

    @Option(name: .customLong("max-values"), help: "Maximum values retained per node (default: \(ValueFlowLimits.standard.valuesPerNode)).")
    var maxValues: Int?

    @Option(name: .customLong("max-heap-cells"), help: "Maximum heap cells retained (default: \(ValueFlowLimits.standard.heapCells)).")
    var maxHeapCells: Int?

    @Option(name: .customLong("call-depth"), help: "Call-string depth from 1 through 8 (default: \(ValueFlowLimits.standard.callStringDepth)).")
    var callDepth: Int?

    func validate() throws {
        guard maxContexts.map({ $0 > 0 }) ?? true else { throw ValidationError("--max-contexts must be positive") }
        guard maxIterations.map({ $0 > 0 }) ?? true else { throw ValidationError("--max-iterations must be positive") }
        guard maxValues.map({ $0 > 0 }) ?? true else { throw ValidationError("--max-values must be positive") }
        guard maxHeapCells.map({ $0 > 0 }) ?? true else { throw ValidationError("--max-heap-cells must be positive") }
        guard callDepth.map({ (1...8).contains($0) }) ?? true else {
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
        // 값 흐름은 발견 목록이 아니라 함수 하나의 사실이다. --strict 가 잴 발견이 없다.
        guard !options.strict else {
            throw ValidationError(
                "--strict cannot be combined with dataflow; value analysis answers facts, not findings"
            )
        }
    }

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        try CommandSupport.emit(
            try context.service.dataflow(
                symbol: subject,
                limits: ValueFlowLimits.resolved(
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
