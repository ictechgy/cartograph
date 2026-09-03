import ArgumentParser
import CartographConfig
import CartographCore
import CartographKit
import Foundation

/// `cartograph` 실행 파일의 진입점.
@main
struct CartographCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: Cartograph.toolName,
        abstract: "Static analysis and dependency graphs for Swift and iOS codebases.",
        discussion: """
            Cartograph reads the index store your compiler already produces and turns it into a \
            queryable dependency graph. Unused code, circular dependencies, architecture metrics \
            and layering rules are all queries over that one graph.

            Build first so the compiler writes an index store, then query it:
              swift build                                              # SwiftPM writes one for you
              xcodebuild build COMPILER_INDEX_STORE_ENABLE=YES -derivedDataPath DerivedData

            Cartograph finds the store on its own. Pass --index-store only to override it.

            Exit codes:
              0   success
              1   findings with --strict, or a configured threshold exceeded
              2   tool failure — no index store, unreadable index, invalid configuration
              64  usage error — unknown option, unknown subcommand, invalid value
            """,
        version: Cartograph.version,
        subcommands: [
            GraphCommand.self,
            CyclesCommand.self,
            DeadCommand.self,
            MetricsCommand.self,
            RulesCommand.self,
            BaselineCommand.self,
            InitCommand.self,
        ]
        // 기본 하위 명령을 두지 않는다. 인자 없이 실행한 사용자가 원하는 것은
        // DOT 덤프가 아니라 "이 도구로 무엇을 할 수 있는지"이다.
    )

    /// 종료 코드를 세 부류로 나눈다.
    ///
    /// - 인자 파싱, `--help`, `--version`, 유효성 오류: ArgumentParser 규약 그대로.
    ///   사용 오류는 관례대로 64(EX_USAGE)로 끝난다.
    /// - 분석 결과 문제 발견(`--strict`, 임계값 초과): 1.
    /// - 그 밖의 실행 실패: 2.
    ///
    /// ArgumentParser 기본 처리는 실행 중 실패를 전부 1 로 내보낸다. 그러면 CI
    /// 스크립트가 "코드에 문제가 있음"과 "도구가 아예 못 돌았음"을 구분할 수 없다.
    static func main() {
        do {
            var command = try parseAsRoot()
            try command.run()
        } catch let error as CartographError {
            // 우리가 아는 실패만 가로챈다. 나머지는 ArgumentParser 가 처리하게 둔다.
            //
            // 처리할 오류를 타입으로 열거하려는 시도를 두 번 했고 두 번 다 깨졌다.
            // --help 는 파싱이 아니라 run() 단계에서 ArgumentParser 내부 오류로
            // 정상 종료하는데, 그 타입은 공개되어 있지 않아 catch 로 집을 수 없다.
            // 그래서 분류는 최상위가 아니라 오류가 나는 자리에서 한다. 도구 실패로
            // 다뤄야 할 것은 그곳에서 CartographError 로 감싼다.
            FileHandle.standardError.write(Data(("error: " + CommandSupport.describe(error) + "\n").utf8))
            Foundation.exit(CommandSupport.failureExitCode)
        } catch {
            exit(withError: error)
        }
    }
}

/// 그래프를 원하는 형식으로 내보낸다.
struct GraphCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "graph",
        abstract: "Render the dependency graph."
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .customLong("format"), help: "dot, mermaid, json or html.")
    var graphFormat: GraphFormat?

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        let outcome = try context.service.renderGraph(level: options.level, format: graphFormat)
        try CommandSupport.emit(outcome, options: options, context: context)
    }
}

/// 순환 의존성을 찾는다.
struct CyclesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cycles",
        abstract: "Find circular dependencies and suggest the weakest link to cut."
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .customLong("explain"), help: "Explain which cycles a node takes part in.")
    var explain: String?

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        let outcome = try explain.map { try context.service.explainCycles(of: $0, level: options.level) }
            ?? context.service.detectCycles(level: options.level)
        try CommandSupport.emit(outcome, options: options, context: context)
    }
}

/// 미사용 선언을 찾는다.
struct DeadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dead",
        abstract: "Find declarations that cannot be reached from any retained root.",
        discussion: """
            Retention rules keep declarations that are used in ways the compiler index cannot see: \
            entry points, tests, Objective-C exposure, Interface Builder connections, raw-value enum \
            cases, CodingKeys, property-wrapper and result-builder requirements, external overrides \
            and conformances.

            Use --explain to find out why a specific declaration survived.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .customLong("explain"), help: "Explain why a declaration is retained, by name or USR.")
    var explain: String?

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        let outcome = try explain.map { try context.service.explainRetention(of: $0) }
            ?? context.service.detectUnusedCode()
        try CommandSupport.emit(outcome, options: options, context: context)
    }
}

/// 아키텍처 지표를 계산한다.
struct MetricsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metrics",
        abstract: "Report Martin metrics: coupling, instability, abstractness and distance."
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        try CommandSupport.emit(
            try context.service.measureMetrics(level: options.level),
            options: options,
            context: context
        )
    }
}

/// 레이어 규칙 위반을 찾는다.
struct RulesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "Enforce the layering rules declared in the configuration file."
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .customLong("explain"), help: "Explain which layer a node is in and why.")
    var explain: String?

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        let outcome = try explain.map { try context.service.explainRules(of: $0, level: options.level) }
            ?? context.service.checkRules(level: options.level)
        try CommandSupport.emit(outcome, options: options, context: context)
    }
}

/// 현재 상태를 베이스라인으로 기록한다.
struct BaselineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "baseline",
        abstract: "Record current findings so only new ones fail the build."
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .customLong("write"), help: "Where to write the baseline file.")
    var writePath: String?

    func run() throws {
        // 범위를 좁혀 기록하면 그 파일은 "오늘의 전체 부채"라는 뜻이 아니게 된다.
        // 나중 전체 실행에서 범위 밖에 있던 기존 부채가 전부 신규로 터진다.
        guard options.since == nil else {
            throw ValidationError(
                "--since cannot be combined with baseline; a baseline must record the whole project"
            )
        }
        let context = try CommandSupport.makeContext(options)
        let path = writePath ?? context.configuration.baselinePath
            ?? (context.service.projectPath as NSString)
                .appendingPathComponent(Cartograph.defaultBaselineFileName)
        let diagnostics = try context.service.collectAllDiagnostics()
        try CommandSupport.emit(
            try context.service.writeBaseline(diagnostics: diagnostics, to: path),
            options: options,
            context: context
        )
    }
}

/// 설정 파일 템플릿을 만든다.
struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Write a commented .cartograph.yml to the project root."
    )

    @Option(name: [.customShort("p"), .customLong("project")], help: "Project root.")
    var projectPath: String?

    @Flag(help: "Overwrite an existing configuration file.")
    var force: Bool = false

    func run() throws {
        let fileSystem = LocalFileSystem()
        let root = projectPath ?? fileSystem.currentDirectoryPath
        let path = (root as NSString).appendingPathComponent(Cartograph.defaultConfigurationFileName)

        guard force || !fileSystem.fileExists(at: path) else {
            throw ValidationError("\(path) already exists. Pass --force to overwrite it.")
        }
        do {
            try fileSystem.write(text: ConfigurationTemplate.yaml + "\n", to: path)
        } catch {
            throw CartographError.outputUnwritable(path: path, underlying: "\(error)")
        }
        print("Wrote \(path)")
    }
}
