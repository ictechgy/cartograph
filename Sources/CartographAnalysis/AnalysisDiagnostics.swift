import CartographCore

/// 분석 결과를 공통 진단 형식으로 바꾼다.
///
/// 리포터가 명령의 종류를 몰라도 되도록, 변환은 전부 여기 모아 둔다.
public enum AnalysisDiagnostics {
    /// 진단 규칙 식별자. 베이스라인 키이자 CI 필터의 기준이다.
    public enum Rule {
        public static let cycle = "cycle"
        public static let unusedSymbol = "unused-symbol"
        public static let layerViolation = "layer-violation"
        public static let unassignedLayer = "unassigned-layer"
        public static let instability = "instability"
        public static let mainSequenceDistance = "main-sequence-distance"
        public static let metricThreshold = "metric-threshold"
    }

    /// 순환 의존성 → 진단.
    public static func diagnostics(
        for cycles: [DependencyCycle],
        in graph: CodeGraph,
        severity: Diagnostic.Severity = .error
    ) -> [Diagnostic] {
        cycles.map { cycle in
            var details: [String] = []
            if let edge = cycle.suggestedEdgeToBreak {
                let source = graph.node(edge.source)?.qualifiedName ?? edge.source.rawValue
                let target = graph.node(edge.target)?.qualifiedName ?? edge.target.rawValue
                details.append(
                    "weakest link: \(source) → \(target) (\(edge.kind.rawValue), \(edge.weight) references)"
                )
            }
            if cycle.component.count > cycle.length {
                details.append("strongly connected component has \(cycle.component.count) nodes")
            }
            return Diagnostic(
                ruleIdentifier: Rule.cycle,
                severity: severity,
                message: "Circular dependency: \(cycle.description(using: graph))",
                location: graph.node(cycle.path.first ?? "")?.location,
                subject: cycle.path.map(\.rawValue).sorted().joined(separator: "|"),
                details: details
            )
        }
    }

    /// 미사용 선언 → 진단.
    public static func diagnostics(
        for report: UnusedCodeReport,
        severity: Diagnostic.Severity = .warning
    ) -> [Diagnostic] {
        report.unused.map { node in
            Diagnostic(
                ruleIdentifier: Rule.unusedSymbol,
                severity: severity,
                message: "\(node.kind.rawValue) '\(node.qualifiedName)' is never used",
                location: node.location,
                subject: node.usr ?? node.id.rawValue
            )
        }
    }

    /// 레이어 규칙 위반 → 진단.
    public static func diagnostics(for violations: [LayerViolation]) -> [Diagnostic] {
        violations.map { violation in
            Diagnostic(
                ruleIdentifier: Rule.layerViolation,
                severity: violation.rule.severity,
                message: violation.message,
                location: violation.location,
                subject: "\(violation.edge.source.rawValue)->\(violation.edge.target.rawValue)",
                details: ["rule: \(violation.rule.displayName)"]
            )
        }
    }

    /// 레이어가 지정되지 않은 정점 → 정보성 진단.
    ///
    /// 규칙이 실제로 무엇을 덮고 있는지 모르면 "통과"라는 결과를 믿을 수 없다.
    public static func unassignedLayerDiagnostics(
        for nodes: [NodeID],
        in graph: CodeGraph
    ) -> [Diagnostic] {
        nodes.map { node in
            Diagnostic(
                ruleIdentifier: Rule.unassignedLayer,
                severity: .info,
                message: "\(graph.node(node)?.qualifiedName ?? node.rawValue) does not belong to any layer",
                location: graph.node(node)?.location,
                subject: node.rawValue
            )
        }
    }

    /// 지표 임계값 초과 → 진단.
    public static func diagnostics(
        for metrics: [NodeMetrics],
        thresholds: Thresholds
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        // 고립 정점은 결합도 지표가 정의되지 않으므로 임계값 판정에서 제외한다.
        for entry in metrics where !entry.isIsolated {
            if let limit = thresholds.maxInstability, entry.instability > limit {
                diagnostics.append(
                    Diagnostic(
                        ruleIdentifier: Rule.instability,
                        severity: .warning,
                        message: Self.format(
                            "instability", value: entry.instability, limit: limit, name: entry.name
                        ),
                        subject: entry.node.rawValue
                    )
                )
            }
            if let limit = thresholds.maxDistanceFromMainSequence, entry.distanceFromMainSequence > limit {
                diagnostics.append(
                    Diagnostic(
                        ruleIdentifier: Rule.mainSequenceDistance,
                        severity: .warning,
                        message: Self.format(
                            "distance from the main sequence",
                            value: entry.distanceFromMainSequence,
                            limit: limit,
                            name: entry.name
                        ),
                        subject: entry.node.rawValue
                    )
                )
            }
        }
        return diagnostics
    }

    /// 개수 임계값 검사. 초과하면 오류를 던진다.
    public static func enforceCountThreshold(
        _ count: Int,
        limit: Int?,
        rule: String
    ) throws {
        guard let limit, count > limit else { return }
        throw CartographError.thresholdExceeded(
            rule: rule,
            message: "found \(count), allowed at most \(limit)"
        )
    }

    private static func format(_ label: String, value: Double, limit: Double, name: String) -> String {
        let formatted = (value * 100).rounded() / 100
        let formattedLimit = (limit * 100).rounded() / 100
        return "\(name) has \(label) \(formatted), above the configured limit of \(formattedLimit)"
    }
}
