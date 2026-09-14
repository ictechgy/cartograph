/// 일반 호출 인덱스에 나타나지 않는 의존성을 팀이 검토 가능한 계약으로 선언한다.
public struct RuntimeContract: Sendable, Equatable, Codable {
    public let id: String
    /// 로컬 호출자가 있으면 이름 또는 USR을 적는다. 외부 시스템의 호출은
    /// 생략할 수 있다.
    public let source: String?
    /// 런타임에 도달해야 하는 선언의 이름 또는 USR. 모호한 이름은 검증 실패다.
    public let target: String
    public let mechanism: Mechanism
    /// 이 시나리오를 전부 실행한 양성 근거가 있어야 계약의 실행 검증을 통과한다.
    public let requiredScenarios: [String]
    /// 호출이 일어나도 다른 결과를 낸 회귀를 감지하기 위한 선택적 관측 값.
    public let expectedValue: String?

    public enum Mechanism: String, Sendable, Equatable, Codable, CaseIterable {
        case selector
        case classLookup
        case registration
        case callback
        case bridge
        case other
    }

    /// 특정 프레임워크에 종속되지 않고 사용자 테스트가 증명할 동적 연결을 기록한다.
    public init(id: String, source: String? = nil, target: String, mechanism: Mechanism,
                requiredScenarios: [String], expectedValue: String? = nil) {
        self.id = id
        self.source = source
        self.target = target
        self.mechanism = mechanism
        self.requiredScenarios = requiredScenarios
        self.expectedValue = expectedValue
    }
}

/// 런타임 계약 입력. 관측 파일과 분리해 실행하지 않은 기대를 실행 결과로
/// 읽지 않게 한다.
public struct RuntimeContractsDocument: Sendable, Equatable, Codable {
    public let format: String
    public let version: Int
    public let contracts: [RuntimeContract]

    /// 계약 문서를 만든다. 읽는 쪽은 형식·버전·중복 ID와 비어 있는
    /// 시나리오를 검증해야 한다.
    public init(format: String = "runtime-contracts", version: Int = 1, contracts: [RuntimeContract]) {
        self.format = format
        self.version = version
        self.contracts = contracts
    }
}

/// 애플리케이션 테스트나 계측기가 기록한 실행 한 건. 도구 자체가 관측했다고
/// 가장하지 않는다.
public struct RuntimeObservation: Sendable, Equatable, Codable {
    public let contract: String
    public let scenario: String
    public let outcome: Outcome
    public let value: String?

    public enum Outcome: String, Sendable, Equatable, Codable {
        case observed
        case failed
    }

    /// 입력이 없다는 사실은 관측 실패나 삭제 가능성을 뜻하지 않는다. 실패는
    /// 명시적으로 기록한다.
    public init(contract: String, scenario: String, outcome: Outcome, value: String? = nil) {
        self.contract = contract
        self.scenario = scenario
        self.outcome = outcome
        self.value = value
    }
}

/// 런타임 계약의 소스·타깃이 현재 인덱스와 같은 빌드 상태인지 나타낸다.
public enum RuntimeFreshness: String, Sendable, Equatable, Codable, CaseIterable {
    /// 이 binding의 파일과 인덱스 unit이 현재 상태로 확인되었다.
    case fresh
    /// freshness를 계산하지 않은 순수 validator 호출이다.
    case notChecked
    /// 해당 binding에는 소스 파일이 없다.
    case notApplicable
    /// 인덱스가 가리키는 파일이 더 이상 없다.
    case missingFile
    /// 소스 파일을 읽을 수 없다.
    case unreadableFile
    /// 해당 파일의 최신 인덱스 unit 날짜를 알 수 없다.
    case unknownIndexDate
    /// 파일 수정 시각이 해당 파일의 최신 인덱스 unit보다 새롭다.
    case sourceNewerThanIndex
}

/// 준비한 계획과 연결된 실행 관측. 다른 소스·인덱스·계약의 관측을
/// 재사용하지 않도록 지문을 요구한다.
public struct RuntimeObservationsDocument: Sendable, Equatable, Codable {
    public let format: String
    public let version: Int
    public let planFingerprint: String
    /// 계획을 실행한 애플리케이션 바이너리의 내용 지문.
    public let executableFingerprint: String
    public let producer: String
    public let observations: [RuntimeObservation]

    /// 관측 생산자의 이름을 보존해 외부 테스트 결과와 분석기의 정적 근거를 구분한다.
    public init(format: String = "runtime-observations", version: Int = 1, planFingerprint: String,
                executableFingerprint: String, producer: String, observations: [RuntimeObservation]) {
        self.format = format
        self.version = version
        self.planFingerprint = planFingerprint
        self.executableFingerprint = executableFingerprint
        self.producer = producer
        self.observations = observations
    }
}
