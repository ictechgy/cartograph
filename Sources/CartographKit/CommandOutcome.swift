import CartographCore

/// 명령 하나의 실행 결과.
///
/// 종료 코드 결정은 CLI 의 몫이므로 여기서는 사실만 담는다.
public struct CommandOutcome: Sendable, Equatable {
    /// 표준 출력에 쓸 내용.
    public let output: String
    /// 보고된 진단 수(베이스라인 적용 후).
    public let findingCount: Int
    /// 베이스라인이 걸러 낸 진단 수.
    public let suppressedCount: Int

    public init(output: String, findingCount: Int = 0, suppressedCount: Int = 0) {
        self.output = output
        self.findingCount = findingCount
        self.suppressedCount = suppressedCount
    }

    public var hasFindings: Bool { findingCount > 0 }
}
