import ArgumentParser
import CartographKit

/// CI에서 전체 구조 점검을 하나의 인덱스 문맥으로 실행한다.
struct CheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Run the dead-code, cycle and layering checks together."
    )

    @OptionGroup var options: GlobalOptions

    func validate() throws {
        guard options.level == nil else {
            throw ValidationError(
                "--level cannot be combined with check; check uses symbol, module, type and configured levels"
            )
        }
    }

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        try CommandSupport.emit(try context.service.check(), options: options, context: context)
    }
}
