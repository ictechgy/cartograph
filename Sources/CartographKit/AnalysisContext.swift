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

    public init(
        snapshot: IndexSnapshot,
        pathFilter: PathFilter = .passthrough,
        edgeKinds: Set<EdgeKind> = [],
        externalRetentions: ExternalRetentionsDocument? = nil,
        missingSourcePaths: [String] = [],
        unreadableSourcePaths: [String] = [],
        runtimeFiles: [RuntimeFileFacts]? = nil,
        runtimeFreshness: [String: RuntimeFreshness] = [:],
        supplementalRuntimeSourcePaths: Set<String> = []
    ) {
        self.snapshot = snapshot
        self.missingSourcePaths = missingSourcePaths
        self.unreadableSourcePaths = unreadableSourcePaths
        self.runtimeFiles = runtimeFiles
        self.runtimeFreshness = runtimeFreshness
        self.supplementalRuntimeSourcePaths = supplementalRuntimeSourcePaths
        self.pathFilter = pathFilter
        self.edgeKinds = edgeKinds
        self.externalRetentions = externalRetentions
        externalRetentionIndex = externalRetentions.map { ExternalRetentionIndex($0.retentions) } ?? .empty
        graphCache = GraphBuildCache()
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

    /// 지정한 해상도의 그래프를 만든다. 같은 문맥·같은 해상도면 처음 만든 것을 돌려준다.
    public func buildGraph(level: GraphLevel, includeExternal: Bool = false) -> GraphBuilder.BuildResult {
        graphCache.result(for: .init(level: level, includeExternal: includeExternal)) {
            GraphBuilder(
                options: .init(
                    level: level,
                    pathFilter: pathFilter,
                    edgeKinds: edgeKinds,
                    includeExternal: includeExternal
                )
            )
            .buildResult(from: snapshot)
        }
    }
}

/// 이름 조회 결과의 기존 Kit API 이름을 유지한다.
public typealias NodeLookup = GraphNodeLookup
