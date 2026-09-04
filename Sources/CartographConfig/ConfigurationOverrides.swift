import CartographCore

/// CLI 옵션으로 설정 파일 값을 덮어쓸 때 쓰는 부분 설정.
///
/// 모든 필드가 선택 값이며, nil 은 "이 항목은 건드리지 않는다"는 뜻이다.
/// 우선순위는 CLI > 설정 파일 > 기본값 이다.
public struct ConfigurationOverrides: Sendable, Equatable {
    public var indexStorePath: String?
    public var projectPath: String?
    public var derivedDataPath: String?
    public var level: GraphLevel?
    public var include: [GlobPattern]?
    public var exclude: [GlobPattern]?
    public var edgeKinds: Set<EdgeKind>?
    public var baselinePath: String?
    public var externalRetentionsPath: String?
    public var reportFormat: ReportFormat?
    public var graphFormat: GraphFormat?
    public var strict: Bool?
    public var retainPublic: Bool?

    public init(
        indexStorePath: String? = nil,
        projectPath: String? = nil,
        derivedDataPath: String? = nil,
        level: GraphLevel? = nil,
        include: [GlobPattern]? = nil,
        exclude: [GlobPattern]? = nil,
        edgeKinds: Set<EdgeKind>? = nil,
        baselinePath: String? = nil,
        externalRetentionsPath: String? = nil,
        reportFormat: ReportFormat? = nil,
        graphFormat: GraphFormat? = nil,
        strict: Bool? = nil,
        retainPublic: Bool? = nil
    ) {
        self.indexStorePath = indexStorePath
        self.projectPath = projectPath
        self.derivedDataPath = derivedDataPath
        self.level = level
        self.include = include
        self.exclude = exclude
        self.edgeKinds = edgeKinds
        self.baselinePath = baselinePath
        self.externalRetentionsPath = externalRetentionsPath
        self.reportFormat = reportFormat
        self.graphFormat = graphFormat
        self.strict = strict
        self.retainPublic = retainPublic
    }
}

extension CartographConfiguration {
    /// 부분 설정을 얹은 새 설정을 만든다.
    public func applying(_ overrides: ConfigurationOverrides) -> CartographConfiguration {
        var result = self
        if let value = overrides.indexStorePath { result.indexStorePath = value }
        if let value = overrides.projectPath { result.projectPath = value }
        if let value = overrides.derivedDataPath { result.derivedDataPath = value }
        if let value = overrides.level { result.level = value }
        if let value = overrides.include { result.include = value }
        if let value = overrides.exclude { result.exclude = value }
        if let value = overrides.edgeKinds { result.edgeKinds = value }
        if let value = overrides.baselinePath { result.baselinePath = value }
        if let value = overrides.externalRetentionsPath { result.externalRetentionsPath = value }
        if let value = overrides.reportFormat { result.reportFormat = value }
        if let value = overrides.graphFormat { result.graphFormat = value }
        if let value = overrides.strict { result.strict = value }
        if let value = overrides.retainPublic { result.retention.retainPublic = value }
        return result
    }
}
