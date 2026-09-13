import ArgumentParser
@testable import cartograph
import Testing

/// 같은 패턴의 거부 가드를 한 자리에서 고정한다.
///
/// 조용히 무시되는 플래그는 스크립트가 잘못 조립한 인자를 증거로 만든다.
/// 종료 코드는 Scripts/verify-cli-contract.sh 가 빌드된 바이너리로 검증하고,
/// 여기서는 거부 문구와 조합을 잡는다.
@Suite("지원하지 않는 플래그 조합")
struct UnsupportedFlagValidationTests {
    private func rejects(_ arguments: [String], contains needle: String) {
        do {
            let command = try BaselineCommand.parse(arguments)
            try command.validate()
            Issue.record("오류가 발생해야 한다: \(arguments)")
        } catch {
            #expect("\(error)".contains(needle), "\(error)")
        }
    }

    @Test("baseline 은 진단 리포트 형식을 받지 않는다")
    func baselineRejectsReportFormat() {
        rejects(["--report-format", "json"], contains: "--report-format cannot be combined with baseline")
    }

    @Test("baseline 은 발견을 세지 않으므로 strict 를 받지 않는다")
    func baselineRejectsStrict() {
        rejects(["--strict"], contains: "--strict cannot be combined with baseline")
    }

    @Test("dead 설명은 테스트 전용 렌즈를 받지 않는다")
    func deadExplainRejectsReportTestOnly() {
        // parse 가 validate 까지 돌리므로 파싱 자체가 실패한다.
        do {
            _ = try DeadCommand.parse(["--explain", "Foo", "--report-test-only"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--report-test-only cannot be combined with dead --explain"))
        }
    }

    @Test("dead 목록은 테스트 전용 렌즈를 그대로 받는다")
    func deadListKeepsReportTestOnly() throws {
        // 거부는 설명(단일 선언)에만 해당한다. 목록 경로를 막으면 안 된다.
        let command = try DeadCommand.parse(["--report-test-only"])
        try command.validate()
    }

    @Test("dataflow 는 strict 를 받지 않는다")
    func dataflowRejectsStrict() {
        do {
            _ = try DataflowCommand.parse(["Worker.run", "--strict"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--strict cannot be combined with dataflow"))
        }
    }

    @Test("query 는 strict 를 받지 않는다")
    func queryRejectsStrict() {
        do {
            _ = try QueryCommand.parse(["Foo", "--strict"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--strict cannot be combined with query"))
        }
    }
}
