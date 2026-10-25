import ArgumentParser
import Testing

@testable import cartograph

@Suite("수정 검증 명령 인자")
struct FixVerificationCommandTests {
    @Test("검증 명령과 적용은 함께 명시해야 한다")
    func requiresApply() {
        #expect(throws: (any Error).self) { _ = try FixCommand.parse(["--verify-command", "[\"swift\",\"build\"]"]) }
        #expect(throws: (any Error).self) { _ = try FixCommand.parse(["--apply", "--verify-timeout", "5"]) }
        #expect(throws: (any Error).self) { _ = try FixCommand.parse(["--apply", "--recovery-directory", "/tmp/new"]) }
    }

    @Test("셸 문자열 빈 argv 비문자 인자 NUL 및 잘못된 예산은 사용 오류다")
    func rejectsInvalidInput() {
        for command in ["swift build", "[]", "[\"\"]", "[1]", "[\"a\\u0000b\"]"] {
            #expect(throws: (any Error).self) { _ = try FixCommand.parse(["--apply", "--verify-command", command]) }
        }
        for timeout in ["0", "-1", "86401", "nan", "inf"] {
            #expect(throws: (any Error).self) {
                _ = try FixCommand.parse([
                    "--apply", "--verify-command", "[\"swift\",\"build\"]", "--verify-timeout", timeout,
                ])
            }
        }
    }

    @Test("기존 드라이런과 명시 적용 및 argv 검증을 파싱한다")
    func preservesExistingModes() throws {
        #expect(try FixCommand.parse([]).verifyCommand == nil)
        #expect(try FixCommand.parse(["--apply"]).apply)
        let command = try FixCommand.parse([
            "--apply", "--verify-command", "[\"swift\",\"build\"]", "--verify-timeout", "0.1",
        ])
        #expect(command.verifyTimeout == 0.1)
    }
}
