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
        public static let testOnlySymbol = "test-only-symbol"
        public static let unusedParameter = "unused-parameter"
        public static let assignOnly = "assign-only"
        public static let unusedImport = "unused-import"
        public static let superfluousIgnore = "superfluous-ignore"
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

    /// 테스트·프리뷰만 붙잡고 있는 선언 → 진단.
    ///
    /// 죽은 코드가 아니므로 경고가 아니라 정보다. 지워도 앱은 그대로지만 테스트가
    /// 깨진다는 사실을 알려 주는 것이 목적이다.
    public static func testOnlyDiagnostics(for report: UnusedCodeReport) -> [Diagnostic] {
        report.testOnly.map { node in
            Diagnostic(
                ruleIdentifier: Rule.testOnlySymbol,
                severity: .info,
                message: "\(node.kind.rawValue) '\(node.qualifiedName)' is reached only from tests or previews",
                location: node.location,
                subject: node.usr ?? node.id.rawValue
            )
        }
    }

    /// 본문에서 읽히지 않는 파라미터 → 진단.
    ///
    /// 도달 불가능한 선언이 아니라 살아 있는 함수의 사용되지 않은 입력이다.
    /// 고치는 방법이 삭제가 아니라 `_` 표기일 수 있으므로 `unused-symbol` 과
    /// 다른 규칙으로 분리하고, strict 카운트에는 넣지 않는다.
    public static func unusedParameterDiagnostics(
        for report: UnusedCodeReport,
        in graph: CodeGraph
    ) -> [Diagnostic] {
        report.unusedParameters.map { parameter in
            let owner = graph.node(NodeID(parameter.functionUSR))
            let ownerName = owner?.qualifiedName ?? "function"
            return Diagnostic(
                ruleIdentifier: Rule.unusedParameter,
                severity: .warning,
                message: "parameter '\(parameter.name)' of '\(ownerName)' is never used",
                location: parameter.location,
                subject: parameter.usr
            )
        }
    }

    /// 대입만 되고 읽히지 않는 프로퍼티 → 진단.
    ///
    /// `unused-parameter` 와 같은 이유로 별도 규칙이다 — 살아 있는 코드가
    /// 값을 넣기만 하고 꺼내 보지 않는 저장소이지 죽은 선언이 아니므로
    /// `unused-symbol` 과 섞으면 "지워라" 로 읽힌다. 경고이며 strict
    /// 카운트에는 넣지 않는다.
    public static func assignOnlyDiagnostics(
        for report: UnusedCodeReport,
        in graph: CodeGraph
    ) -> [Diagnostic] {
        report.assignOnly.map { node in
            let owner = graph.incomingEdges(to: node.id)
                .first(where: { $0.kind == .member })
                .flatMap { graph.node($0.source)?.name }
            let context = owner.map { " of '\($0)'" } ?? ""
            return Diagnostic(
                ruleIdentifier: Rule.assignOnly,
                severity: .warning,
                message: "\(node.kind.rawValue) '\(node.name)'\(context) is assigned but never read",
                location: node.location,
                subject: node.usr ?? node.id.rawValue
            )
        }
    }

    /// 참조 근거가 증명하지 못하는 import → 진단.
    ///
    /// 선언의 생사가 아니라 파일의 모듈 의존 표시에 대한 발견이므로 별도
    /// 규칙이다 — 지워도 되는가는 삭제 판정이 아니라 "이 파일에서 그 모듈의
    /// 선언을 참조한 적이 없다"는 뜻이다. 경고이며 strict 카운트에는 넣지 않는다.
    public static func unusedImportDiagnostics(for report: UnusedCodeReport) -> [Diagnostic] {
        report.unusedImports.map { fact in
            Diagnostic(
                ruleIdentifier: Rule.unusedImport,
                severity: .warning,
                message: "import '\(fact.spelling)' is never used",
                location: fact.location,
                subject: "import:\(fact.location.path):\(fact.spelling)"
            )
        }
    }

    /// 떼어 내도 아무 보고도 억제하지 않는 `cartograph:ignore` → 진단.
    ///
    /// 억제할 발견이 없는 주석은 죽은 주석이다 — 선언을 죽은 것으로 영원히
    /// 덮고, 지워도 된다는 잘못된 확신을 남긴다. 경고이며 strict 카운트에는
    /// 넣지 않는다. 베이스라인 키는 선언 자체의 발견과 섞이지 않도록 주석임을
    /// 표시한다.
    public static func superfluousIgnoreDiagnostics(for report: UnusedCodeReport) -> [Diagnostic] {
        report.superfluousIgnores.map { entry in
            let message: String
            let subject: String
            if entry.coversWholeFile, let path = entry.node.location?.path {
                message = "file-level 'cartograph:ignore:all' comment is superfluous "
                    + "— no declaration in this file needs it"
                subject = "ignore:file:\(path)"
            } else {
                let covered = entry.coveredCount > 1
                    ? " and \(entry.coveredCount - 1) declaration(s) it covers" : ""
                message = "ignore comment on '\(entry.node.qualifiedName)'\(covered) is superfluous "
                    + "— removing it would report nothing"
                subject = (entry.node.usr ?? entry.node.id.rawValue) + "|ignore"
            }
            return Diagnostic(
                ruleIdentifier: Rule.superfluousIgnore,
                severity: .warning,
                message: message,
                location: entry.node.location,
                subject: subject
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
                // 규칙 이름과 간선 종류를 지문에 넣는다. 이것이 없으면 같은 두 모듈
                // 사이의 위반이 전부 한 지문으로 뭉쳐, 하나를 베이스라인에 넣는 순간
                // 아직 보지 못한 위반까지 함께 묻힌다.
                subject: "\(violation.rule.displayName)|\(violation.edge.kind.rawValue)|"
                    + "\(violation.edge.source.rawValue)->\(violation.edge.target.rawValue)",
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
