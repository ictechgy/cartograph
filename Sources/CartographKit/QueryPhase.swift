/// 진단 레코드의 닫힌 단계 목록. 선언 순서가 CLI 출력 순서다.
package enum QueryPhase: String, CaseIterable, Hashable, Sendable {
    case cliSetup = "cli_setup"
    case inputPreparation = "input_preparation"
    case rawSnapshot = "raw_snapshot"
    case syntaxContext = "syntax_context"
    case graphQuerySetup = "graph_query_setup"
    case foundFacts = "found_facts"
    case answer
    case serialization
    case cliOutput = "cli_output"
}

/// 서비스는 출력이나 집계 방식 없이 단계와 경과 시간만 알린다.
package typealias QueryPhaseObserver = @Sendable (QueryPhase, Duration) -> Void

/// 비활성 경로는 시계를 읽기 전에 원래 본문으로 바로 들어간다.
package func measureQueryPhase<Value>(
    _ phase: QueryPhase,
    observer: QueryPhaseObserver?,
    now: () -> ContinuousClock.Instant = { ContinuousClock().now },
    _ body: () throws -> Value
) rethrows -> Value {
    guard let observer else { return try body() }
    let start = now()
    defer { observer(phase, start.duration(to: now())) }
    return try body()
}
