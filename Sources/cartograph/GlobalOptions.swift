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

    @Flag(
        name: .customLong("allow-empty-index"),
        help: "Analyze even when the index store knows none of this project's declarations."
    )
    var allowEmptyIndex: Bool = false

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

        let resolvedProjectPath = Self.absolutePath(
            projectPath ?? loaded.configuration.projectPath ?? searchDirectory,
            relativeTo: fileSystem.currentDirectoryPath
        )
        // CLI 인자로 준 파일 경로는 터미널 작업 디렉터리 기준이고,
        // 설정 파일에 적힌 상대 경로는 프로젝트 루트 기준이다.
        // 베이스라인·외부 근거 파일은 명시적 CLI 옵션만 여기서 작업 디렉터리 기준 절대 경로로 고정하고,
        // 설정 값은 서비스가 같은 루트 기준으로 푼다. 인덱스 경로 두 키는 출처마다 여기서 바로 푼다 —
        // 인덱스 계층은 받은 경로를 그대로 열어 상대 경로를 프로세스 작업 디렉터리 기준으로 읽는다.
        let resolvedBaselinePath = commandLineBaselinePath(currentDirectory: fileSystem.currentDirectoryPath)
        let resolvedExternalRetentionsPath = externalRetentionsPath.map {
            Self.absolutePath($0, relativeTo: fileSystem.currentDirectoryPath)
        }
        let overrides = ConfigurationOverrides(
            indexStorePath: Self.resolvedIndexPath(
                indexStorePath, configured: loaded.configuration.indexStorePath,
                currentDirectory: fileSystem.currentDirectoryPath, projectRoot: resolvedProjectPath
            ),
            projectPath: resolvedProjectPath,
            derivedDataPath: Self.resolvedIndexPath(
                derivedDataPath, configured: loaded.configuration.derivedDataPath,
                currentDirectory: fileSystem.currentDirectoryPath, projectRoot: resolvedProjectPath
            ),
            level: level,
            include: include.isEmpty ? nil : include.map { GlobPattern($0) },
            exclude: exclude.isEmpty ? nil : exclude.map { GlobPattern($0) },
            edgeKinds: edgeKinds.isEmpty ? nil : Set(edgeKinds),
            baselinePath: resolvedBaselinePath,
            externalRetentionsPath: resolvedExternalRetentionsPath,
            reportFormat: reportFormat,
            strict: strict ? true : nil,
            retainPublic: retainPublic ? true : nil
        )
        return (loaded.configuration.applying(overrides), loaded.warnings)
    }

    /// `--baseline` 을 작업 디렉터리 기준 절대 경로로 푼 값. 주지 않았으면 nil 이다.
    ///
    /// 설정을 풀 때와 `serve` 가 시작 전에 파일을 확인할 때 같은 경로를 봐야 하므로 한 곳에서 푼다.
    func commandLineBaselinePath(currentDirectory: String) -> String? {
        baselinePath.map { Self.absolutePath($0, relativeTo: currentDirectory) }
    }

    /// 인덱스 스토어·DerivedData 경로 하나를 출처에 맞는 기준으로 절대 경로화한다. CLI 값이 설정 값보다 우선한다.
    ///
    /// CLI 값은 터미널에서 친 것이라 작업 디렉터리 기준이다. 설정 값은 저장소에 커밋되는 것이라 `baseline_path`·
    /// `external_retentions_path` 처럼 프로젝트 루트 기준이다 — 작업 디렉터리 기준이면 모노레포 루트에서
    /// `--project ios` 로 돌린 CI 가 `derived_data_path: DerivedData` 를 `ios/` 가 아닌 루트에서 찾는다. 설정을
    /// `--config` 로 다른 곳에서 읽어도 기준은 프로젝트 루트다. 한 파일 안의 상대 경로들이 키마다 다른 곳을
    /// 가리키지 않게 다른 경로 키와 같은 기준을 쓴다.
    ///
    /// - Returns: 둘 다 없으면 nil. 그때는 설정 값도 없으므로 덮어쓸 것이 없다.
    static func resolvedIndexPath(
        _ commandLineValue: String?,
        configured configuredValue: String?,
        currentDirectory: String,
        projectRoot: String
    ) -> String? {
        if let commandLineValue { return absolutePath(commandLineValue, relativeTo: currentDirectory) }
        return configuredValue.map { absolutePath($0, relativeTo: projectRoot) }
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
