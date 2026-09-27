import ArgumentParser
@testable import cartograph
import Testing

/// `routes` 의 인자 계약. 종료 코드는 Scripts/verify-cli-contract.sh 가 빌드된 바이너리로 검증한다.
@Suite("routes 명령")
struct RoutesCommandTests {
    private func rejects(_ arguments: [String], contains needle: String) {
        do {
            _ = try RoutesCommand.parse(arguments)
            Issue.record("오류가 발생해야 한다: \(arguments)")
        } catch {
            #expect("\(error)".contains(needle), "\(error)")
        }
    }

    @Test("선언 파일·테스트 포함·서비스·텍스트 형식을 받는다")
    func parsesOptions() throws {
        let command = try RoutesCommand.parse(["--wrappers", "w.json", "--include-tests", "--service", "api", "--format", "text"])
        #expect(command.wrappersPath == "w.json")
        #expect(command.includeTests)
        #expect(command.service == "api")
        #expect(command.format == .text)
    }

    @Test("조인용 전체보내기라 증분·해상도·진단 형식·strict 를 거부한다")
    func rejectsReportFlags() {
        rejects(["--since", "HEAD"], contains: "--since cannot be combined with routes")
        rejects(["--level", "module"], contains: "--level cannot be combined with routes")
        rejects(["--report-format", "json"], contains: "--report-format cannot be combined with routes")
        rejects(["--strict"], contains: "--strict cannot be combined with routes")
    }

    @Test("빈 서비스 이름은 문서를 소비자가 거부하게 만들므로 받지 않는다")
    func rejectsEmptyService() {
        rejects(["--service", ""], contains: "--service must be a non-empty name")
    }

    @Test("도움말이 선언 파일과 테스트 소스 정책을 설명한다")
    func helpExplainsInputs() {
        let discussion = RoutesCommand.configuration.discussion
        #expect(discussion.contains("http-wrappers"))
        #expect(discussion.contains("--include-tests"))
        #expect(discussion.contains("missing-route-usrs"))
    }
}
