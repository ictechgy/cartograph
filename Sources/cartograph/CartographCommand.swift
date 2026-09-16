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
              2   tool failure — no index store, an index that knows nothing about this \
            project, unreadable index, invalid configuration
              64  usage error — unknown option, unknown subcommand, invalid value
            """,
        version: Cartograph.version,
        subcommands: [
            GraphCommand.self,
            CyclesCommand.self,
            DeadCommand.self,
            QueryCommand.self,
            RuntimeCommand.self,
            ImpactCommand.self,
            CheckCommand.self,
            ServeCommand.self,
            SnapshotCommand.self,
            DataflowCommand.self,
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
        } catch let error as AnalysisSessionError {
            FileHandle.standardError.write(Data(("error: " + (error.errorDescription ?? "Analysis inputs changed.") + "\n").utf8))
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

    func validate() throws {
        // 그래프는 전체를 덤프한다. 바뀐 파일만 잘라내면 도달성부터 틀린
        // 그림이 되고, 그렇다고 조용히 전체를 그리면 `--since` 를 걸고 비교한
        // 결과가 "같음" 으로 나온다. 앞에서 거부한다.
        guard options.since == nil else {
            throw ValidationError(
                "--since cannot be combined with graph; graph renders the whole project, "
                    + "not the findings in changed files"
            )
        }
        // 문서 형식은 --format 이 정한다. --report-format 은 진단 목록 명령의
        // 형식이라 여기서 받으면 DOT 을 내놓고 JSON 을 기대하게 된다.
        guard options.reportFormat == nil else {
            throw ValidationError(
                "--report-format cannot be combined with graph; use --format for the document format"
            )
        }
        // 그래프 덤프는 발견을 내지 않는다. --strict 는 발견을 세는 명령의 규약이다.
        guard !options.strict else {
            throw ValidationError(
                "--strict cannot be combined with graph; graph renders the whole graph, "
                    + "it has no findings to enforce"
            )
        }
    }

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

    func validate() throws {
        // 설명은 `--explain` 이 있을 때만 단일 정점에 답하고, 그때는 범위
        // 렌즈가 닿을 자리가 없다. `cycles --since` (목록)는 그대로 둔다.
        guard explain == nil || options.since == nil else {
            throw ValidationError(
                "--since cannot be combined with cycles --explain; the explanation answers "
                    + "one node, not the findings in changed files"
            )
        }
    }

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

    func validate() throws {
        // `dead --since` (목록)는 유효하고 `dead --explain` (단일 선언)만
        // 범위 렌즈와 겹친다. 겹치는 조합만 앞에서 거부한다.
        guard explain == nil || options.since == nil else {
            throw ValidationError(
                "--since cannot be combined with dead --explain; the explanation answers "
                    + "one declaration, not the findings in changed files"
            )
        }
        // 설명은 한 선언이 왜 살아 있는지의 근거다. 테스트 전용 목록은 발견
        // 목록의 렌즈라 설명에 닿을 자리가 없다. 받아 두면 조용히 무시된다.
        guard explain == nil || !reportTestOnly else {
            throw ValidationError(
                "--report-test-only cannot be combined with dead --explain; the explanation "
                    + "answers one declaration, not the findings list the flag widens"
            )
        }
        // 미사용 분석은 항상 심볼 레벨이다. `--level` 을 받으면 출력이
        // 바이트까지 같아 통과할 수밖에 없는 비교가 증거가 된다.
        guard options.level == nil else {
            throw ValidationError(
                "--level cannot be combined with dead; unused-code analysis is always at symbol level"
            )
        }
    }

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
        abstract: "Answer three questions about one or many declarations, as JSON.",
        discussion: """
            Who uses it, what does it use, and is it reachable from a retained root. The answer is \
            always JSON on stdout, with the reachability reason as a value rather than as prose.

            This command never says a declaration is safe to delete. It reports what the index can \
            see and, in the same response, the channels this analysis cannot see — Objective-C \
            sources, Interface Builder documents, an index older than the sources — so the caller \
            can decide how far to trust the answer. The list is counted from your project and stays \
            empty when there is nothing to report.

            Names that match more than one declaration return the candidates and their USRs \
            instead of a guess. Ask again with a USR.

            --batch answers many declarations from one index read. Sweeping a `dead` report one \
            name at a time costs one process and one index read per name; the answers are cheap and \
            the preparation is not. The file is a JSON array of names, and the results come back in \
            request order, duplicates kept, in the `symbol-query-batch` format that dartograph \
            already writes.

            A batch answers every request from one snapshot of the index. A sweep run one name at \
            a time can straddle a rebuild and answer half its questions from a different index.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "The declaration to ask about, by name, qualified name or USR.")
    var symbol: String?

    @Option(
        name: .customLong("batch"),
        help: """
            A JSON array of 1-1000 non-empty names to ask about, at most 1 MiB, answered from one \
            index read. Every answer is printed even when a name is not found; read stdout before \
            reacting to the exit code.
            """
    )
    var batch: String?

    @Option(name: .customLong("depth"), help: "How many edges to follow in each direction.")
    var depth: Int = 1

    @Option(name: .customLong("limit"), help: "Maximum neighbours to report in each direction.")
    var limit: Int = 50

    func validate() throws {
        guard depth >= 1 else { throw ValidationError("--depth must be at least 1") }
        guard limit >= 1 else { throw ValidationError("--limit must be at least 1") }
        // `query` 는 진단 목록이 아니라 선언 하나에 답하므로 범위 렌즈가 닿을
        // 자리가 없다. 조용히 무시하면 `--since` 를 걸고 비교한 결과가 "같음" 으로
        // 나와 통과할 수밖에 없는 비교가 증거가 된다. 베이스라인과 같은 방식으로
        // 앞에서 거부한다.
        guard options.since == nil else {
            throw ValidationError(
                "--since cannot be combined with query; query answers one declaration, "
                    + "not the findings in changed files"
            )
        }
        // `query` 는 설정과 무관하게 항상 심볼 레벨로 답한다. 레벨을 받으면
        // 같은 답이 다른 레벨 답으로 둔갑할 자리가 생긴다.
        guard options.level == nil else {
            throw ValidationError(
                "--level cannot be combined with query; query always answers at symbol level"
            )
        }
        // 답은 언제나 JSON 이다. --report-format 을 받아 두면 조용히 무시된 채
        // JSON 이 나가고, 텍스트를 기대한 스크립트가 잘못된 출력을 파싱한다.
        guard options.reportFormat == nil else {
            throw ValidationError(
                "--report-format cannot be combined with query; query always answers as JSON on stdout"
            )
        }
        // 질의는 발견 목록이 아니라 사실 한 건이다. --strict 는 발견을 세는
        // 명령의 종료 코드 규약이라 여기서는 아무것도 잴 수 없다.
        guard !options.strict else {
            throw ValidationError(
                "--strict cannot be combined with query; query answers facts, not findings"
            )
        }
        // 둘 다 받으면 어느 쪽을 답했는지 출력 형식으로만 알 수 있다. 스크립트가
        // 인자를 잘못 조립해도 조용히 한쪽이 무시되는 것이 가장 나쁘다.
        switch (symbol, batch) {
        case (nil, nil):
            throw ValidationError("give a declaration to ask about, or --batch <requests.json>")
        case let (.some(name), nil) where name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            // 배치는 빈 이름을 앞에서 거부한다. 단건만 통과시키면 인덱스를 다 읽고
            // notFound 를 답하게 되고, 그 답은 오타를 오타라고 말하지 않는다.
            throw ValidationError("the declaration to ask about is empty")
        case (.some, .some):
            throw ValidationError("give either a declaration or --batch, not both")
        default:
            break
        }
    }

    func run() throws {
        // 요청 파일은 인덱스를 열기 전에 읽는다. 색인을 다 만든 뒤에 "배열이 비었다" 를
        // 말하면 사용자는 몇 초를 기다린 대가로 오타 하나를 받는다.
        let requests = try batch.map { try Self.readRequests(at: $0) }
        let context = try CommandSupport.makeContext(options)
        let outcome = try requests.map {
            try context.service.queryBatch(symbols: $0, depth: depth, limit: limit)
        } ?? context.service.query(symbol: symbol ?? "", depth: depth, limit: limit)
        try CommandSupport.emit(outcome, options: options, context: context)
    }

    /// 요청 파일을 읽어 이름 목록으로 만든다.
    ///
    /// 실패를 `ValidationError` 로 바꾼다. 요청 파일이 잘못된 것은 **인자의 문제**이지
    /// 도구가 죽은 것이 아니다. `CartographError` 를 그대로 던지면 최상위가 종료 코드 2
    /// 를 내고, CI 스크립트는 그것을 "분석을 신뢰할 수 없음" 으로 읽는다. 오타 하나에
    /// 파이프라인이 인덱스를 의심하게 만들지 않는다.
    private static func readRequests(at path: String) throws -> [String] {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try SymbolQueryBatchRequests.parse(data, path: path)
        } catch let error as CartographError {
            throw ValidationError(error.errorDescription ?? "\(error)")
        } catch {
            throw ValidationError(
                CartographError.invalidBatchRequests(
                    path: path, reason: Self.trimmed(error.localizedDescription)
                ).errorDescription ?? "\(error)"
            )
        }
    }

    /// 끝의 마침표를 뗀다. 이 자리의 이유 문구는 문장 가운데에 끼워 넣는다.
    private static func trimmed(_ reason: String) -> String {
        var reason = reason
        while reason.hasSuffix(".") { reason.removeLast() }
        return reason
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
            out of the sources, and attaches the index's USR to each Swift declaration it can \
            match; facts from `.m` files carry their syntactic qualified name, plus a Clang USR \
            only where the index uniquely identifies the declaration. Event and message channels \
            are counted under `limitations` rather than read by default; `--messages` opts into \
            BasicMessageChannel handler facts and `--events` into EventChannel stream-handler \
            facts, each as a transport-specific bridge-facts v2 document. The output is the \
            bridge-facts exchange format that isthmus reads to join with the Dart or JavaScript side.

            This command states facts, not verdicts. It does not know whether anything calls a \
            handler; a name that is not a literal is kept and marked `dynamic` rather than dropped.

            Feed the retentions isthmus produces back with `dead --external-retentions <path>`.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .customLong("format"), help: "json (the exchange format) or text (one line per fact).")
    var format: BridgesFormat = .json

    @Option(name: .customLong("target"), help: "Limit facts to flutter or react-native.")
    var target: BridgesTarget?

    @Flag(name: .customLong("messages"), help: "Export Flutter BasicMessageChannel handler facts as bridge-facts v2.")
    var messages: Bool = false

    @Flag(name: .customLong("events"), help: "Export Flutter EventChannel stream-handler facts as bridge-facts v2.")
    var events: Bool = false

    func validate() throws {
        // 사실 문서는 조인용 전체 내보내기다. 바뀐 파일만 담으면 하류 조인이
        // 빠진 핸들러로 읽는다. 조용히 전체를 내보내는 쪽도 `--since` 비교를
        // 증거로 만들기 때문에 앞에서 거부한다.
        guard options.since == nil else {
            throw ValidationError(
                "--since cannot be combined with bridges; the document must carry the whole "
                    + "boundary or the join reads a missing handler"
            )
        }
        // 사실 문서는 그래프가 아니라 경계 목록이라 해상도가 없다.
        guard options.level == nil else {
            throw ValidationError(
                "--level cannot be combined with bridges; bridge facts have no graph level"
            )
        }
        // 문서 형식은 --format 이 정한다. --report-format 은 진단 목록 명령의
        // 형식이라 여기서 받으면 조용히 무시된 채 JSON 이 나간다.
        guard options.reportFormat == nil else {
            throw ValidationError(
                "--report-format cannot be combined with bridges; use --format for the document format"
            )
        }
        // 사실 문서는 판정이 아니라 내보내기다. 발견이 없으니 --strict 가 잴 것도 없다.
        guard !options.strict else {
            throw ValidationError(
                "--strict cannot be combined with bridges; bridge facts state the boundary, "
                    + "they are not findings"
            )
        }
        guard !messages || target != .reactNative else {
            throw ValidationError("--messages can only be combined with --target flutter")
        }
        guard !events || target != .reactNative else {
            throw ValidationError("--events can only be combined with --target flutter")
        }
        // 문서 하나는 전송 하나다. 두 플래그를 같이 받으면 한 문서에 두 transport 가
        // 섞이므로, isthmus 가 요청할 때처럼 각각 실행하게 앞에서 거부한다.
        guard !(messages && events) else {
            throw ValidationError("--messages and --events are separate documents; run one flag at a time")
        }
    }

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        try CommandSupport.emit(
            try context.service.exportBridgeFacts(
                asText: format == .text,
                target: target?.bridgeTarget,
                messages: messages,
                events: events
            ),
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

/// `bridges --target`에서 선택할 언어 경계다.
enum BridgesTarget: String, ExpressibleByArgument, CaseIterable {
    case flutter
    case reactNative = "react-native"

    var bridgeTarget: BridgeFact.Target {
        switch self {
        case .flutter: .flutter
        case .reactNative: .reactNative
        }
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

    func validate() throws {
        // 설명은 `--explain` 이 있을 때만 단일 정점에 답한다. `rules --since`
        // (목록)는 그대로 둔다.
        guard explain == nil || options.since == nil else {
            throw ValidationError(
                "--since cannot be combined with rules --explain; the explanation answers "
                    + "one node, not the findings in changed files"
            )
        }
    }

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

    func validate() throws {
        // 베이스라인은 명령마다 정해진 해상도로 거둔다. `--level` 을 받으면
        // 같은 기록이 다른 해상도 기록으로 둔갑할 자리가 생긴다.
        guard options.level == nil else {
            throw ValidationError(
                "--level cannot be combined with baseline; it records every command at its own level"
            )
        }
        // 결과는 고정된 한 줄이다. 진단 리포트가 아니므로 --report-format 이
        // 바꿀 출력도, --strict 가 잴 발견도 없다.
        guard options.reportFormat == nil else {
            throw ValidationError(
                "--report-format cannot be combined with baseline; it writes a baseline file, not a report"
            )
        }
        guard !options.strict else {
            throw ValidationError(
                "--strict cannot be combined with baseline; it records findings, it does not enforce them"
            )
        }
    }

    func run() throws {
        // 범위를 좁혀 기록하면 그 파일은 "오늘의 전체 부채"라는 뜻이 아니게 된다.
        // 나중 전체 실행에서 범위 밖에 있던 기존 부채가 전부 신규로 터진다.
        guard options.since == nil else {
            throw ValidationError(
                "--since cannot be combined with baseline; a baseline must record the whole project"
            )
        }
        let context = try CommandSupport.makeContext(options)
        // 쓰기 목적지는 설정 파일이 정하지 못한다. 분석 대상 저장소의
        // .cartograph.yml 에 절대 경로를 심어 두고 baseline 을 돌리면 그 경로의
        // 파일이 JSON 으로 덮어써진다 — 중간 디렉터리까지 만들어 주니 더욱 그렇다.
        // baseline_path 는 읽기 위치를 나타내는 키로 남기고, 쓰는 곳은 항상
        // 명시적으로 고르게 한다.
        let path: String
        if let writePath {
            path = GlobalOptions.absolutePath(writePath, relativeTo: context.fileSystem.currentDirectoryPath)
        } else {
            if context.configuration.baselinePath != nil {
                throw ValidationError(
                    "baseline_path is set in the configuration, so the write destination must be explicit; "
                        + "pass --write <path> (baseline_path names where suppression findings are read from, "
                        + "never where a baseline is written)"
                )
            }
            path = (context.service.projectPath as NSString)
                .appendingPathComponent(Cartograph.defaultBaselineFileName)
        }
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
        let path = ((root as NSString).appendingPathComponent(AgentSkillTemplate.directory)
            as NSString).appendingPathComponent(AgentSkillTemplate.fileName)
        try TemplateInstaller.install(AgentSkillTemplate.markdown + "\n", to: path, force: force, fileSystem: fileSystem)
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
        try TemplateInstaller.install(ConfigurationTemplate.yaml + "\n", to: path, force: force, fileSystem: fileSystem)
    }
}
