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
    /// `--explain` 이 가리킨 이름이 어디에도 없었는지 여부.
    ///
    /// 코드의 문제가 아니라 인자의 문제라 진단으로 세지 않는다. 그래도 조용히 0 으로
    /// 끝나면 CI 스크립트의 오타가 영영 드러나지 않으므로 호출부에 사실을 알린다.
    public let subjectNotFound: Bool
    /// 임계값을 넘겨 실패로 처리해야 하는 경우의 사유.
    ///
    /// 오류로 즉시 던지지 않고 결과에 실어 보낸다. 임계값을 넘겼다는 사실만 알려 주고
    /// 무엇이 문제인지는 보여 주지 않으면, 사용자는 임계값을 풀고 다시 돌리는 수밖에 없다.
    public let thresholdFailure: CartographError?
    /// 찾지 못한 이름들. 배치 질의에서만 채워진다.
    ///
    /// 불리언 하나만으로는 1000건 배치에서 어느 셋이 없었는지 알 수 없다. 표준 출력의
    /// 상태로 되짚을 수는 있지만, 그러려면 실패를 본 사람이 JSON 을 다시 훑어야 한다.
    public let missingSubjects: [String]

    public init(
        output: String,
        findingCount: Int = 0,
        suppressedCount: Int = 0,
        thresholdFailure: CartographError? = nil,
        subjectNotFound: Bool = false,
        missingSubjects: [String] = []
    ) {
        self.output = output
        self.findingCount = findingCount
        self.suppressedCount = suppressedCount
        self.thresholdFailure = thresholdFailure
        self.subjectNotFound = subjectNotFound
        self.missingSubjects = missingSubjects
    }

    public var hasFindings: Bool { findingCount > 0 }
}
