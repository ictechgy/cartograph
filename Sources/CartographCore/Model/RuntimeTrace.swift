/// 자동 계측 한 번에서 관찰한 런타임 경계 사건.
///
/// `phase`가 lookup이면 이름 조회 결과이고, registration이면 등록 호출이 반환했다는 뜻이다.
/// invocation-returned만 실제 selector 호출이 정상 반환한 근거다.
public struct RuntimeTraceEvent: Codable, Sendable, Equatable {
    public let api: String
    public let phase: String
    public let name: String?
    public let result: Bool?
    public let receiverClass: String?
    public let receiverIsClass: Bool?
    public let callerSymbol: String?
    public let callerImage: String?
    public let callerOffset: UInt64?
    public let calleeSymbol: String?
    public let calleeImage: String?
    public let dispatchUncertain: Bool?

    /// 조회·등록·호출을 같은 형식으로 교환하되, 관찰하지 않은 값은 nil로 남긴다.
    public init(
        api: String,
        phase: String,
        name: String? = nil,
        result: Bool? = nil,
        receiverClass: String? = nil,
        receiverIsClass: Bool? = nil,
        callerSymbol: String? = nil,
        callerImage: String? = nil,
        callerOffset: UInt64? = nil,
        calleeSymbol: String? = nil,
        calleeImage: String? = nil,
        dispatchUncertain: Bool? = nil
    ) {
        self.api = api
        self.phase = phase
        self.name = name
        self.result = result
        self.receiverClass = receiverClass
        self.receiverIsClass = receiverIsClass
        self.callerSymbol = callerSymbol
        self.callerImage = callerImage
        self.callerOffset = callerOffset
        self.calleeSymbol = calleeSymbol
        self.calleeImage = calleeImage
        self.dispatchUncertain = dispatchUncertain
    }
}

/// 현재 분석 입력과 실행 파일에 묶인 자동 런타임 관측 문서.
///
/// 수집기가 로드되지 않았거나 실행 중 입력이 바뀌면 일부 사건이 있어도
/// `collectionComplete`를 false로 유지해 깨끗한 실행으로 오인하지 않게 한다.
public struct RuntimeTraceDocument: Codable, Sendable, Equatable {
    public let format: String
    public let version: Int
    public let inputFingerprint: String
    public let executableFingerprint: String
    public let executablePath: String
    public let collectorActive: Bool
    public let collectionComplete: Bool
    public let processExitCode: Int?
    public let events: [RuntimeTraceEvent]
    public let droppedEvents: Int
    public let limitations: [String]
    public let launch: RuntimeTraceLaunch?
    public let observationWindow: RuntimeTraceObservationWindow?
    public let evidenceComplete: Bool?

    /// 프로세스 성공과 봉인된 관측 구간을 구분하면서 둘의 사용 가능한 근거를 질의한다.
    public var hasCompleteEvidence: Bool {
        guard format == "runtime-trace" else { return false }
        if version == 1 {
            return collectionComplete && collectorActive && droppedEvents == 0 && processExitCode == 0
                && observationWindow == nil && evidenceComplete == nil
                && (launch.map { ($0.processID ?? 0) > 0 } ?? true)
        }
        return version == 2 && evidenceComplete == true && Self.windowIsComplete(
            collectorActive: collectorActive, collectionComplete: collectionComplete,
            droppedEvents: droppedEvents, eventCount: events.count, launch: launch, window: observationWindow
        )
    }

    /// 실행 관측과 그것을 해석할 수 있는 완전성 근거를 함께 보존한다.
    public init(
        format: String = "runtime-trace",
        version: Int = 1,
        inputFingerprint: String,
        executableFingerprint: String,
        executablePath: String,
        collectorActive: Bool,
        collectionComplete: Bool,
        processExitCode: Int?,
        events: [RuntimeTraceEvent],
        droppedEvents: Int,
        limitations: [String],
        launch: RuntimeTraceLaunch? = nil,
        observationWindow: RuntimeTraceObservationWindow? = nil
    ) {
        self.format = format
        self.version = version
        self.inputFingerprint = inputFingerprint
        self.executableFingerprint = executableFingerprint
        self.executablePath = executablePath
        self.collectorActive = collectorActive
        self.collectionComplete = collectionComplete
        self.processExitCode = processExitCode
        self.events = events
        self.droppedEvents = droppedEvents
        self.limitations = limitations
        self.launch = launch
        self.observationWindow = observationWindow
        evidenceComplete = version == 2 ? Self.windowIsComplete(
            collectorActive: collectorActive, collectionComplete: collectionComplete,
            droppedEvents: droppedEvents, eventCount: events.count, launch: launch, window: observationWindow
        ) : nil
    }

    private static func windowIsComplete(
        collectorActive: Bool, collectionComplete: Bool, droppedEvents: Int,
        eventCount: Int, launch: RuntimeTraceLaunch?, window: RuntimeTraceObservationWindow?
    ) -> Bool {
        guard collectorActive, !collectionComplete, droppedEvents == 0,
              let pid = launch?.processID, pid > 0, let window, window.complete,
              window.trigger == "duration", (1...3_600_000).contains(window.requestedMilliseconds),
              let elapsed = window.elapsedMilliseconds,
              (window.requestedMilliseconds...3_610_000).contains(elapsed),
              window.sealedEventCount == eventCount, window.processOutcome == .stoppedAfterSeal else { return false }
        return true
    }
}

/// GUI 앱의 종료 성공과 독립적인, 명시적으로 닫은 관측 구간.
public struct RuntimeTraceObservationWindow: Codable, Sendable, Equatable {
    /// 도구가 시작한 프로세스의 정리 결과이며 시나리오 성공 판정은 아니다.
    public enum ProcessOutcome: String, Codable, Sendable {
        case stoppedAfterSeal
        case exitedBeforeSeal
        case unverified
    }

    public let trigger: String
    public let requestedMilliseconds: Int
    public let elapsedMilliseconds: Int?
    public let complete: Bool
    public let sealedEventCount: Int?
    public let processOutcome: ProcessOutcome

    /// 종료 코드 대신 봉인된 구간의 범위와 확인 가능한 정리 상태를 보존한다.
    public init(
        requestedMilliseconds: Int,
        elapsedMilliseconds: Int? = nil,
        complete: Bool,
        sealedEventCount: Int? = nil,
        processOutcome: ProcessOutcome
    ) {
        trigger = "duration"
        self.requestedMilliseconds = requestedMilliseconds
        self.elapsedMilliseconds = elapsedMilliseconds
        self.complete = complete
        self.sealedEventCount = sealedEventCount
        self.processOutcome = processOutcome
    }
}

/// 같은 바이너리를 어디에서 실행했는지 재현할 수 있도록 실행 대상을 기록한다.
public struct RuntimeTraceLaunch: Codable, Sendable, Equatable {
    /// 실행 환경과 기기 식별자의 의미를 제한한다.
    public enum Platform: String, Codable, Sendable {
        case macOS
        case iOSSimulator
    }

    public let platform: Platform
    public let processID: Int32?
    public let simulatorID: String?
    public let bundleID: String?

    /// 실패한 시작도 요청한 대상을 남길 수 있도록 PID는 선택적으로 둔다.
    public init(platform: Platform, processID: Int32?, simulatorID: String? = nil, bundleID: String? = nil) {
        self.platform = platform
        self.processID = processID
        self.simulatorID = simulatorID
        self.bundleID = bundleID
    }
}
