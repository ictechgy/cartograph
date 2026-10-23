import CartographAnalysis
import CartographCore
import Foundation

/// 한 번 읽은 인덱스 스냅샷과, 그 위에서 만든 그래프들.
///
/// 인덱스를 읽는 것이 파이프라인에서 가장 느린 단계다. 명령마다 다시 읽으면
/// `baseline` 처럼 여러 분석을 묶어 돌리는 경로에서 그 비용을 그대로 반복한다.
/// 같은 스냅샷에서 필요한 해상도의 그래프를 그때그때 만들어 쓴다.
public struct AnalysisContext: Sendable {
    public let snapshot: IndexSnapshot
    /// 이미 지워졌지만 인덱스에 남은 파일. 분석 한계를 설명할 때만 쓴다.
    public let missingSourcePaths: [String]
    /// 읽기 실패로 보존 정보가 불완전한 파일. 선언에는 sourceUnavailable 근거가 붙는다.
    public let unreadableSourcePaths: [String]
    /// 지역 함수 구분이 불확실한 소스만 분석 한계에 알리기 위한 실제 개수.
    public let unresolvedLocalFunctionsByPath: [String: Int]
    /// 구문 보강에서 실제로 제외한 지역 함수와 그 원인.
    public let localFunctionDiagnostics: [LocalFunctionDiagnostic]
    private let pathFilter: PathFilter
    private let edgeKinds: Set<EdgeKind>
    /// `--external-retentions` 로 읽은 문서. 스냅샷과 함께 한 번만 읽는다.
    ///
    /// 파일 읽기는 실패할 수 있어 던지는 자리(`loadContext`)에서 해야 한다. 질의 API 는
    /// 던지지 않으므로 여기 실어 두면 질의가 그대로 순수하게 남는다.
    public let externalRetentions: ExternalRetentionsDocument?
    /// 보존 규칙이 쓰는 색인. 문서가 없으면 비어 있다. 접근할 때마다 다시 만들지 않는다.
    public let externalRetentionIndex: ExternalRetentionIndex
    /// nil은 아직 자동 발견 입력을 수집하지 않은 문맥이며 빈 배열과 다르다.
    public let runtimeFiles: [RuntimeFileFacts]?
    public let runtimeFreshness: [String: RuntimeFreshness]
    /// 명시적 빌드 근거로 검증되어 기본 경로 필터 밖에서 추가한 소스 파일.
    let supplementalRuntimeSourcePaths: Set<String>
    /// 실행 근거용 입력 해시를 읽기 전후로 확인한 문맥에만 설정한다.
    public private(set) var runtimeInputFingerprint: String?
    /// 같은 loadContext 실행에서 수집한 프로젝트 파일 목록.
    ///
    /// 외부에서 직접 만든 문맥은 nil일 수 있고, 그 경우 소비자가 기존 walk로 폴백한다.
    private(set) var projectFileInventory: ProjectFileInventory?
    /// 실제 입력을 읽을 때의 선택 근거. 후속 재탐색으로 과거 그래프의 출처를 바꾸지 않는다.
    private(set) var indexSelectionLimitations: [String] = []

    public init(
        snapshot: IndexSnapshot,
        pathFilter: PathFilter = .passthrough,
        edgeKinds: Set<EdgeKind> = [],
        externalRetentions: ExternalRetentionsDocument? = nil,
        missingSourcePaths: [String] = [],
        unreadableSourcePaths: [String] = [],
        unresolvedLocalFunctionsByPath: [String: Int] = [:],
        localFunctionDiagnostics: [LocalFunctionDiagnostic] = [],
        runtimeFiles: [RuntimeFileFacts]? = nil,
        runtimeFreshness: [String: RuntimeFreshness] = [:],
        supplementalRuntimeSourcePaths: Set<String> = []
    ) {
        self.snapshot = snapshot
        self.missingSourcePaths = missingSourcePaths
        self.unreadableSourcePaths = unreadableSourcePaths
        self.unresolvedLocalFunctionsByPath = unresolvedLocalFunctionsByPath
        self.localFunctionDiagnostics = localFunctionDiagnostics
        self.runtimeFiles = runtimeFiles
        self.runtimeFreshness = runtimeFreshness
        self.supplementalRuntimeSourcePaths = supplementalRuntimeSourcePaths
        self.pathFilter = pathFilter
        self.edgeKinds = edgeKinds
        self.externalRetentions = externalRetentions
        externalRetentionIndex = externalRetentions.map { ExternalRetentionIndex($0.retentions) } ?? .empty
        projectFileInventory = nil
        graphCache = GraphBuildCache()
    }

    func bindingProjectFileInventory(_ inventory: ProjectFileInventory) -> AnalysisContext {
        var copy = self
        copy.projectFileInventory = inventory
        return copy
    }

    func bindingIndexSelectionLimitations(_ limitations: [String]) -> AnalysisContext {
        var copy = self
        copy.indexSelectionLimitations = limitations
        return copy
    }

    /// 같은 문맥이 만든 그래프를 레벨별로 한 번씩만 간직한다.
    ///
    /// `baseline` 은 순환·미사용·지표·레이어 네 분석을 한 문맥에서 돌린다. 문맥이
    /// 기억하지 않으면 같은 레벨의 그래프를 그 배수만큼 다시 만든다 — 정점과
    /// 간선을 전부 다시 스캔하고 정렬하는 비용이다.
    ///
    /// 경합 시 같은 키를 두 스레드가 각자 계산할 수 있다(값만 자물쇠 안에 넣는다).
    /// 그래도 안전한 이유는 `GraphBuilder.BuildResult` 가 순수한 값이라 어느 쪽을
    /// 받아도 관찰 결과가 같기 때문이다. 가변 상태를 품게 되면 이 가정이 깨진다.
    private final class GraphBuildCache: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Key: GraphBuilder.BuildResult] = [:]

        struct Key: Hashable {
            let level: GraphLevel
            let includeExternal: Bool
            let includeSelfLoops: Bool
        }

        func result(for key: Key, make: () -> GraphBuilder.BuildResult) -> GraphBuilder.BuildResult {
            lock.lock()
            defer { lock.unlock() }
            if let known = results[key] { return known }
            // 만드는 동안 자물쇠를 쥐고 있으면 병렬 질의가 줄 서서 기다린다.
            // 그래프 만들기는 던지지 않는 순수 계산이므로 결과만 자물쇠 안에 넣는다.
            lock.unlock()
            let built = make()
            lock.lock()
            results[key] = built
            return built
        }
    }

    private let graphCache: GraphBuildCache
    private let reviewCache = ReviewCache()
    private let runtimeCache = RuntimeCache()
    private let impactPreparationCache = ImpactPreparationCache()
    /// 세션이 세대 문맥에 붙이는 캐시. 직접 만든 문맥에는 없다(nil).
    ///
    /// 분석 한계와 통합 점검은 스냅샷만이 아니라 서비스 설정·베이스라인 파일·소스 수정 시각에도 기댄다.
    /// 세션은 그 입력을 세대 지문으로 묶으므로 같은 세대에서는 답이 같지만, 직접 만든 문맥을 쥐고 파일을
    /// 고쳐 가며 다시 쓰는 라이브러리 호출은 지금처럼 요청마다 현재 상태로 세어야 답이 바뀌지 않는다.
    private var generationCache: GenerationCache?

    /// 세션 세대용 캐시를 붙인 복사본. 값 복사는 같은 캐시를 공유한다.
    ///
    /// 새로 만든 문맥(다음 세대, Core Data 보강 문맥)은 붙이기 전까지 캐시가 없어 이 세대의 값을 보지 않는다.
    func bindingGenerationCache() -> AnalysisContext {
        var copy = self
        copy.generationCache = GenerationCache()
        return copy
    }

    /// 같은 세대·같은 스토어 시각의 분석 한계는 한 번만 센다. 세대 캐시가 없는 문맥은 부를 때마다 센다.
    ///
    /// 스토어 시각은 세대 지문 밖이라(지문은 유닛 디렉터리만 본다) 키에 넣는다. 심볼 그래프는 이 문맥의
    /// 것만 넘기므로(호출자 전부 `buildGraph(level: .symbol)`) 넘겼는지만 키에 넣는다.
    func generationLimitations(storeDate: Date?, hasSymbolGraph: Bool, make: () -> [String]) -> [String] {
        guard let generationCache else { return make() }
        return generationCache.limitations(for: .init(storeDate: storeDate, hasSymbolGraph: hasSymbolGraph), make: make)
    }

    /// 같은 세대의 통합 점검 결과(한계 제외)는 한 번만 만든다. 실패는 담지 않아 다음 요청이 다시 시도한다.
    ///
    /// 이름 붙인 베이스라인이 없어 실패한 결과를 담으면, 파일을 만든 뒤 다시 물어도 세대가 바뀔 때까지 지난
    /// 오류가 돌아온다. 담지 않으면 다음 요청이 지금처럼 그때의 파일을 다시 읽는다.
    func generationCheck(make: () throws -> CheckFindings) rethrows -> CheckFindings {
        guard let generationCache else { return try make() }
        return try generationCache.check(make: make)
    }

    private final class GenerationCache: @unchecked Sendable {
        struct LimitationKey: Equatable {
            let storeDate: Date?
            let hasSymbolGraph: Bool
        }

        // 값마다 자물쇠를 따로 둔다. 만드는 동안 쥐고 있으므로, 한 값을 만들다 다른 값을 묻는 변경이 생겨도
        // 같은 자물쇠를 다시 잡아 멈추지 않게 한다.
        private let limitationLock = NSLock()
        private let checkLock = NSLock()
        /// 마지막 키의 한계 하나만 둔다. 세대 안에서 키가 바뀌는 것은 스토어 루트 시각이 바뀐 드문 경우뿐이다.
        private var limitationEntry: (key: LimitationKey, value: [String])?
        private var checkValue: CheckFindings?

        func limitations(for key: LimitationKey, make: () -> [String]) -> [String] {
            limitationLock.lock()
            defer { limitationLock.unlock() }
            if let limitationEntry, limitationEntry.key == key { return limitationEntry.value }
            let made = make()
            limitationEntry = (key, made)
            return made
        }

        func check(make: () throws -> CheckFindings) rethrows -> CheckFindings {
            checkLock.lock()
            defer { checkLock.unlock() }
            if let checkValue { return checkValue }
            let made = try make()
            checkValue = made
            return made
        }
    }

    func bindingRuntimeInputFingerprint(_ fingerprint: String) -> AnalysisContext {
        var copy = self
        copy.runtimeInputFingerprint = fingerprint
        return copy
    }

    /// 자동 발견 결과도 같은 세대의 스냅샷에서 한 번만 계산한다.
    public func runtimeDiscovery() -> RuntimeDiscoveryReport? {
        guard let runtimeFiles else { return nil }
        return runtimeCache.result {
            RuntimeDiscoveryResolver().resolve(files: runtimeFiles, snapshot: snapshot,
                graph: buildGraph(level: .symbol).graph, freshness: runtimeFreshness)
        }
    }

    private final class RuntimeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: RuntimeDiscoveryReport?

        func result(make: () -> RuntimeDiscoveryReport) -> RuntimeDiscoveryReport {
            lock.lock()
            defer { lock.unlock() }
            if let value { return value }
            let made = make()
            value = made
            return made
        }
    }

    /// 반복 영향 질의가 같은 스냅샷의 프레임워크·테스트 근거를 매번 다시 분류하지 않게 한다.
    func impactReviewReasons() -> [NodeID: Set<RetentionReason>] {
        reviewCache.result {
            RetentionPolicy(externalRetentions: externalRetentionIndex)
                .reviewReasons(in: buildGraph(level: .symbol).graph, snapshot: snapshot)
        }
    }

    private final class ReviewCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [NodeID: Set<RetentionReason>]?

        func result(make: () -> [NodeID: Set<RetentionReason>]) -> [NodeID: Set<RetentionReason>] {
            lock.lock()
            defer { lock.unlock() }
            if let value { return value }
            let made = make()
            value = made
            return made
        }
    }

    /// 스냅샷에만 의존하는 준비 값은 같은 문맥에서 한 번 만들고, 요청별 계약·실행 근거는 넣지 않는다.
    /// 값 복사는 같은 그래프를 공유하지만 refresh나 Core Data 보강의 새 문맥은 별도 캐시를 갖는다.
    func impactLifecycle(
        make: ((CodeGraph) -> XCTestLifecycleImpact)? = nil
    ) -> XCTestLifecycleImpact {
        // 같은 캐시 잠금을 중첩하지 않도록 신원을 먼저 준비한다.
        let identity = impactTestIdentity().xctest
        return impactPreparationCache.lifecycle {
            let graph = buildGraph(level: .symbol).graph
            return make?(graph) ?? XCTestLifecycleImpact(in: graph, identity: identity)
        }
    }

    /// 테스트 분류와 실행 계약이 같은 스냅샷 신원을 공유한다.
    func impactTestIdentity() -> TestCandidateIdentity {
        impactPreparationCache.identity { TestCandidateIdentity(snapshot: snapshot) }
    }

    /// 파일 선택이 있을 때만 원래 경로별 정점을 준비한다. 링크 해석은 요청마다 다시 한다.
    func impactRawNodesByFile(
        make: (CodeGraph) -> [String: [NodeID]] = { ImpactSelection.rawNodesByFile(in: $0) }
    ) -> [String: [NodeID]] {
        impactPreparationCache.files { make(buildGraph(level: .symbol).graph) }
    }

    /// 파일·리소스 선택만 하는 요청은 이름 색인을 만들지 않는다.
    func impactQueryIndex(
        make: (CodeGraph) -> GraphQueryIndex = { GraphQueryIndex(graph: $0) }
    ) -> GraphQueryIndex {
        impactPreparationCache.names { make(buildGraph(level: .symbol).graph) }
    }

    private final class ImpactPreparationCache: @unchecked Sendable {
        private let lock = NSLock()
        private var lifecycleValue: XCTestLifecycleImpact?
        private var fileValue: [String: [NodeID]]?
        private var nameValue: GraphQueryIndex?
        private var identityValue: TestCandidateIdentity?

        func identity(make: () -> TestCandidateIdentity) -> TestCandidateIdentity {
            lock.lock()
            defer { lock.unlock() }
            if let identityValue { return identityValue }
            let made = make()
            identityValue = made
            return made
        }

        func lifecycle(make: () -> XCTestLifecycleImpact) -> XCTestLifecycleImpact {
            lock.lock()
            defer { lock.unlock() }
            if let lifecycleValue { return lifecycleValue }
            let made = make()
            lifecycleValue = made
            return made
        }

        func files(make: () -> [String: [NodeID]]) -> [String: [NodeID]] {
            lock.lock()
            defer { lock.unlock() }
            if let fileValue { return fileValue }
            let made = make()
            fileValue = made
            return made
        }

        func names(make: () -> GraphQueryIndex) -> GraphQueryIndex {
            lock.lock()
            defer { lock.unlock() }
            if let nameValue { return nameValue }
            let made = make()
            nameValue = made
            return made
        }
    }

    /// 지정한 해상도의 그래프를 만든다. 같은 문맥·같은 해상도면 처음 만든 것을 돌려준다.
    public func buildGraph(level: GraphLevel, includeExternal: Bool = false) -> GraphBuilder.BuildResult {
        buildGraph(level: level, includeExternal: includeExternal, includeSelfLoops: false)
    }

    /// 자기 간선은 명시한 심볼 투영에만 포함한다. 롤업 내부 관계는 기존처럼 제거한다.
    public func buildGraph(
        level: GraphLevel, includeExternal: Bool = false, includeSelfLoops: Bool
    ) -> GraphBuilder.BuildResult {
        let keepsSelfLoops = includeSelfLoops && level == .symbol
        return graphCache.result(for: .init(
            level: level, includeExternal: includeExternal, includeSelfLoops: keepsSelfLoops
        )) {
            GraphBuilder(
                options: .init(
                    level: level,
                    pathFilter: pathFilter,
                    edgeKinds: edgeKinds,
                    includeExternal: includeExternal,
                    dropSelfLoops: !keepsSelfLoops
                )
            )
            .buildResult(from: snapshot)
        }
    }
}

/// 이름 조회 결과의 기존 Kit API 이름을 유지한다.
public typealias NodeLookup = GraphNodeLookup
