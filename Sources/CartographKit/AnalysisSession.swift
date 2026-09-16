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
    private var service: CartographService?
    private var context: AnalysisContext?
    private var querySession: CartographService.QuerySession?
    private var preparedFingerprint: String?
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
    public init(
        serviceFactory: @escaping ServiceFactory,
        inputFingerprintProvider: @escaping InputFingerprintProvider
    ) throws {
        self.serviceFactory = serviceFactory
        self.inputFingerprintProvider = inputFingerprintProvider
        try refresh()
    }

    /// 고정된 서비스의 안전한 입력 지문을 사용하는 세션을 만든다.
    ///
    /// 설정을 다시 읽어야 한다면 serviceFactory 초기화를 사용한다.
    public convenience init(service: CartographService) throws {
        let cache = AnalysisInputFingerprintCache()
        try self.init(
            serviceFactory: { service },
            inputFingerprintProvider: { try service.sessionInputFingerprint(using: cache) }
        )
    }

    /// 서비스를 새로 만들 수 있는 공장으로 세션을 만든다.
    ///
    /// 지문을 계산할 때도 공장에서 서비스를 하나 받아 현재 설정을 읽는다.
    /// 따라서 호출자가 설정 파일을 다시 읽는 공장을 주입하면 입력 변경 뒤
    /// 다음 요청에서 새 설정이 적용된다.
    public convenience init(serviceFactory: @escaping ServiceFactory) throws {
        let cache = AnalysisInputFingerprintCache()
        try self.init(
            serviceFactory: serviceFactory,
            inputFingerprintProvider: {
                let service = try serviceFactory()
                return try service.sessionInputFingerprint(using: cache)
            }
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
        do {
            let observed = try inputFingerprintProvider()
            guard preparedFingerprint == observed, service != nil, context != nil else {
                _ = try reload(expectedFingerprint: observed)
                return
            }
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
    }

    fileprivate enum State {
        case missing
        case unreadable
        case digest(Data)
    }

    fileprivate struct Entry {
        let stamp: FileFingerprintStamp?
        let state: State
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    /// 지문 한 번에 관측한 디렉터리. 가지치기 기준이며 다음 지문 시작 때 비운다.
    private var observedDirectories: Set<String> = []
    private var directories: [String: DirectoryRecord] = [:]

    fileprivate func entry(for key: Key) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    fileprivate func store(_ state: State, stamp: FileFingerprintStamp?, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        entries[key] = Entry(stamp: stamp, state: state)
    }

    /// 운영체제 지문이 그대로인 디렉터리의 이전 목록. 지문이 다르거나 없으면 nil.
    fileprivate func cachedEntries(at path: String, stamp: DirectoryListingStamp) -> [DirectoryEntry]? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = directories[path], record.stamp == stamp else { return nil }
        return record.entries
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

    fileprivate func resetObservedDirectories() {
        lock.lock()
        defer { lock.unlock() }
        observedDirectories.removeAll()
    }

    fileprivate func prune(keeping keys: Set<Key>) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { keys.contains($0.key) }
        directories = directories.filter { observedDirectories.contains($0.key) }
    }

    private struct DirectoryRecord {
        let stamp: DirectoryListingStamp
        let entries: [DirectoryEntry]
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
        cache?.resetObservedDirectories()
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
        let paths = fileSystem.recursiveFiles(
            under: projectPath,
            isIncluded: { path in
                // 글롭 대조와 리소스 판정(URL 생성)은 항목당 비싸므로 이름으로 먼저
                // 좁힌다. 소스 접미사는 대소문자 구분 그대로, 리소스는 이름 게이트
                // 뒤에 원래의 정밀 판정을 부른다 — `xcdatamodel` 밖의 일반
                // `contents` 는 계속 빠져야 한다.
                let name = (path as NSString).lastPathComponent
                let ext = (path as NSString).pathExtension
                if ext == "swift" || ext == "m" || ext == "mm"
                    || name == ".swift" || name == ".m" || name == ".mm" {
                    return configuration.pathFilter.allows(path)
                }
                let lowerName = name.lowercased()
                let resourceCandidate = ext.lowercased() == "xib"
                    || ext.lowercased() == "storyboard"
                    || lowerName == ".xib" || lowerName == ".storyboard"
                    || lowerName == "contents" || name == ".xccurrentversion"
                return resourceCandidate
                    && RuntimeResourcePath.isSupported(path)
                    && configuration.pathFilter.allows(path)
            },
            shouldDescend: BuildArtifactDirectories.shouldDescend(into:)
        )
        accumulator.addText("source-count:\(paths.count)")
        for path in paths {
            // 내용이 같아도 소스 시각은 인덱스 신선도 결과에 영향을 준다.
            try addFile(path, label: "source-file", includeModificationDate: true,
                cache: cache, observedKeys: &observedKeys, to: &accumulator)
        }
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
                let paths = fileSystem.recursiveFiles(
                    under: root,
                    isIncluded: { _ in true },
                    shouldDescend: { _ in true }
                )
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
        accumulator.addText("\(label):\(path)")
        let cacheKey = AnalysisInputFingerprintCache.Key(label: label, path: path)
        observedKeys.insert(cacheKey)
        let fileSystem = environment.fileSystem
        // 파일마다 한 번의 stat 으로 실제 경로·수정 시각·캐시 비교 상태를 모두 얻는다.
        // 요청마다 수백 입력을 다시 검증하는 세션 지문에서 항목당 syscall 수가 지배적이다.
        let stamp = fileSystem.fingerprintStamp(at: path)
        let resolvedPath = stamp?.resolvedPath ?? (try? fileSystem.realPath(at: path)) ?? path
        guard !Self.isSensitive(path), !Self.isSensitive(resolvedPath) else {
            throw AnalysisSessionError.sensitiveInput
        }
        if let stamp {
            // 디렉터리·끊어진 링크·FIFO 같은 비정규 입력은 읽지 않는다.
            guard stamp.isRegularFile else {
                accumulator.addText("missing")
                cache?.store(.missing, stamp: nil, for: cacheKey)
                return
            }
        } else {
            // stamp를 주지 않는 구현은 예전처럼 존재 여부로만 판정한다.
            guard fileSystem.fileExists(at: path) else {
                accumulator.addText("missing")
                cache?.store(.missing, stamp: nil, for: cacheKey)
                return
            }
        }
        if includeModificationDate {
            // 내용이 같아도 소스 시각은 인덱스 신선도 결과에 영향을 주므로 별도로 싣는다.
            let modified = stamp.map {
                Date(timeIntervalSince1970:
                    Double($0.modificationSeconds) + Double($0.modificationNanoseconds) / 1e9)
            } ?? fileSystem.modificationDate(at: path)
            if let modified {
                accumulator.addText("modified:\(modified.timeIntervalSinceReferenceDate)")
            } else {
                accumulator.addText("modified:unknown")
            }
        }
        if let cache, let stamp, let entry = cache.entry(for: cacheKey), entry.stamp == stamp {
            append(entry.state, to: &accumulator)
            return
        }
        guard let data = try? fileSystem.readData(at: path) else {
            accumulator.addText("unreadable")
            cache?.store(.unreadable, stamp: stamp, for: cacheKey)
            return
        }
        if let cache {
            let digest = Data(SHA256.hash(data: data))
            cache.store(.digest(digest), stamp: stamp, for: cacheKey)
            accumulator.addData(label: "content-digest", data: digest)
        } else {
            accumulator.addData(label: "content", data: data)
        }
    }

    private func append(
        _ state: AnalysisInputFingerprintCache.State,
        to accumulator: inout FingerprintAccumulator
    ) {
        switch state {
        case .missing:
            accumulator.addText("missing")
        case .unreadable:
            accumulator.addText("unreadable")
        case let .digest(digest):
            accumulator.addData(label: "content-digest", data: digest)
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
