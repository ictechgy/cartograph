/// `.cartograph.yml` 로 표현되는 전체 설정.
///
/// CLI 옵션이 설정 파일보다 우선하며, 병합은 `overriding(...)` 로 수행한다.
public struct CartographConfiguration: Sendable, Codable, Equatable {
    /// 인덱스 스토어 경로. 비우면 자동 탐색한다.
    public var indexStorePath: String?
    /// 분석 대상 프로젝트 루트. 비우면 현재 디렉터리.
    public var projectPath: String?
    /// 기본 그래프 해상도.
    public var level: GraphLevel
    /// 분석에 포함할 소스 경로 글롭.
    public var include: [GlobPattern]
    /// 분석에서 제외할 소스 경로 글롭.
    public var exclude: [GlobPattern]
    /// 그래프에 포함할 간선 종류. 비우면 전부 포함한다.
    public var edgeKinds: Set<EdgeKind>
    public var retention: RetentionOptions
    public var layers: [LayerDefinition]
    public var rules: [LayerRule]
    public var thresholds: Thresholds
    /// 베이스라인 파일 경로.
    public var baselinePath: String?
    public var reportFormat: ReportFormat
    public var graphFormat: GraphFormat
    /// 참이면 진단이 하나라도 있을 때 0이 아닌 코드로 종료한다.
    public var strict: Bool

    public init(
        indexStorePath: String? = nil,
        projectPath: String? = nil,
        level: GraphLevel = .module,
        include: [GlobPattern] = [],
        exclude: [GlobPattern] = CartographConfiguration.defaultExcludes,
        edgeKinds: Set<EdgeKind> = [],
        retention: RetentionOptions = .default,
        layers: [LayerDefinition] = [],
        rules: [LayerRule] = [],
        thresholds: Thresholds = .none,
        baselinePath: String? = nil,
        reportFormat: ReportFormat = .text,
        graphFormat: GraphFormat = .dot,
        strict: Bool = false
    ) {
        self.indexStorePath = indexStorePath
        self.projectPath = projectPath
        self.level = level
        self.include = include
        self.exclude = exclude
        self.edgeKinds = edgeKinds
        self.retention = retention
        self.layers = layers
        self.rules = rules
        self.thresholds = thresholds
        self.baselinePath = baselinePath
        self.reportFormat = reportFormat
        self.graphFormat = graphFormat
        self.strict = strict
    }

    /// 거의 모든 프로젝트에서 잡음이 되는 경로들.
    ///
    /// 빌드 산출물과 체크아웃된 의존성 소스는 내 코드가 아니므로 기본으로 제외한다.
    public static let defaultExcludes: [GlobPattern] = [
        "**/.build/**",
        "**/DerivedData/**",
        "**/Pods/**",
        "**/Carthage/**",
        "**/SourcePackages/checkouts/**",
        "**/*.generated.swift",
        "**/Generated/**",
    ]

    public static let `default` = CartographConfiguration()

    /// 설정에서 유도한 경로 필터.
    public var pathFilter: PathFilter {
        PathFilter(include: include, exclude: exclude)
    }

    /// 이름으로 레이어를 찾는다.
    public func layer(named name: String) -> LayerDefinition? {
        layers.first { $0.name == name }
    }

    /// 규칙이 참조하는 레이어가 모두 정의되어 있는지 검증한다.
    public func validate() throws {
        let defined = Set(layers.map(\.name))
        for rule in rules {
            for referenced in [rule.from] + (rule.allow ?? []) + (rule.deny ?? []) where !defined.contains(referenced) {
                throw CartographError.unknownLayer(name: referenced, definedLayers: layers.map(\.name).sorted())
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case indexStorePath = "index_store_path"
        case projectPath = "project_path"
        case level
        case include
        case exclude
        case edgeKinds = "edge_kinds"
        case retention
        case layers
        case rules
        case thresholds
        case baselinePath = "baseline"
        case reportFormat = "report_format"
        case graphFormat = "graph_format"
        case strict
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CartographConfiguration.default
        self.init(
            indexStorePath: try container.decodeIfPresent(String.self, forKey: .indexStorePath),
            projectPath: try container.decodeIfPresent(String.self, forKey: .projectPath),
            level: try container.decodeIfPresent(GraphLevel.self, forKey: .level) ?? fallback.level,
            include: try container.decodeIfPresent([GlobPattern].self, forKey: .include) ?? [],
            exclude: try container.decodeIfPresent([GlobPattern].self, forKey: .exclude) ?? fallback.exclude,
            edgeKinds: Set(try container.decodeIfPresent([EdgeKind].self, forKey: .edgeKinds) ?? []),
            retention: try container.decodeIfPresent(RetentionOptions.self, forKey: .retention) ?? .default,
            layers: try container.decodeIfPresent([LayerDefinition].self, forKey: .layers) ?? [],
            rules: try container.decodeIfPresent([LayerRule].self, forKey: .rules) ?? [],
            thresholds: try container.decodeIfPresent(Thresholds.self, forKey: .thresholds) ?? .none,
            baselinePath: try container.decodeIfPresent(String.self, forKey: .baselinePath),
            reportFormat: try container.decodeIfPresent(ReportFormat.self, forKey: .reportFormat)
                ?? fallback.reportFormat,
            graphFormat: try container.decodeIfPresent(GraphFormat.self, forKey: .graphFormat)
                ?? fallback.graphFormat,
            strict: try container.decodeIfPresent(Bool.self, forKey: .strict) ?? fallback.strict
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(indexStorePath, forKey: .indexStorePath)
        try container.encodeIfPresent(projectPath, forKey: .projectPath)
        try container.encode(level, forKey: .level)
        try container.encode(include, forKey: .include)
        try container.encode(exclude, forKey: .exclude)
        try container.encode(edgeKinds.sorted(), forKey: .edgeKinds)
        try container.encode(retention, forKey: .retention)
        try container.encode(layers, forKey: .layers)
        try container.encode(rules, forKey: .rules)
        try container.encode(thresholds, forKey: .thresholds)
        try container.encodeIfPresent(baselinePath, forKey: .baselinePath)
        try container.encode(reportFormat, forKey: .reportFormat)
        try container.encode(graphFormat, forKey: .graphFormat)
        try container.encode(strict, forKey: .strict)
    }
}
