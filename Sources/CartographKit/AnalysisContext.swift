import CartographAnalysis
import CartographCore

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

    public init(
        snapshot: IndexSnapshot,
        pathFilter: PathFilter = .passthrough,
        edgeKinds: Set<EdgeKind> = [],
        externalRetentions: ExternalRetentionsDocument? = nil,
        missingSourcePaths: [String] = [],
        unreadableSourcePaths: [String] = []
    ) {
        self.snapshot = snapshot
        self.missingSourcePaths = missingSourcePaths
        self.unreadableSourcePaths = unreadableSourcePaths
        self.pathFilter = pathFilter
        self.edgeKinds = edgeKinds
        self.externalRetentions = externalRetentions
        externalRetentionIndex = externalRetentions.map { ExternalRetentionIndex($0.retentions) } ?? .empty
    }

    /// 지정한 해상도의 그래프를 만든다.
    public func buildGraph(level: GraphLevel, includeExternal: Bool = false) -> GraphBuilder.BuildResult {
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

/// 이름 조회 결과의 기존 Kit API 이름을 유지한다.
public typealias NodeLookup = GraphNodeLookup
