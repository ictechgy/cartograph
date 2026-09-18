import CartographConfig
import CartographCore
import CartographIndexStore
import CryptoKit
import Foundation

/// 분석 세션을 새로 읽거나 다시 읽을 때 발생하는 오류.
public enum AnalysisSessionError: Error, Sendable, Equatable, LocalizedError {
    /// 인덱스·소스·설정이 읽는 도중 계속 바뀌어 일관된 문맥을 만들지 못했다.
    case inputChangedDuringRefresh(attempts: Int)
    /// 분석 입력 위치가 비밀 자료로 보이는 파일을 가리킨다.
    case sensitiveInput
    /// 세션 문맥이 준비되지 않은 내부 상태다.
    case unavailable

    /// 재시도 오류를 사람이 읽을 수 있는 안내로 바꾼다.
    public var errorDescription: String? {
        switch self {
        case let .inputChangedDuringRefresh(attempts):
            return "Analysis inputs changed during refresh after \(attempts) attempts; retry when the build is idle."
        case .sensitiveInput:
            return "Analysis input points to a credential-like file; configure a non-secret path "
                + "before using a session."
        case .unavailable:
            return "Analysis session is unavailable because its prepared context was discarded."
        }
    }
}

/// 여러 에이전트 질의를 하나의 일관된 분석 문맥에서 처리하는 세션.
///
/// 인덱스와 구문 보강은 첫 문맥을 만들 때 한 번만 수행하고, `QuerySession`은
/// 첫 `query` 요청 때 늦게 만든다. 이 타입은 단일 소비자가 순차적으로 사용해야
/// 하며, 동시에 여러 작업에서 공유하지 않는다.
public final class AnalysisSession {
    /// 세션이 서비스를 다시 만들 때 사용할 공장 함수.
    public typealias ServiceFactory = () throws -> CartographService
    /// 읽기 전후의 입력 상태를 식별하는 함수.
    public typealias InputFingerprintProvider = () throws -> String

    /// 현재 분석 문맥의 상태와 규모.
    public struct Metadata: Sendable, Equatable, Codable {
        /// 성공적으로 준비된 문맥의 세대 번호.
        public let generation: Int
        /// 해당 세대가 읽은 입력 지문.
        public let fingerprint: String
        /// 심볼 그래프의 정점 수.
        public let nodeCount: Int
        /// 심볼 그래프에서 관찰된 소스 파일 수.
        public let fileCount: Int
        /// 이 문맥의 분석 한계.
        public let limitations: [String]

        /// 메타데이터를 만든다.
        public init(
            generation: Int,
            fingerprint: String,
            nodeCount: Int,
            fileCount: Int,
            limitations: [String]
        ) {
            self.generation = generation
            self.fingerprint = fingerprint
            self.nodeCount = nodeCount
            self.fileCount = fileCount
            self.limitations = limitations
        }
    }

    private static let maximumRefreshAttempts = 3

    private let serviceFactory: ServiceFactory
    private let inputFingerprintProvider: InputFingerprintProvider
    /// 입력 지문을 다시 읽기 전에 준비된 세대를 그대로 쓸 시간 창.
    /// `.zero` 이면 요청마다 지문을 다시 읽는다.
    private let freshnessCheckInterval: Duration
    /// 시각 소스. 창 의미론 검증이 실제 수면 없이 시간을 진행할 수 있게 주입한다.
    private let now: () -> ContinuousClock.Instant
    private var service: CartographService?
    private var context: AnalysisContext?
    private var querySession: CartographService.QuerySession?
    private var preparedFingerprint: String?
    /// 마지막으로 입력 지문을 검증한 시각. 창이 `.zero` 일 때는 쓰지 않는다.
    private var lastFingerprintCheck: ContinuousClock.Instant?
    private var generation = 0

    /// 마지막으로 성공한 세대의 메타데이터. 새로고침에 실패하면 nil 이 된다.
    public private(set) var metadata: Metadata?
    /// 추가 모델 검증을 기본 인덱스 세대의 규모로 오해하지 않도록 분리한다.
    public struct RuntimeBuildEvidenceMetadata: Codable, Sendable, Equatable {
        public let status: String
        public let supplementalSources: Int
    }
    public private(set) var runtimeBuildEvidenceMetadata: RuntimeBuildEvidenceMetadata?

    /// 주입된 서비스 공장과 입력 지문으로 세션을 만든다.
    ///
    /// 초기화 시 문맥을 준비하므로 반환된 세션은 즉시 메타데이터를 제공한다.
    /// 질의 색인과 도달성 보고서는 첫 `query` 때까지 만들지 않는다.
    ///
    /// `freshnessCheckInterval`은 요청마다 입력 지문을 다시 읽기 전에 마지막 검증
    /// 세대를 믿는 시간이다. 지문 계산은 소스·인덱스 파일 전부를 다시 stat 하므로
    /// 프로젝트에 비례해 커지고, MCP 서버처럼 호출이 연속으로 오는 소비자는 짧은
    /// 창으로 그 비용을 한 번으로 묶을 수 있다. 창은 신선도 확인을 미루는 상한이며
    /// 기본값 `.zero`는 지금까지와 같은 요청마다 검증이다. 음수도 `.zero`와 같이
    /// 매 요청 검증한다. `now`는 창의 시각 소스로, 호출마다 새 ContinuousClock 을
    /// 만들어도 같은 단조 시간대를 읽는다.
    public init(
        serviceFactory: @escaping ServiceFactory,
        inputFingerprintProvider: @escaping InputFingerprintProvider,
        freshnessCheckInterval: Duration = .zero,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) throws {
        self.serviceFactory = serviceFactory
        self.inputFingerprintProvider = inputFingerprintProvider
        self.freshnessCheckInterval = freshnessCheckInterval
        self.now = now
        try refresh()
    }

    /// 고정된 서비스의 안전한 입력 지문을 사용하는 세션을 만든다.
    ///
    /// 설정을 다시 읽어야 한다면 serviceFactory 초기화를 사용한다.
    public convenience init(
        service: CartographService,
        freshnessCheckInterval: Duration = .zero
    ) throws {
        let cache = AnalysisInputFingerprintCache()
        try self.init(
            serviceFactory: { service },
            inputFingerprintProvider: { try service.sessionInputFingerprint(using: cache) },
            freshnessCheckInterval: freshnessCheckInterval
        )
    }

    /// 서비스를 새로 만들 수 있는 공장으로 세션을 만든다.
    ///
    /// 지문을 계산할 때도 공장에서 서비스를 하나 받아 현재 설정을 읽는다.
    /// 따라서 호출자가 설정 파일을 다시 읽는 공장을 주입하면 입력 변경 뒤
    /// 다음 요청에서 새 설정이 적용된다.
    public convenience init(
        serviceFactory: @escaping ServiceFactory,
        freshnessCheckInterval: Duration = .zero
    ) throws {
        let cache = AnalysisInputFingerprintCache()
        try self.init(
            serviceFactory: serviceFactory,
            inputFingerprintProvider: {
                let service = try serviceFactory()
                return try service.sessionInputFingerprint(using: cache)
            },
            freshnessCheckInterval: freshnessCheckInterval
        )
    }

    /// 현재 입력을 다시 읽어 새 문맥 세대를 만든다.
    ///
    /// 같은 지문이어도 명시적으로 호출하면 인덱스와 소스 보강을 다시 읽는다.
    /// 읽기 전후 지문이 다르면 최대 세 번 안정화를 시도하며, 끝내 안정되지
    /// 않으면 부분 결과를 캐시하지 않고 오류를 던진다.
    @discardableResult
    public func refresh() throws -> Metadata {
        invalidate()
        return try reload()
    }

    /// 현재 입력 세대의 메타데이터를 확인한다.
    ///
    /// 먼저 지문을 다시 읽어 입력이 바뀌었으면 새 문맥을 준비한다. 준비에
    /// 실패하면 이전 메타데이터를 반환하지 않고 오류를 던진다.
    public func status() throws -> Metadata {
        runtimeBuildEvidenceMetadata = nil
        try ensurePrepared()
        guard let metadata else { throw AnalysisSessionError.unavailable }
        return metadata
    }

    /// 여러 심볼을 하나의 준비된 문맥에서 질의한다.
    ///
    /// 요청 순서와 중복은 `SymbolQueryBatchDocument` 계약을 따라 보존한다.
    public func query(
        symbols: [String], depth: Int = 1, limit: Int = 50, evidenceBudget: QueryEvidenceBudget? = nil
    ) throws
        -> SymbolQueryBatchDocument {
        runtimeBuildEvidenceMetadata = nil
        try ensurePrepared()
        guard let service, let context else { throw AnalysisSessionError.unavailable }
        if querySession == nil {
            querySession = try service.makeQuerySession(in: context)
        }
        guard let querySession else { throw AnalysisSessionError.unavailable }
        var remaining = evidenceBudget
        let results = try symbols.map { symbol in
            let document = try service.queryDocument(symbol: symbol, depth: depth, limit: limit, in: querySession)
            guard var budget = remaining else { return document }
            let limited = budget.apply(to: document)
            remaining = budget
            return limited
        }
        return SymbolQueryBatchDocument(results: results)
    }

    /// 준비된 문맥에서 변경 영향 문서를 만든다.
    ///
    /// 기본 인덱스는 재사용한다. 명시한 Core Data 산출물은 별도 검증하여
    /// 생성 소스의 변경을 기본 세션 캐시로 가리지 않는다.
    public func impact(
        symbols: [String] = [],
        files: [String] = [],
        maxDepth: Int? = nil,
        limit: Int = 200,
        runtimeContracts: RuntimeContractsDocument? = nil,
        coreDataBuildEvidencePath: String? = nil
    ) throws -> ImpactDocument {
        try ensurePrepared()
        guard let service, let context else { throw AnalysisSessionError.unavailable }
        let runtimeContext = try runtimeContext(
            service: service, base: context, coreDataBuildEvidencePath: coreDataBuildEvidencePath
        )
        return try service.impactDocument(
            symbols: symbols,
            files: files,
            maxDepth: maxDepth,
            limit: limit,
            runtimeContracts: runtimeContracts,
            in: runtimeContext
        )
    }

    /// 준비된 문맥에서 자동으로 발견한 런타임 경계와 미해결 항목을 반환한다.
    ///
    /// 같은 문맥의 구문·리소스 사실을 사용하므로 query나 impact 뒤에 호출해도
    /// 인덱스를 다시 읽거나 서로 다른 세대의 근거를 섞지 않는다.
    public func runtimeDiscovery(limit: Int = 200, coreDataBuildEvidencePath: String? = nil) throws
        -> RuntimeDiscoveryDocument {
        try ensurePrepared()
        guard let service, let context else { throw AnalysisSessionError.unavailable }
        let runtimeContext = try runtimeContext(
            service: service, base: context, coreDataBuildEvidencePath: coreDataBuildEvidencePath
        )
        return try service.runtimeDiscoveryDocument(limit: limit, in: runtimeContext)
    }

    /// 서버가 선택한 근거만 매번 재검증하며 query용 문맥과 캐시는 바꾸지 않는다.
    private func runtimeContext(
        service: CartographService, base: AnalysisContext, coreDataBuildEvidencePath: String?
    ) throws -> AnalysisContext {
        runtimeBuildEvidenceMetadata = nil
        guard let requested = coreDataBuildEvidencePath else { return base }
        let path = try validatedBuildEvidencePath(requested, service: service)
        let augmented = try service.coreDataRuntimeContext(evidencePath: path, in: base)
        guard try inputFingerprintProvider() == preparedFingerprint else {
            invalidate()
            throw AnalysisSessionError.inputChangedDuringRefresh(attempts: 1)
        }
        runtimeBuildEvidenceMetadata = .init(status: "verifiedCurrent",
            supplementalSources: augmented.supplementalRuntimeSourcePaths.count)
        return augmented
    }

    private func validatedBuildEvidencePath(_ requested: String, service: CartographService) throws -> String {
        let root = URL(fileURLWithPath: service.projectPath).standardizedFileURL.path
        let raw = requested.hasPrefix("/") ? requested : (root as NSString).appendingPathComponent(requested)
        let absolute = URL(fileURLWithPath: raw).standardizedFileURL.path
        guard !AnalysisInputFingerprinter.isSensitive(absolute) else { throw AnalysisSessionError.sensitiveInput }
        let fileSystem = service.environment.fileSystem
        let canonicalRoot = fileSystem.canonicalPath(root)
        let canonical = fileSystem.canonicalPath(absolute)
        guard !AnalysisInputFingerprinter.isSensitive(canonical) else { throw AnalysisSessionError.sensitiveInput }
        let prefix = canonicalRoot == "/" ? "/" : canonicalRoot + "/"
        guard canonical != canonicalRoot, canonical.hasPrefix(prefix),
              URL(fileURLWithPath: canonical).pathExtension.lowercased() == "json" else {
            throw CartographError.invalidConfiguration(path: root,
                reason: "MCP Core Data build evidence must be a JSON file inside the configured project.")
        }
        return canonical
    }

    /// 준비된 문맥에서 CI의 네 가지 점검을 함께 실행한다.
    ///
    /// query·impact와 같은 세대의 문맥을 사용하므로 한 세션 안에서
    /// 서로 다른 인덱스를 섞어 판단하지 않는다.
    public func check() throws -> CheckDocument {
        runtimeBuildEvidenceMetadata = nil
        try ensurePrepared()
        guard let service, let context else { throw AnalysisSessionError.unavailable }
        return try service.checkDocument(in: context)
    }

    // MARK: - 문맥 수명

    private func ensurePrepared() throws {
        // 마지막 검증 직후의 연속 요청은 입력을 다시 읽지 않는다. 지문 계산은 입력
        // 수에 비례해 요청마다 수백 파일을 다시 stat 하므로, 창 안에서는 이 비용이
        // 질의 자체보다 커진다. 검증을 미루는 시간은 창으로 상한이 정해져 있다.
        if freshnessCheckInterval > .zero, service != nil, context != nil,
           let lastFingerprintCheck,
           lastFingerprintCheck.duration(to: now()) < freshnessCheckInterval {
            return
        }
        do {
            // 관측 시작 시각을 쓰면 관측 자체의 소요도 창에 포함돼 문서화된
            // 상한이 지켜진다. 일치가 확인된 경우에만 찍는다 — 불일치 분기는
            // reload 성공 시의 검증 시각에 맡기고, 실패는 폐기로 이어진다.
            let checkedAt = now()
            let observed = try inputFingerprintProvider()
            guard preparedFingerprint == observed, service != nil, context != nil else {
                _ = try reload(expectedFingerprint: observed)
                return
            }
            lastFingerprintCheck = checkedAt
        } catch {
            // 입력 상태를 읽는 것 자체가 실패하면 이전 문맥도 현재 상태를
            // 대표하지 못한다. 오래된 결과를 재사용할 수 없게 즉시 폐기한다.
            invalidate()
            throw error
        }
    }

    private func reload(expectedFingerprint: String? = nil) throws -> Metadata {
        invalidate()
        var expected = try expectedFingerprint ?? inputFingerprintProvider()

        for _ in 1...Self.maximumRefreshAttempts {
            let candidateService = try serviceFactory()
            let candidateContext = try candidateService.loadContext()
            // 관측 시작 시각을 찍는다 — 관측 자체의 소요도 창에 포함시켜
            // 유보가 정확히 창으로 상한을 갖게 한다.
            let checkedAt = now()
            let observed = try inputFingerprintProvider()
            guard observed == expected else {
                expected = observed
                continue
            }

            let candidateMetadata = metadata(
                for: candidateService,
                context: candidateContext,
                fingerprint: observed,
                generation: generation + 1
            )
            service = candidateService
            context = candidateContext
            querySession = nil
            preparedFingerprint = observed
            lastFingerprintCheck = checkedAt
            generation = candidateMetadata.generation
            metadata = candidateMetadata
            return candidateMetadata
        }

        invalidate()
        throw AnalysisSessionError.inputChangedDuringRefresh(attempts: Self.maximumRefreshAttempts)
    }

    private func invalidate() {
        runtimeBuildEvidenceMetadata = nil
        service = nil
        context = nil
        querySession = nil
        preparedFingerprint = nil
        lastFingerprintCheck = nil
        metadata = nil
    }

    private func metadata(
        for service: CartographService,
        context: AnalysisContext,
        fingerprint: String,
        generation: Int
    ) -> Metadata {
        let graph = context.buildGraph(level: .symbol).graph
        let files = Set(graph.sortedNodes.compactMap { $0.location?.path })
        return Metadata(
            generation: generation,
            fingerprint: fingerprint,
            nodeCount: graph.nodeCount,
            fileCount: files.count,
            limitations: service.analysisLimitations(context: context, symbolGraph: graph)
        )
    }
}

extension CartographService {
    /// 현재 서비스가 읽을 수 있는 분석 입력의 내용 지문.
    ///
    /// 세션이 파일 수정 시각만 믿고 이전 문맥을 재사용하지 않도록, 알려진 소스·설정·
    /// 근거 파일과 인덱스 unit의 내용을 해시한다. 비밀 파일은 입력 목록에 넣지 않는다.
    func sessionInputFingerprint() throws -> String {
        try AnalysisInputFingerprinter(
            configuration: configuration,
            environment: environment,
            reportScope: reportScope,
            projectPath: projectPath
        ).make()
    }

    fileprivate func sessionInputFingerprint(using cache: AnalysisInputFingerprintCache) throws -> String {
        var environment = environment
        environment.fileSystem = CachedListingFileSystem(base: environment.fileSystem, cache: cache)
        return try AnalysisInputFingerprinter(
            configuration: configuration,
            environment: environment,
            reportScope: reportScope,
            projectPath: projectPath
        ).make(cache: cache)
    }
}

/// 세션이 순서대로 재사용하는 변경 감지 상태.
///
/// 오늘의 호출 경로는 전부 직렬이지만(CLI·MCP 루프) `Sendable` 경계를 넘는
/// 타입이 암묵 계약에 기대면 나중에 들어온 병렬 호출이 조용한 데이터 레이스가
/// 된다. 상태는 전부 락 아래에 둔다.
fileprivate final class AnalysisInputFingerprintCache: @unchecked Sendable {
    fileprivate struct Key: Hashable {
        let label: String
        let path: String
        /// 수정 시각이 기여 바이트에 들어가는 입력인지. 같은 경로라도 시각 포함
        /// 여부가 다르면 다른 항목이므로 키의 일부다.
        let stampsModificationDate: Bool
    }

    fileprivate struct Entry {
        let stamp: FileFingerprintStamp?
        /// 이 입력이 지문에 기여하는 프레임된 바이트열. 스탬프가 그대로면 이전에
        /// 검증·부호화해 둔 결과이므로 그대로 재생해도 같은 지문이 나온다.
        let encoded: Data
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    /// 소스 탐색의 `isIncluded` 판정 메모. 판정은 경로와 필터만의 순수 함수이므로
    /// 지문 계산마다 되풀이할 필요가 없다 — 실측에서 요청당 수백 번의 글롭 대조가
    /// 지문 비용의 큰 부분이었다. 사라진 경로의 판정은 다시 조회되지 않아 무해하므로
    /// 항목 수는 세션 동안 본 경로 수로 한정된다 — 가지치기 대상이 아니다.
    private var inclusions: [String: Bool] = [:]
    private var inclusionFilter: PathFilter?

    /// 지문 한 번에 관측한 디렉터리. 가지치기 기준이며 다음 지문 시작 때 비운다.
    private var observedDirectories: Set<String> = []
    private var directories: [String: DirectoryRecord] = [:]

    /// 탐색 루트별 이전 결과와 그때 열거한 디렉터리의 지문.
    ///
    /// 디렉터리 지문(mtime·ctime·inode)은 항목 추가·삭제·이름 변경에 반응하므로,
    /// 열거했던 디렉터리 전부의 지문이 그대로면 탐색 결과 목록도 그대로다.
    /// 하나라도 다르거나 지문을 얻지 못하면 전체를 다시 걷는다.
    private var walks: [String: WalkRecord] = [:]

    fileprivate func entry(for key: Key) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    fileprivate func store(encoded: Data, stamp: FileFingerprintStamp?, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        entries[key] = Entry(stamp: stamp, encoded: encoded)
    }

    /// 탐색 시작 전에 호출한다. 필터가 바뀌면 판정 메모가 다른 규칙의 결과이므로 비운다.
    fileprivate func prepareInclusion(filter: PathFilter) {
        lock.lock()
        defer { lock.unlock() }
        if inclusionFilter != filter {
            inclusionFilter = filter
            inclusions.removeAll()
        }
    }

    /// 저장된 포함 판정을 돌려준다.
    fileprivate func inclusion(for path: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return inclusions[path]
    }

    fileprivate func storeInclusion(_ included: Bool, for path: String) {
        lock.lock()
        defer { lock.unlock() }
        // 오래 사는 세션에서 삭제된 경로의 판정이 무한히 쌓이지 않게 상한을 둔다.
        // 메모는 비용 절약일 뿐이므로 넘치면 통째로 비워도 정답은 같다.
        if inclusions.count >= 65_536 { inclusions.removeAll() }
        inclusions[path] = included
    }

    /// 운영체제 지문이 그대로인 디렉터리의 이전 목록. 지문이 다르거나 없으면 nil.
    fileprivate func cachedEntries(at path: String, stamp: DirectoryListingStamp) -> [DirectoryEntry]? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = directories[path], record.stamp == stamp else { return nil }
        return record.entries
    }

    /// 열거 시도 전에 디렉터리 지문만 먼저 기록한다.
    ///
    /// 열거가 실패하는 디렉터리(읽기 권한 없음 등)도 지문을 남겨 두어야 탐색
    /// 캐시가 그 변화를 감시할 수 있다 — 권한 회복이나 교체는 지문을 바꾼다.
    /// 항목이 없는 기록은 `cachedEntries` 가 적중시키지 않으므로 매번 열거를
    /// 다시 시도한다.
    fileprivate func storeListingStamp(_ stamp: DirectoryListingStamp, at path: String) {
        lock.lock()
        defer { lock.unlock() }
        directories[path] = DirectoryRecord(stamp: stamp, entries: nil)
    }

    fileprivate func storeEntries(_ entries: [DirectoryEntry], stamp: DirectoryListingStamp, at path: String) {
        lock.lock()
        defer { lock.unlock() }
        directories[path] = DirectoryRecord(stamp: stamp, entries: entries)
    }

    fileprivate func observeDirectory(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        observedDirectories.insert(path)
    }

    /// 이전 탐색의 결과 목록. 기억된 디렉터리 전부의 지문이 그대로이고, 버려진
    /// 링크 파일의 지문도 그대로이며, 같은 필터로 만든 결과일 때만 돌려준다.
    fileprivate func walkedResult(root: String, filter: PathFilter?, fileSystem: any FileSystem) -> [String]? {
        lock.lock()
        let record = walks[root]
        lock.unlock()
        guard let record, record.filter == filter else { return nil }
        // 지문 확인은 락 밖에서 한다 — 파일 시스템 호출이 락을 다시 타지 않게.
        for (directory, stamp) in record.dirStamps {
            guard fileSystem.directoryListingStamp(at: directory) == stamp else { return nil }
        }
        // 같은 파일을 가리켜 버려진 링크는 부모 디렉터리 지문에 드러나지 않는다 —
        // 다른 파일을 가리키게 재지정되면 결과 목록이 달라지므로 따로 검증한다.
        for (link, stamp) in record.linkStamps {
            guard fileSystem.fingerprintStamp(at: link) == stamp else { return nil }
        }
        // 재사용한 디렉터리도 이번 지문에서 관측된 것으로 표시해 목록 레코드가
        // 가지치기되지 않게 한다.
        lock.lock()
        for (directory, _) in record.dirStamps {
            observedDirectories.insert(directory)
        }
        lock.unlock()
        return record.result
    }

    /// 탐색 결과를 루트와 필터에 묶어 둔다. 열거한 디렉터리 중 지문이 없거나
    /// 열거에 실패한 것이 있으면 검증할 수 없으므로 — 실패는 다음 지문에서 다시
    /// 시도돼야 하므로 — 저장하지 않는다. 버려진 링크 파일의 지문도 함께 남긴다.
    fileprivate func storeWalk(
        root: String, filter: PathFilter?, directories walked: [String],
        discardedLinks: [String], result: [String], fileSystem: any FileSystem
    ) {
        guard let resolvedRoot = walked.first else { return }
        lock.lock()
        var records: [(String, DirectoryRecord)] = []
        for directory in walked {
            guard let record = directories[directory] else { lock.unlock(); return }
            records.append((directory, record))
        }
        lock.unlock()
        // 파일 시스템 호출은 락 밖에서 한다 — walkedResult 와 같은 이유다.
        var dirStamps: [(String, DirectoryListingStamp)] = []
        dirStamps.reserveCapacity(records.count + 1)
        for (directory, record) in records {
            guard record.entries != nil else { return }
            dirStamps.append((directory, record.stamp))
        }
        var linkStamps: [(String, FileFingerprintStamp)] = []
        for link in discardedLinks {
            guard let stamp = fileSystem.fingerprintStamp(at: link) else { return }
            linkStamps.append((link, stamp))
        }
        // 루트가 링크면 열거는 풀린 철자로 남고 재지정은 그 철자들의 지문에 드러나지
        // 않는다. stat 은 링크를 따라가므로 부른 철자의 지문도 함께 기록한다.
        if resolvedRoot != root, let rootStamp = dirStamps.first?.1 {
            dirStamps.append((root, rootStamp))
        }
        lock.lock()
        walks[root] = WalkRecord(filter: filter, dirStamps: dirStamps, linkStamps: linkStamps, result: result)
        lock.unlock()
    }

    fileprivate func resetObservations() {
        lock.lock()
        defer { lock.unlock() }
        observedDirectories.removeAll()
    }

    fileprivate func prune(keeping keys: Set<Key>) {
        lock.lock()
        defer { lock.unlock() }
        // 가지치기는 메모리 위생일 뿐 판정에 영향이 없다. 보낼 항목이 없으면 건너뛴다.
        guard entries.count > keys.count || directories.count > observedDirectories.count
        else { return }
        entries = entries.filter { keys.contains($0.key) }
        directories = directories.filter { observedDirectories.contains($0.key) }
    }

    private struct DirectoryRecord {
        let stamp: DirectoryListingStamp
        /// nil 은 열거에 실패한 디렉터리 — 지문만 감시하고 매번 다시 열거를 시도한다.
        let entries: [DirectoryEntry]?
    }

    private struct WalkRecord {
        /// 결과를 만든 경로 필터. 필터가 바뀌면 같은 디렉터리들이라도 목록이
        /// 달라지므로 탐색 결과를 재사용할 수 없다.
        let filter: PathFilter?
        let dirStamps: [(String, DirectoryListingStamp)]
        /// 같은 파일을 가리켜 버려진 심볼릭 링크의 지문. 부모 디렉터리 지문에는
        /// 재지정이 드러나지 않으므로 따로 검증한다.
        let linkStamps: [(String, FileFingerprintStamp)]
        let result: [String]
    }
}

/// 디렉터리 목록을 운영체제 지문으로 검증해 재열거를 건너뛰는 파일 시스템 래퍼.
///
/// 디렉터리의 지문(mtime·ctime·inode·mode)이 그대로이면 항목 구성이 바뀌지
/// 않은 것으로 본다. 파일 내용 변경은 파일별 지문이 따로 잡으므로 이 목록은 구조
/// 변화만 감시하면 된다. 지문을 제공하지 않는 구현은 매번 열거한다.
fileprivate struct CachedListingFileSystem: FileSystem {
    let base: any FileSystem
    let cache: AnalysisInputFingerprintCache

    func directoryEntries(at path: String) throws -> [DirectoryEntry] {
        cache.observeDirectory(path)
        guard let stamp = base.directoryListingStamp(at: path) else {
            return try base.directoryEntries(at: path)
        }
        if let cached = cache.cachedEntries(at: path, stamp: stamp) {
            return cached
        }
        // 열거에 실패해도 지문은 남겨 둔다 — 권한 회복처럼 열거 결과를 바꾸는
        // 변화가 다음 지문에서 탐지되어야 한다.
        cache.storeListingStamp(stamp, at: path)
        let entries = try base.directoryEntries(at: path)
        cache.storeEntries(entries, stamp: stamp, at: path)
        return entries
    }

    func realPath(at path: String) throws -> String { try base.realPath(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func readData(at path: String) throws -> Data { try base.readData(at: path) }
    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    func contentsOfDirectory(at path: String) throws -> [String] {
        try base.contentsOfDirectory(at: path)
    }
    func modificationDate(at path: String) -> Date? { base.modificationDate(at: path) }
    func fingerprintStamp(at path: String) -> FileFingerprintStamp? {
        base.fingerprintStamp(at: path)
    }
    func directoryListingStamp(at path: String) -> DirectoryListingStamp? {
        base.directoryListingStamp(at: path)
    }
    var currentDirectoryPath: String { base.currentDirectoryPath }
}

private struct AnalysisInputFingerprinter {
    let configuration: CartographConfiguration
    let environment: CartographEnvironment
    let reportScope: ReportScope?
    let projectPath: String

    func make(cache: AnalysisInputFingerprintCache? = nil) throws -> String {
        var accumulator = FingerprintAccumulator()
        accumulator.addText(cache == nil ? "cartograph-analysis-input-v2" : "cartograph-analysis-input-v3")
        var observedKeys: Set<AnalysisInputFingerprintCache.Key> = []
        cache?.resetObservations()
        let encodedConfiguration = try JSONEncoder.cartographDefault(prettyPrinted: false)
            .encode(configuration)
        accumulator.addData(label: "configuration", data: encodedConfiguration)
        if let scope = reportScope {
            accumulator.addText("report-scope")
            for path in scope.files.sorted() {
                accumulator.addText(path)
            }
        } else {
            accumulator.addText("report-scope:none")
        }

        try addConfigurationFiles(to: &accumulator, cache: cache, observedKeys: &observedKeys)
        try addSourceFiles(to: &accumulator, cache: cache, observedKeys: &observedKeys)
        try addOptionalConfigurationInputs(to: &accumulator, cache: cache, observedKeys: &observedKeys)
        try addIndexUnits(to: &accumulator, cache: cache, observedKeys: &observedKeys)
        try addToolchain(to: &accumulator, cache: cache, observedKeys: &observedKeys)
        if let cache { cache.prune(keeping: observedKeys) }
        return accumulator.finalize()
    }

    private func addConfigurationFiles(
        to accumulator: inout FingerprintAccumulator,
        cache: AnalysisInputFingerprintCache?,
        observedKeys: inout Set<AnalysisInputFingerprintCache.Key>
    ) throws {
        for name in [Cartograph.defaultConfigurationFileName, ".cartograph.yaml"] {
            let path = (projectPath as NSString).appendingPathComponent(name)
            try addFile(
                path, label: "configuration-file", cache: cache, observedKeys: &observedKeys, to: &accumulator
            )
        }
    }

    private func addSourceFiles(
        to accumulator: inout FingerprintAccumulator,
        cache: AnalysisInputFingerprintCache?,
        observedKeys: inout Set<AnalysisInputFingerprintCache.Key>
    ) throws {
        let fileSystem = environment.fileSystem
        cache?.prepareInclusion(filter: configuration.pathFilter)
        // 탐색 결과를 열거 디렉터리 전체의 지문으로 묶어 둔다 — 구조가 그대로면
        // 다음 지문에서 글롭 대조·디렉터리 열거 없이 경로 목록을 재사용한다.
        let paths: [String]
        if let cached = cache?.walkedResult(
            root: projectPath, filter: configuration.pathFilter, fileSystem: fileSystem
        ) {
            paths = cached
        } else {
            var walked: [String] = []
            var discardedLinks: [String] = []
            paths = fileSystem.recursiveFiles(
                under: projectPath,
                isIncluded: { path in
                    if let cached = cache?.inclusion(for: path) { return cached }
                    let included = Self.isSourceInput(path, filter: configuration.pathFilter)
                    cache?.storeInclusion(included, for: path)
                    return included
                },
                shouldDescend: BuildArtifactDirectories.shouldDescend(into:),
                onDirectory: { walked.append($0) },
                onDiscardedLink: { discardedLinks.append($0) }
            )
            cache?.storeWalk(
                root: projectPath, filter: configuration.pathFilter,
                directories: walked, discardedLinks: discardedLinks, result: paths,
                fileSystem: fileSystem
            )
        }
        accumulator.addText("source-count:\(paths.count)")
        for path in paths {
            // 내용이 같아도 소스 시각은 인덱스 신선도 결과에 영향을 준다.
            try addFile(path, label: "source-file", includeModificationDate: true,
                cache: cache, observedKeys: &observedKeys, to: &accumulator)
        }
    }

    /// 세션 입력에 들어가는 소스·리소스 경로 판정.
    ///
    /// 글롭 대조와 리소스 판정(URL 생성)은 항목당 비싸므로 이름으로 먼저 좁힌다.
    /// 소스 접미사는 대소문자 구분 그대로, 리소스는 이름 게이트 뒤에 원래의 정밀
    /// 판정을 부른다 — `xcdatamodel` 밖의 일반 `contents` 는 계속 빠져야 한다.
    private static func isSourceInput(_ path: String, filter: PathFilter) -> Bool {
        let name = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension
        if ext == "swift" || ext == "m" || ext == "mm"
            || name == ".swift" || name == ".m" || name == ".mm" {
            return filter.allows(path)
        }
        let lowerName = name.lowercased()
        let resourceCandidate = ext.lowercased() == "xib"
            || ext.lowercased() == "storyboard"
            || lowerName == ".xib" || lowerName == ".storyboard"
            || lowerName == "contents" || name == ".xccurrentversion"
        return resourceCandidate
            && RuntimeResourcePath.isSupported(path)
            && filter.allows(path)
    }

    private func addOptionalConfigurationInputs(
        to accumulator: inout FingerprintAccumulator,
        cache: AnalysisInputFingerprintCache?,
        observedKeys: inout Set<AnalysisInputFingerprintCache.Key>
    ) throws {
        let baseline = configuration.baselinePath ?? Cartograph.defaultBaselineFileName
        try addFile(
            resolvedPath(baseline), label: "baseline", cache: cache, observedKeys: &observedKeys, to: &accumulator
        )
        if let external = configuration.externalRetentionsPath {
            try addFile(
                resolvedPath(external), label: "external-retentions", cache: cache,
                observedKeys: &observedKeys, to: &accumulator
            )
        } else {
            accumulator.addText("external-retentions:none")
        }
    }

    private func addIndexUnits(
        to accumulator: inout FingerprintAccumulator,
        cache: AnalysisInputFingerprintCache?,
        observedKeys: inout Set<AnalysisInputFingerprintCache.Key>
    ) throws {
        let stores = indexStorePaths()
        guard !stores.isEmpty else {
            accumulator.addText("index-store:none")
            return
        }
        let fileSystem = environment.fileSystem
        for store in stores.sorted() {
            for suffix in ["/v5/units", "/units"] {
                let root = store + suffix
                accumulator.addText("index-unit-root:\(root):\(fileSystem.directoryExists(at: root))")
                if let modified = fileSystem.modificationDate(at: root) {
                    accumulator.addText("index-unit-root-modified:\(modified.timeIntervalSinceReferenceDate)")
                } else {
                    accumulator.addText("index-unit-root-modified:unknown")
                }
                let paths: [String]
                if let cached = cache?.walkedResult(root: root, filter: nil, fileSystem: fileSystem) {
                    paths = cached
                } else {
                    var walked: [String] = []
                    var discardedLinks: [String] = []
                    paths = fileSystem.recursiveFiles(
                        under: root,
                        isIncluded: { _ in true },
                        shouldDescend: { _ in true },
                        onDirectory: { walked.append($0) },
                        onDiscardedLink: { discardedLinks.append($0) }
                    )
                    cache?.storeWalk(
                        root: root, filter: nil, directories: walked,
                        discardedLinks: discardedLinks, result: paths, fileSystem: fileSystem
                    )
                }
                accumulator.addText("index-unit-count:\(paths.count)")
                for path in paths {
                    try addFile(
                        path, label: "index-unit", includeModificationDate: true, cache: cache,
                        observedKeys: &observedKeys, to: &accumulator
                    )
                }
            }
        }
    }

    private func addToolchain(
        to accumulator: inout FingerprintAccumulator,
        cache: AnalysisInputFingerprintCache?,
        observedKeys: inout Set<AnalysisInputFingerprintCache.Key>
    ) throws {
        guard environment.indexProviderOverride == nil else {
            accumulator.addText("index-library:injected-provider")
            return
        }
        let locator = IndexStoreLocator(fileSystem: environment.fileSystem)
        guard let library = try? locator.locateLibrary(
            explicitPath: nil,
            developerDirectory: environment.developerDirectory
        ) else {
            accumulator.addText("index-library:unavailable")
            return
        }
        try addFile(library, label: "index-library", includeModificationDate: true,
            cache: cache, observedKeys: &observedKeys, to: &accumulator)
    }

    private func indexStorePaths() -> [String] {
        if let explicit = configuration.indexStorePath { return [explicit] }
        guard environment.indexProviderOverride == nil else { return [] }
        let locator = IndexStoreLocator(fileSystem: environment.fileSystem)
        return (try? locator.locate(
            explicitPath: nil,
            projectPath: projectPath,
            derivedDataPath: configuration.derivedDataPath ?? environment.derivedDataPath
        )).map { [$0] } ?? []
    }

    private func resolvedPath(_ path: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        return (projectPath as NSString).appendingPathComponent(path)
    }

    private func addFile(
        _ path: String,
        label: String,
        includeModificationDate: Bool = false,
        cache: AnalysisInputFingerprintCache?,
        observedKeys: inout Set<AnalysisInputFingerprintCache.Key>,
        to accumulator: inout FingerprintAccumulator
    ) throws {
        let cacheKey = AnalysisInputFingerprintCache.Key(
            label: label, path: path, stampsModificationDate: includeModificationDate
        )
        observedKeys.insert(cacheKey)
        let fileSystem = environment.fileSystem
        // 파일마다 한 번의 stat 으로 실제 경로·수정 시각·캐시 비교 상태를 모두 얻는다.
        // 요청마다 수백 입력을 다시 검증하는 세션 지문에서 항목당 syscall 수가 지배적이다.
        let stamp = fileSystem.fingerprintStamp(at: path)
        // 스탬프가 그대로면 경로·해결 철자·내용·시각이 전부 같다. 저장 시 이미 민감
        // 이름 판정과 부호화를 마쳤으므로 히트 경로는 결과 바이트만 재생한다.
        if let cache, let stamp, let entry = cache.entry(for: cacheKey), entry.stamp == stamp {
            accumulator.appendEncoded(entry.encoded)
            return
        }
        var contribution = FingerprintContribution()
        contribution.addText("\(label):\(path)")
        let resolvedPath = stamp?.resolvedPath ?? (try? fileSystem.realPath(at: path)) ?? path
        guard !Self.isSensitive(path), !Self.isSensitive(resolvedPath) else {
            throw AnalysisSessionError.sensitiveInput
        }
        let missing = stamp.map { !$0.isRegularFile } ?? !fileSystem.fileExists(at: path)
        // 디렉터리·끊어진 링크·FIFO 같은 비정규 입력은 읽지 않는다. stamp 를 주지
        // 않는 구현은 예전처럼 존재 여부로만 판정한다.
        guard !missing else {
            contribution.addText("missing")
            accumulator.appendEncoded(contribution.data)
            cache?.store(encoded: contribution.data, stamp: nil, for: cacheKey)
            return
        }
        if includeModificationDate {
            // 내용이 같아도 소스 시각은 인덱스 신선도 결과에 영향을 주므로 별도로 싣는다.
            let modified = stamp.map {
                Date(timeIntervalSince1970:
                    Double($0.modificationSeconds) + Double($0.modificationNanoseconds) / 1e9)
            } ?? fileSystem.modificationDate(at: path)
            contribution.addText(
                modified.map { "modified:\($0.timeIntervalSinceReferenceDate)" } ?? "modified:unknown"
            )
        }
        guard let data = try? fileSystem.readData(at: path) else {
            contribution.addText("unreadable")
            accumulator.appendEncoded(contribution.data)
            cache?.store(encoded: contribution.data, stamp: stamp, for: cacheKey)
            return
        }
        if let cache {
            let digest = Data(SHA256.hash(data: data))
            contribution.addData(label: "content-digest", data: digest)
            accumulator.appendEncoded(contribution.data)
            cache.store(encoded: contribution.data, stamp: stamp, for: cacheKey)
        } else {
            contribution.addData(label: "content", data: data)
            accumulator.appendEncoded(contribution.data)
        }
    }

    fileprivate static func isSensitive(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let knownCredentialNames: Set<String> = [
            ".env", "auth.json", "auth.plist",
            "credentials.json", "credentials.plist", "secrets.json", "secrets.plist",
            "secrets.yml", "secrets.yaml",
        ]
        return knownCredentialNames.contains(name)
            || name.hasPrefix(".env.")
            || [".pem", ".key", ".p12", ".p8", ".mobileprovision"].contains {
                name.hasSuffix($0)
            }
    }
}

private struct FingerprintAccumulator {
    private var hasher = SHA256()

    mutating func addText(_ value: String) {
        addBytes(Data(value.utf8))
    }

    mutating func addData(label: String, data: Data) {
        addText(label)
        addBytes(data)
    }

    /// 이미 길이-접두사로 프레임된 기여 바이트를 그대로 해시에 넣는다.
    ///
    /// 캐시된 입력의 재생에 쓴다 — 프레임 형식은 `FingerprintContribution` 이 만든다.
    mutating func appendEncoded(_ data: Data) {
        hasher.update(data: data)
    }

    private mutating func addBytes(_ data: Data) {
        var length = UInt64(data.count).bigEndian
        let prefix = withUnsafeBytes(of: &length) { Data($0) }
        hasher.update(data: prefix)
        hasher.update(data: data)
    }

    mutating func finalize() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 지문 입력 하나가 기여하는 바이트열을 `FingerprintAccumulator` 와 같은
/// 길이-접두사 프레이밍으로 만든다.
///
/// 스탬프가 그대로인 입력은 요청마다 민감 이름 판정·문자열 부호화·내용 읽기를
/// 되풀이할 필요가 없다. 저장 시 한 번 만든 이 열을 히트 때 그대로 재생한다.
private struct FingerprintContribution {
    private(set) var data = Data()

    mutating func addText(_ value: String) {
        addBytes(Data(value.utf8))
    }

    mutating func addData(label: String, data: Data) {
        addText(label)
        addBytes(data)
    }

    private mutating func addBytes(_ bytes: Data) {
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}
