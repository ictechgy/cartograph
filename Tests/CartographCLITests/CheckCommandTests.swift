import ArgumentParser
@testable import cartograph
import Testing

@Suite("check 인자 검증")
struct CheckCommandTests {
    @Test("기본 점검 옵션을 파싱한다")
    func parsesDefaults() throws {
        let command = try CheckCommand.parse([])
        try command.validate()
        #expect(command.options.level == nil)
        #expect(!command.options.strict)
    }

    @Test("strict, since, report-format은 통합 점검에서 그대로 허용한다")
    func acceptsCheckOptions() throws {
        for arguments in [
            ["--strict"],
            ["--since", "origin/main"],
            ["--report-format", "json"],
        ] {
            let command = try CheckCommand.parse(arguments)
            try command.validate()
        }
    }

    @Test("check는 사용자가 level을 덮어쓰는 것을 거부한다")
    func rejectsLevelOverride() {
        do {
            let command = try CheckCommand.parse(["--level", "symbol"])
            try command.validate()
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--level cannot be combined with check"))
        }
    }
}
