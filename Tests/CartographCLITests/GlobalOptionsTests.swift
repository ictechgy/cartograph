import ArgumentParser
@testable import cartograph
import CartographCore
import CartographTestSupport
import Testing

@Suite("CLI 옵션 해석")
struct GlobalOptionsTests {
    @Test("설정 파일이 없어도 기본값으로 동작한다")
    func worksWithoutConfigurationFile() throws {
        let options = try GlobalOptions.parse(["--project", "/p"])
        let resolved = try options.resolveConfiguration(fileSystem: InMemoryFileSystem())
        #expect(resolved.configuration.projectPath == "/p")
        #expect(resolved.configuration.level == .module)
        #expect(resolved.warnings.isEmpty)
    }

    @Test("CLI 옵션이 설정 파일보다 우선한다")
    func commandLineOverridesConfigurationFile() throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/.cartograph.yml": """
                level: module
                strict: false
                report_format: text
                """
        ])
        let options = try GlobalOptions.parse([
            "--project", "/p", "--level", "symbol", "--report-format", "sarif", "--strict",
        ])
        let resolved = try options.resolveConfiguration(fileSystem: fileSystem)
        #expect(resolved.configuration.level == .symbol)
        #expect(resolved.configuration.reportFormat == .sarif)
        #expect(resolved.configuration.strict)
    }

    @Test("지정하지 않은 옵션은 설정 파일 값을 유지한다")
    func unspecifiedOptionsKeepConfigurationValues() throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/.cartograph.yml": "level: type\nstrict: true\n"
        ])
        let options = try GlobalOptions.parse(["--project", "/p"])
        let resolved = try options.resolveConfiguration(fileSystem: fileSystem)
        #expect(resolved.configuration.level == .type)
        #expect(resolved.configuration.strict)
    }

    @Test("--external-retentions 와 --baseline 은 작업 디렉터리 기준으로 해결되며 설정 파일 값을 덮어쓴다")
    func cliFileOptionsOverrideAndNormalizeAgainstCurrentDirectory() throws {
        let fileSystem = InMemoryFileSystem(
            currentDirectoryPath: "/work",
            files: [
                "/p/.cartograph.yml": """
                    external_retentions_path: from-file.json
                    baseline_path: baseline-from-file.json
                    """
            ]
        )
        let fromFile = try GlobalOptions.parse(["--project", "/p"]).resolveConfiguration(fileSystem: fileSystem)
        // 설정 파일의 상대 경로는 프로젝트 루트 기준 처리를 위해 그대로 유지된다.
        #expect(fromFile.configuration.externalRetentionsPath == "from-file.json")
        #expect(fromFile.configuration.baselinePath == "baseline-from-file.json")

        let fromFlag = try GlobalOptions.parse([
            "--project", "/p",
            "--external-retentions", "cli.json",
            "--baseline", "cli-baseline.json"
        ]).resolveConfiguration(fileSystem: fileSystem)
        // CLI 인자로 준 상대 경로는 현재 작업 디렉터리(/work) 기준으로 절대 경로화된다.
        #expect(fromFlag.configuration.externalRetentionsPath == "/work/cli.json")
        #expect(fromFlag.configuration.baselinePath == "/work/cli-baseline.json")
    }

    @Test("설정 파일의 index_store_path·derived_data_path 상대 경로는 작업 디렉터리가 아니라 프로젝트 루트 기준이다")
    func configuredIndexPathsResolveAgainstProjectRoot() throws {
        // 모노레포 루트(/root)에서 하위 앱을 `--project ios` 로 분석하는 CI(공식 액션)가 템플릿 예시를 그대로 쓴 모양.
        // 작업 디렉터리 기준으로 풀면 /root/DerivedData 를 찾아 "index store not found" 로 끝나거나, 그 자리에 있는
        // 다른 앱의 평면 DerivedData 스토어를 연다.
        let fileSystem = InMemoryFileSystem(
            currentDirectoryPath: "/root",
            files: ["/root/ios/.cartograph.yml": "index_store_path: Index/DataStore\nderived_data_path: DerivedData\n"]
        )
        let relative = try GlobalOptions.parse(["--project", "ios"]).resolveConfiguration(fileSystem: fileSystem)
        #expect(relative.configuration.projectPath == "/root/ios")
        #expect(relative.configuration.indexStorePath == "/root/ios/Index/DataStore")
        #expect(relative.configuration.derivedDataPath == "/root/ios/DerivedData")

        let absolute = try GlobalOptions.parse(["--project", "/p"]).resolveConfiguration(
            fileSystem: InMemoryFileSystem(
                currentDirectoryPath: "/work",
                files: ["/p/.cartograph.yml": "index_store_path: /ci/store\nderived_data_path: /ci/DerivedData\n"]
            )
        )
        #expect(absolute.configuration.indexStorePath == "/ci/store")
        #expect(absolute.configuration.derivedDataPath == "/ci/DerivedData")
    }

    @Test("--config 로 다른 곳의 설정을 읽어도 인덱스 경로 키는 baseline_path 처럼 프로젝트 루트 기준이다")
    func explicitConfigurationElsewhereStillResolvesAgainstProjectRoot() throws {
        // 설정 파일 디렉터리와 프로젝트 루트가 갈리는 유일한 경우다. 다른 경로 키와 같은 기준을 써야 한 파일 안의
        // 상대 경로들이 서로 다른 곳을 가리키지 않는다.
        let fileSystem = InMemoryFileSystem(
            currentDirectoryPath: "/work",
            files: ["/shared/ci.yml": "derived_data_path: DerivedData\nbaseline_path: baseline.json\n"]
        )
        let resolved = try GlobalOptions.parse(["--project", "/p", "--config", "/shared/ci.yml"])
            .resolveConfiguration(fileSystem: fileSystem)
        #expect(resolved.configuration.derivedDataPath == "/p/DerivedData")
        // baseline_path 는 서비스가 같은 루트 기준으로 푼다(`CartographService.loadBaseline`).
        #expect(resolved.configuration.baselinePath == "baseline.json")
    }

    @Test("--index-store·--derived-data 상대 경로는 작업 디렉터리 기준 절대 경로가 되고 설정 파일 값을 덮어쓴다")
    func commandLineIndexPathsResolveAgainstCurrentDirectory() throws {
        let fileSystem = InMemoryFileSystem(
            currentDirectoryPath: "/root",
            files: ["/root/ios/.cartograph.yml": "index_store_path: Index/DataStore\nderived_data_path: DerivedData\n"]
        )
        let resolved = try GlobalOptions.parse([
            "--project", "ios", "--index-store", ".build/out", "--derived-data", "build/../DD",
        ]).resolveConfiguration(fileSystem: fileSystem)
        #expect(resolved.configuration.indexStorePath == "/root/.build/out")
        #expect(resolved.configuration.derivedDataPath == "/root/DD")
    }

    @Test("여러 값을 받는 옵션을 파싱한다")
    func parsesRepeatedOptions() throws {
        let options = try GlobalOptions.parse([
            "--project", "/p",
            "--include", "Sources/**", "App/**",
            "--exclude", "**/Generated/**",
            "--edge-kind", "call", "conformance",
        ])
        let resolved = try options.resolveConfiguration(fileSystem: InMemoryFileSystem())
        #expect(resolved.configuration.include.map(\.pattern) == ["Sources/**", "App/**"])
        #expect(resolved.configuration.exclude.map(\.pattern) == ["**/Generated/**"])
        #expect(resolved.configuration.edgeKinds == [.call, .conformance])
    }

    @Test("설정 파일의 알 수 없는 키는 경고로 전달된다")
    func surfacesConfigurationWarnings() throws {
        let fileSystem = InMemoryFileSystem(files: ["/p/.cartograph.yml": "levl: type\n"])
        let options = try GlobalOptions.parse(["--project", "/p"])
        let resolved = try options.resolveConfiguration(fileSystem: fileSystem)
        #expect(resolved.warnings.count == 1)
        #expect(resolved.warnings[0].contains("'levl'"))
    }

    @Test("잘못된 설정 파일은 오류로 이어진다")
    func invalidConfigurationThrows() throws {
        let fileSystem = InMemoryFileSystem(files: ["/p/.cartograph.yml": "level: 42\n"])
        let options = try GlobalOptions.parse(["--project", "/p"])
        #expect(throws: CartographError.self) {
            try options.resolveConfiguration(fileSystem: fileSystem)
        }
    }

    @Test("프로젝트를 지정하지 않으면 현재 디렉터리를 쓴다")
    func defaultsToCurrentDirectory() throws {
        let options = try GlobalOptions.parse([])
        let resolved = try options.resolveConfiguration(
            fileSystem: InMemoryFileSystem(currentDirectoryPath: "/here")
        )
        #expect(resolved.configuration.projectPath == "/here")
    }

    @Test("알 수 없는 열거형 값은 파싱 단계에서 거부된다")
    func rejectsUnknownEnumValues() {
        #expect(throws: (any Error).self) { try GlobalOptions.parse(["--level", "galaxy"]) }
        #expect(throws: (any Error).self) { try GlobalOptions.parse(["--report-format", "yaml"]) }
    }
}

@Suite("CLI 명령 구성")
struct CommandConfigurationTests {
    @Test("모든 하위 명령이 등록되어 있다")
    func subcommandsAreRegistered() {
        let names = CartographCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names == [
            "graph", "cycles", "dead", "fix", "query", "runtime", "impact", "affected", "check", "serve", "snapshot", "dataflow", "bridges",
            "schema", "routes", "metrics", "rules", "baseline", "init", "skill",
        ])
        // 인자 없이 실행하면 도움말이 나와야 한다. 기본 하위 명령이 있으면
        // 처음 써 보는 사용자가 DOT 덤프를 마주하게 된다.
        #expect(CartographCommand.configuration.defaultSubcommand == nil)
    }

    @Test("도움말에 인덱스 생성 방법과 종료 코드가 적혀 있다")
    func helpExplainsPrerequisitesAndExitCodes() {
        let discussion = CartographCommand.configuration.discussion
        #expect(discussion.contains("swift build"))
        #expect(discussion.contains("COMPILER_INDEX_STORE_ENABLE"))
        #expect(discussion.contains("Exit codes"))
    }

    @Test("종료 코드 상수가 문서와 일치한다")
    func exitCodesMatchDocumentation() {
        #expect(CommandSupport.findingsExitCode == 1)
        #expect(CommandSupport.failureExitCode == 2)
    }

    @Test("도구 오류는 원인과 해결 방법을 담은 문장으로 바뀐다")
    func describesToolErrors() {
        let message = CommandSupport.describe(CartographError.indexStoreNotFound(searchedPaths: ["/a"]))
        #expect(message.contains("/a"))
        #expect(message.contains("swift build"))
    }

    @Test("도구 오류가 아닌 것도 문자열로 설명된다")
    func describesOtherErrors() {
        struct Boom: Error {}
        #expect(!CommandSupport.describe(Boom()).isEmpty)
    }
    @Test("프로젝트 경로를 절대 경로로 바꾼다")
    func makesProjectPathAbsolute() {
        // libIndexStore 는 상대 경로를 받으면 어서션으로 프로세스를 죽인다.
        // 종료 코드 계약을 지킬 기회조차 없으므로 인덱스 계층에 닿기 전에 막아야 한다.
        #expect(GlobalOptions.absolutePath(".", relativeTo: "/work/proj") == "/work/proj")
        #expect(GlobalOptions.absolutePath("sub", relativeTo: "/work/proj") == "/work/proj/sub")
        #expect(GlobalOptions.absolutePath("../other", relativeTo: "/work/proj") == "/work/other")
        #expect(GlobalOptions.absolutePath("/already/absolute", relativeTo: "/work") == "/already/absolute")
        #expect(GlobalOptions.absolutePath("/a/./b/../c", relativeTo: "/work") == "/a/c")
        #expect(GlobalOptions.absolutePath("~", relativeTo: "/work").hasPrefix("/"))
    }

}
