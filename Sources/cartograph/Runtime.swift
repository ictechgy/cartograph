import ArgumentParser
import CartographKit

/// 애플리케이션의 실행 근거를 독립적인 계약으로 검증한다.
struct RuntimeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runtime",
        abstract: "Discover, collect and verify runtime dependencies.",
        subcommands: [RuntimeDiscoverCommand.self, RuntimePrepareCoreDataCommand.self, RuntimePlanCommand.self,
            RuntimeCheckCommand.self, RuntimeCollectCommand.self]
    )
}

/// 하위 명령이 등록용 상위 명령을 역참조하지 않도록 공통 옵션 계약을 분리한다.
enum RuntimeOptionsValidation {
    static func validate(_ options: GlobalOptions) throws {
        guard options.level == nil,
              options.since == nil,
              options.reportFormat == nil,
              options.baselinePath == nil
        else {
            throw ValidationError(
                "runtime uses the complete symbol graph and always emits JSON; --level, --since, "
                    + "--report-format and --baseline are not supported"
            )
        }
    }
}

/// 실행 전에 대상 선언과 입력 지문을 고정한다.
struct RuntimePlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Resolve runtime contracts and fingerprint the code and index before running scenarios."
    )
    @OptionGroup var options: GlobalOptions
    @Option(name: .customLong("contracts"), help: "runtime-contracts v1 JSON file.")
    var contracts: String
    @Option(name: .customLong("executable"), help: "Built application executable to fingerprint.")
    var executable: String

    func validate() throws {
        try RuntimeOptionsValidation.validate(options)
        guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--executable cannot be empty")
        }
    }

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        let path = GlobalOptions.absolutePath(contracts, relativeTo: context.fileSystem.currentDirectoryPath)
        let executablePath = GlobalOptions.absolutePath(executable, relativeTo: context.fileSystem.currentDirectoryPath)
        try CommandSupport.emit(
            try context.service.planRuntime(contractsPath: path, executablePath: executablePath),
            options: options,
            context: context
        )
    }
}

/// 실제 시나리오 기록이 현재 코드와 계약을 충족하는지 확인한다.
struct RuntimeCheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Verify scenario observations against the current code and runtime contracts.",
        discussion: """
            Run `runtime plan --executable <path>` after building, then have application tests record
            runtime-observations v1
            with that plan and executable fingerprint. --strict fails for missing scenarios, failed calls,
            wrong result tags or unresolved declarations. Observations from another plan or executable fail with exit 2.
            Unobserved does not mean unused. These are claims supplied by the named observation producer.
            """
    )
    @OptionGroup var options: GlobalOptions
    @Option(name: .customLong("contracts"), help: "runtime-contracts v1 JSON file.")
    var contracts: String
    @Option(name: .customLong("observations"), help: "runtime-observations v1 JSON file from application tests.")
    var observations: String
    @Option(name: .customLong("executable"), help: "Built application executable to fingerprint.")
    var executable: String

    func validate() throws {
        try RuntimeOptionsValidation.validate(options)
        guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--executable cannot be empty")
        }
    }

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        let cwd = context.fileSystem.currentDirectoryPath
        try CommandSupport.emit(
            try context.service.checkRuntime(
                contractsPath: GlobalOptions.absolutePath(contracts, relativeTo: cwd),
                observationsPath: GlobalOptions.absolutePath(observations, relativeTo: cwd),
                executablePath: GlobalOptions.absolutePath(executable, relativeTo: cwd)
            ),
            options: options, context: context
        )
    }
}
