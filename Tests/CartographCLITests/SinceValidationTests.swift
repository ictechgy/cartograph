import ArgumentParser
@testable import cartograph
import Testing

/// `--since` 범위 렌즈의 적용 범위.
///
/// 진단 목록을 내는 `dead`·`cycles`·`metrics`·`rules`만 렌즈를 낀다. 전체를
/// 그리거나 내보내는 `graph`·`bridges`, 단일 대상에 답하는 `--explain` 계열은
/// 닿을 자리가 없어 앞에서 거부한다. 조용히 받으면 비교 실험이 통과할 수밖에
/// 없는 증거가 된다(`query`의 같은 수정과 한 쌍).
@Suite("--since 적용 범위")
struct SinceValidationTests {
    @Test("graph는 --since를 받으면 사용 오류를 낸다")
    func graphRejectsSince() {
        do {
            _ = try GraphCommand.parse(["--since", "HEAD"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--since cannot be combined with graph"))
        }
    }

    @Test("bridges는 --since를 받으면 사용 오류를 낸다")
    func bridgesRejectsSince() {
        do {
            _ = try BridgesCommand.parse(["--since", "HEAD"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--since cannot be combined with bridges"))
        }
    }

    @Test("dead --explain은 --since와 함께 받으면 사용 오류를 낸다")
    func deadExplainRejectsSince() {
        do {
            _ = try DeadCommand.parse(["--explain", "Foo", "--since", "HEAD"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--since cannot be combined with dead --explain"))
        }
    }

    @Test("cycles --explain은 --since와 함께 받으면 사용 오류를 낸다")
    func cyclesExplainRejectsSince() {
        do {
            _ = try CyclesCommand.parse(["--explain", "Foo", "--since", "HEAD"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--since cannot be combined with cycles --explain"))
        }
    }

    @Test("rules --explain은 --since와 함께 받으면 사용 오류를 낸다")
    func rulesExplainRejectsSince() {
        do {
            _ = try RulesCommand.parse(["--explain", "Foo", "--since", "HEAD"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--since cannot be combined with rules --explain"))
        }
    }

    @Test("목록 조회와 설명 단독은 그대로 통과한다")
    func validCombinationsPass() throws {
        try DeadCommand.parse(["--since", "HEAD"]).validate()
        try CyclesCommand.parse(["--since", "HEAD"]).validate()
        try RulesCommand.parse(["--since", "HEAD"]).validate()
        try DeadCommand.parse(["--explain", "Foo"]).validate()
        try GraphCommand.parse([]).validate()
        try BridgesCommand.parse([]).validate()
    }
}
