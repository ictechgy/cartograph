import Foundation
@testable import CartographIndexStore
import Testing

@Suite("Xcode 경로 명령 수집")
struct XcodeEnvironmentTests {
    @Test("정상 종료한 명령의 경로만 앞뒤 공백을 제거해 반환한다")
    func readsSuccessfulCommandOutput() {
        #expect(XcodeEnvironment.output(from: command("printf '  /toolchain\\n'")) == "/toolchain")
    }

    @Test("빈 출력과 실행 실패는 개발자 경로로 쓰지 않는다")
    func rejectsMissingOutputAndLaunchFailure() {
        #expect(XcodeEnvironment.output(from: command("printf '  \\n'")) == nil)
        let missing = Process()
        missing.executableURL = URL(fileURLWithPath: "/cartograph-missing-xcode-select")
        #expect(XcodeEnvironment.output(from: missing) == nil)
    }

    @Test("출력이 닫힌 뒤 실패한 명령의 경로는 사용하지 않는다")
    func waitsForFailureAfterOutputCloses() {
        let process = command("printf '/toolchain\\n'; exec 1>&-; sleep 0.05; exit 7")
        #expect(XcodeEnvironment.output(from: process) == nil)
        #expect(process.terminationStatus == 7)
    }

    @Test("신호로 종료한 명령도 성공 경로를 반환하지 않는다")
    func rejectsSignalledExit() {
        #expect(XcodeEnvironment.output(from: command("printf '/toolchain\\n'; kill -TERM $$")) == nil)
    }

    private func command(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }
}
