import ArgumentParser
@testable import cartograph
import Testing

/// `query` 인자 검증.
///
/// `--since` 는 진단 목록에 거는 범위 렌즈인데 `query` 는 선언 하나에 답하므로
/// 닿을 자리가 없다. 조용히 받으면 비교 실험이 통과할 수밖에 없는 증거가 된다.
/// 거부는 파싱 단계(`validate()`)에서 나며 종료 코드 64 로 끝난다.
@Suite("query 인자 검증")
struct QueryCommandTests {
    @Test("--since 를 받으면 사용 오류를 낸다")
    func sinceIsRejected() {
        do {
            _ = try QueryCommand.parse(["Foo", "--since", "HEAD"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--since cannot be combined with query"))
        }
    }

    @Test("배치 질의에서도 --since 를 받으면 사용 오류를 낸다")
    func sinceIsRejectedForBatch() {
        do {
            _ = try QueryCommand.parse(["--batch", "requests.json", "--since", "HEAD"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--since cannot be combined with query"))
        }
    }

    @Test("--since 없이는 그대로 통과한다")
    func passesWithoutSince() throws {
        let single = try QueryCommand.parse(["Foo"])
        try single.validate()
        let batch = try QueryCommand.parse(["--batch", "requests.json"])
        try batch.validate()
    }
}
