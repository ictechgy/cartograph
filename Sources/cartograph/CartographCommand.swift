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
            QueryCommand.self,
            BridgesCommand.self,
            MetricsCommand.self,
            RulesCommand.self,
            BaselineCommand.self,
            InitCommand.self,
            SkillCommand.self,
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
            and conformances. Callers in Dart or JavaScript are supplied by isthmus through \
            --external-retentions; see `cartograph bridges --help`.

            Use --explain to find out why a specific declaration survived.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .customLong("explain"), help: "Explain why a declaration is retained, by name or USR.")
    var explain: String?

    @Flag(
        name: .customLong("report-test-only"),
        help: "Also report declarations reached only from tests or previews."
    )
    var reportTestOnly: Bool = false

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        let outcome = try explain.map { try context.service.explainRetention(of: $0) }
            ?? context.service.detectUnusedCode(reportingTestOnlyCode: reportTestOnly)
        try CommandSupport.emit(outcome, options: options, context: context)
    }
}

/// 심볼 하나에 대해 되묻는다.
struct QueryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Answer three questions about one declaration, as JSON.",
        discussion: """
            Who uses it, what does it use, and is it reachable from a retained root. The answer is \
            always JSON on stdout, with the reachability reason as a value rather than as prose.

            This command never says a declaration is safe to delete. It reports what the index can \
            see and, in the same response, the channels this analysis cannot see — Objective-C \
            sources, Interface Builder documents, uncompiled #if branches — so the caller can \
            decide how far to trust the answer.

            Names that match more than one declaration return the candidates and their USRs \
            instead of a guess. Ask again with a USR.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "The declaration to ask about, by name, qualified name or USR.")
    var symbol: String

    @Option(name: .customLong("depth"), help: "How many edges to follow in each direction.")
    var depth: Int = 1

    @Option(name: .customLong("limit"), help: "Maximum neighbours to report in each direction.")
    var limit: Int = 50

    func validate() throws {
        guard depth >= 1 else { throw ValidationError("--depth must be at least 1") }
        guard limit >= 1 else { throw ValidationError("--limit must be at least 1") }
    }

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        try CommandSupport.emit(
            try context.service.query(symbol: symbol, depth: depth, limit: limit),
            options: options,
            context: context
        )
    }
}

/// 언어 경계의 사실을 내보낸다.
struct BridgesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bridges",
        abstract: "Export what Swift declares at a language boundary, for isthmus to join.",
        discussion: """
            Reads Flutter channel names, method-call handlers and their `case "…"` branches, and \
            React Native module exports (`@objc(Name)`, `RCT_EXPORT_MODULE`, `RCT_EXPORT_METHOD`) \
            out of the sources, and attaches the index's USR to each. The output is the \
            bridge-facts exchange format that isthmus reads to join with the Dart or JavaScript side.

            This command states facts, not verdicts. It does not know whether anything calls a \
            handler; a name that is not a literal is kept and marked `dynamic` rather than dropped.

            Feed the retentions isthmus produces back with `dead --external-retentions <path>`.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .customLong("format"), help: "json (the exchange format) or text (one line per fact).")
    var format: BridgesFormat = .json

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        try CommandSupport.emit(
            try context.service.exportBridgeFacts(asText: format == .text),
            options: options,
            context: context
        )
    }
}

/// `bridges --format` 의 값.
enum BridgesFormat: String, ExpressibleByArgument, CaseIterable {
    case json
    case text
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
/// 코딩 에이전트에게 이 도구 쓰는 법을 설치한다.
struct SkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Install the agent skill that teaches a coding agent to use this tool.",
        discussion: """
            Writes \(AgentSkillTemplate.directory)/\(AgentSkillTemplate.fileName) into the \
            project. A coding agent that reads it will run `cartograph query` before deleting a \
            declaration, and — more importantly — will know what the answer does not prove.

            An agent turns a verdict into an edit without pausing, so the skill spends most of its \
            length on what must not be inferred from an `unreachable` result.
            """
    )

    @Option(name: [.customShort("p"), .customLong("project")], help: "Project root.")
    var projectPath: String?

    @Flag(help: "Overwrite an existing skill file.")
    var force: Bool = false

    func run() throws {
        let fileSystem = LocalFileSystem()
        let root = projectPath ?? fileSystem.currentDirectoryPath
        let directory = (root as NSString).appendingPathComponent(AgentSkillTemplate.directory)
        let path = (directory as NSString).appendingPathComponent(AgentSkillTemplate.fileName)

        guard force || !fileSystem.fileExists(at: path) else {
            throw ValidationError("\(path) already exists. Pass --force to overwrite it.")
        }
        do {
            try fileSystem.write(text: AgentSkillTemplate.markdown + "\n", to: path)
        } catch {
            throw CartographError.outputUnwritable(path: path, underlying: "\(error)")
        }
        print("Wrote \(path)")
    }
}

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
