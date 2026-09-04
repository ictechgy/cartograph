import ArgumentParser
import CartographConfig
import CartographCore
import Foundation

/// 모든 분석 명령이 공유하는 옵션.
///
/// 우선순위는 CLI > 설정 파일 > 기본값 이다.
struct GlobalOptions: ParsableArguments {
    @Option(name: [.customShort("p"), .customLong("project")], help: "Project root to analyze.")
    var projectPath: String?

    @Option(name: .customLong("index-store"), help: "Index store directory. Auto-detected when omitted.")
    var indexStorePath: String?

    @Option(name: [.customShort("c"), .customLong("config")], help: "Configuration file path.")
    var configPath: String?

    @Option(name: .customLong("derived-data"), help: "DerivedData directory to search for an index store.")
    var derivedDataPath: String?

    @Option(help: "Graph resolution: module, file, type or symbol.")
    var level: GraphLevel?

    @Option(name: .customLong("report-format"), help: "text, json, xcode, checkstyle, github-actions or sarif.")
    var reportFormat: ReportFormat?

    @Option(name: .customLong("baseline"), help: "Baseline file used to suppress known findings.")
    var baselinePath: String?

    @Option(
        name: .customLong("external-retentions"),
        help: "Retentions file from `isthmus retentions --for cartograph`; keeps declarations called across a bridge."
    )
    var externalRetentionsPath: String?

    @Option(name: .customLong("include"), parsing: .upToNextOption, help: "Glob patterns to include.")
    var include: [String] = []

    @Option(name: .customLong("exclude"), parsing: .upToNextOption, help: "Glob patterns to exclude.")
    var exclude: [String] = []

    @Option(name: .customLong("edge-kind"), parsing: .upToNextOption, help: "Edge kinds to keep.")
    var edgeKinds: [EdgeKind] = []

    @Option(name: [.customShort("o"), .customLong("output")], help: "Write output to a file instead of stdout.")
    var outputPath: String?

    @Flag(name: .customLong("retain-public"), help: "Treat public and open declarations as used.")
    var retainPublic: Bool = false

    @Option(
        name: .customLong("since"),
        help: "Report only findings in files changed since this git revision."
    )
    var since: String?

    @Flag(help: "Exit with a non-zero status when findings remain.")
    var strict: Bool = false

    @Flag(help: "Suppress warnings on stderr.")
    var quiet: Bool = false

    /// 설정 파일을 읽고 CLI 옵션을 덮어쓴 최종 설정.
    func resolveConfiguration(
        fileSystem: any FileSystem
    ) throws -> (configuration: CartographConfiguration, warnings: [String]) {
        // libIndexStore 는 상대 경로를 받으면 어서션으로 프로세스를 즉시 죽인다
        // ("passed relative path without working-dir"). 종료 코드 계약을 지킬 기회조차
        // 없으므로, 인덱스 계층에 닿기 전에 여기서 절대 경로로 바꾼다.
        let searchDirectory = Self.absolutePath(
            projectPath ?? fileSystem.currentDirectoryPath,
            relativeTo: fileSystem.currentDirectoryPath
        )
        let loaded = try ConfigurationLoader(fileSystem: fileSystem)
            .load(explicitPath: configPath, searchDirectory: searchDirectory)

        let overrides = ConfigurationOverrides(
            indexStorePath: indexStorePath,
            projectPath: Self.absolutePath(
                projectPath ?? loaded.configuration.projectPath ?? searchDirectory,
                relativeTo: fileSystem.currentDirectoryPath
            ),
            derivedDataPath: derivedDataPath,
            level: level,
            include: include.isEmpty ? nil : include.map { GlobPattern($0) },
            exclude: exclude.isEmpty ? nil : exclude.map { GlobPattern($0) },
            edgeKinds: edgeKinds.isEmpty ? nil : Set(edgeKinds),
            baselinePath: baselinePath,
            externalRetentionsPath: externalRetentionsPath,
            reportFormat: reportFormat,
            strict: strict ? true : nil,
            retainPublic: retainPublic ? true : nil
        )
        return (loaded.configuration.applying(overrides), loaded.warnings)
    }

    /// 사용자가 준 경로를 절대 경로로 바꾼다.
    ///
    /// `~` 를 풀고, `.` 과 `..` 를 정리한다. 이미 절대 경로면 정리만 한다.
    static func absolutePath(_ path: String, relativeTo currentDirectory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        // 기준 URL 을 디렉터리로 표시하지 않으면 마지막 구성요소를 파일 이름으로 보고
        // 버린다. "sub" 가 "/work/proj/sub" 가 아니라 "/work/sub" 가 된다.
        let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL.path
    }
}
