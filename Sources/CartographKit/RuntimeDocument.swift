import CartographAnalysis
import CartographCore

/// 실행 계획과 검증 결과가 같은 심볼·시나리오 표현을 사용한다.
public struct RuntimeBinding: Sendable, Equatable, Codable {
    public let contractID: String
    public let mechanism: RuntimeContract.Mechanism
    public let requiredScenarios: [String]
    public let source: SymbolQuery.Subject?
    public let target: SymbolQuery.Subject?
    public let status: RuntimeContractResult.Status
    /// 소스 선언의 파일과 인덱스 unit freshness.
    public let sourceFreshness: RuntimeFreshness
    /// 타깃 선언의 파일과 인덱스 unit freshness.
    public let targetFreshness: RuntimeFreshness
    public let sourceCandidates: [SymbolQueryDocument.Candidate]
    public let targetCandidates: [SymbolQueryDocument.Candidate]
    public let sourceCandidateCount: Int
    public let targetCandidateCount: Int
    public let observedScenarios: [String]
    public let missingScenarios: [String]
    public let failedScenarios: [String]
}

/// 애플리케이션 테스트에 전달할 계획. 원문 소스나 예상 값은 출력하지 않고
/// 지문에만 결합한다.
public struct RuntimePlanDocument: Sendable, Equatable, Codable {
    public let format: String
    public let version: Int
    public let project: String
    public let fingerprint: String
    public let inputFingerprint: String
    /// 로드한 심볼 그래프의 정규화된 내용 지문.
    public let graphFingerprint: String
    /// 실행할 애플리케이션 바이너리의 내용 지문.
    public let executableFingerprint: String
    public let bindings: [RuntimeBinding]
    public let limitations: [String]

    /// 대상 선언을 찾았다는 사실은 해당 시나리오를 실행했다는 의미가 아니다.
    public var isResolved: Bool { bindings.allSatisfy { $0.status == .declared } && !bindings.isEmpty }

    init(project: String, fingerprint: String, inputFingerprint: String, graphFingerprint: String,
         executableFingerprint: String,
         bindings: [RuntimeBinding], limitations: [String]) {
        format = "runtime-plan"
        version = 1
        self.project = project
        self.fingerprint = fingerprint
        self.inputFingerprint = inputFingerprint
        self.graphFingerprint = graphFingerprint
        self.executableFingerprint = executableFingerprint
        self.bindings = bindings
        self.limitations = limitations
    }
}

/// 제공된 실행 관측을 현재 코드·계약과 대조한 결과. 미관측을 미사용으로
/// 바꾸는 필드는 없다.
public struct RuntimeCheckDocument: Sendable, Equatable, Codable {
    public let format: String
    public let version: Int
    public let project: String
    public let planFingerprint: String
    public let observationPlanFingerprint: String
    /// 현재 분석에 사용한 실행 파일 지문.
    public let executableFingerprint: String
    /// 관측 생산자가 기록한 실행 파일 지문.
    public let observationExecutableFingerprint: String
    public let producer: String
    public let status: String
    public let bindings: [RuntimeBinding]
    public let unexpectedContracts: [String]
    public let verifiedCount: Int
    public let unverifiedCount: Int
    public let failureCount: Int
    public let limitations: [String]

    init(project: String, planFingerprint: String, executableFingerprint: String,
         observations: RuntimeObservationsDocument,
         bindings: [RuntimeBinding], unexpectedContracts: [String], limitations: [String]) {
        format = "runtime-check"
        version = 1
        self.project = project
        self.planFingerprint = planFingerprint
        observationPlanFingerprint = observations.planFingerprint
        self.executableFingerprint = executableFingerprint
        observationExecutableFingerprint = observations.executableFingerprint
        producer = observations.producer
        self.bindings = bindings
        self.unexpectedContracts = unexpectedContracts
        verifiedCount = bindings.count { $0.status == .observed }
        unverifiedCount = bindings.count {
            [.declared, .unobserved, .staleObservations, .unverifiedSource, .unverifiedTarget]
                .contains($0.status)
        }
        failureCount = bindings.count - verifiedCount - unverifiedCount + unexpectedContracts.count
        status = planFingerprint != observations.planFingerprint
            || executableFingerprint != observations.executableFingerprint ? "stale"
            : (failureCount > 0 ? "failed" : (unverifiedCount > 0 ? "incomplete" : "verified"))
        self.limitations = limitations
    }
}
