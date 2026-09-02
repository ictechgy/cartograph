import ArgumentParser
@testable import CartographCLI
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
        #expect(names == ["graph", "cycles", "dead", "metrics", "rules", "baseline", "init"])
        // 인자 없이 실행하면 도움말이 나와야 한다. 기본 하위 명령이 있으면
        // 처음 써 보는 사용자가 DOT 덤프를 마주하게 된다.
        #expect(CartographCommand.configuration.defaultSubcommand == nil)
    }

    @Test("도움말에 인덱스 생성 방법과 종료 코드가 적혀 있다")
    func helpExplainsPrerequisitesAndExitCodes() {
        let discussion = CartographCommand.configuration.discussion
        #expect(discussion.contains("index-store-path"))
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
}
