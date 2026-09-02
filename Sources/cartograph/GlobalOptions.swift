import ArgumentParser
import CartographConfig
import CartographCore

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

    @Flag(help: "Exit with a non-zero status when findings remain.")
    var strict: Bool = false

    @Flag(help: "Suppress warnings on stderr.")
    var quiet: Bool = false

    /// 설정 파일을 읽고 CLI 옵션을 덮어쓴 최종 설정.
    func resolveConfiguration(
        fileSystem: any FileSystem
    ) throws -> (configuration: CartographConfiguration, warnings: [String]) {
        let searchDirectory = projectPath ?? fileSystem.currentDirectoryPath
        let loaded = try ConfigurationLoader(fileSystem: fileSystem)
            .load(explicitPath: configPath, searchDirectory: searchDirectory)

        let overrides = ConfigurationOverrides(
            indexStorePath: indexStorePath,
            projectPath: projectPath ?? loaded.configuration.projectPath ?? searchDirectory,
            derivedDataPath: derivedDataPath,
            level: level,
            include: include.isEmpty ? nil : include.map { GlobPattern($0) },
            exclude: exclude.isEmpty ? nil : exclude.map { GlobPattern($0) },
            edgeKinds: edgeKinds.isEmpty ? nil : Set(edgeKinds),
            baselinePath: baselinePath,
            reportFormat: reportFormat,
            strict: strict ? true : nil,
            retainPublic: retainPublic ? true : nil
        )
        return (loaded.configuration.applying(overrides), loaded.warnings)
    }
}
