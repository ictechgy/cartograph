import CartographAnalysis
import CartographCore
import CartographSyntax

/// 안전한 기계적 수정 계획과 그 적용 결과.
///
/// `dead` 의 경고 중 소스만 바꿔 안전하게 없앨 수 있는 두 종류 —
/// `unused-import` 와 `unused-parameter` — 를 모은다. 기본은 계획이고,
/// `--apply` 로만 파일을 쓴다.
public struct MechanicalFixDocument: Sendable, Equatable, Codable {
    public static let format = "mechanical-fixes"
    public static let version = 1

    public let format: String
    public let version: Int
    public let project: String
    /// 파일을 실제로 썼는지 여부. 거짓이면 계산만 한 계획이다.
    public let applied: Bool
    /// 적용할 수 있는(또는 적용한) 편집 수.
    public let editCount: Int
    /// 위치가 어긋나 적용하지 못한 편집 수.
    public let skippedCount: Int
    /// 편집이 있는 파일 수.
    public let fileCount: Int
    /// 스코프·베이스라인으로 보고에서 빠진 발견 수.
    public let suppressedCount: Int
    public let edits: [Edit]
    public let skipped: [Skip]
    public let limitations: [String]

    /// 실제로 만들어진 편집 하나.
    public struct Edit: Sendable, Equatable, Codable {
        public let file: String
        public let line: Int
        public let column: Int
        /// `unused-import` 또는 `unused-parameter`.
        public let rule: String
        public let message: String
        /// 바꿔 끼운 텍스트. import 제거는 빈 문자열이다.
        public let replacement: String
    }

    /// 편집을 만들지 못한 요청 하나.
    public struct Skip: Sendable, Equatable, Codable {
        public let file: String
        public let line: Int
        public let column: Int
        public let rule: String
        public let reason: String
    }

    init(
        project: String,
        applied: Bool,
        edits: [Edit],
        skipped: [Skip],
        suppressedCount: Int,
        limitations: [String]
    ) {
        format = Self.format
        version = Self.version
        self.project = project
        self.applied = applied
        self.edits = edits
        self.skipped = skipped
        editCount = edits.count
        skippedCount = skipped.count
        fileCount = Set(edits.map(\.file)).count
        self.suppressedCount = suppressedCount
        self.limitations = limitations
    }
}

extension CartographService {
    /// 기계적 수정 계획을 세우고, `apply` 면 파일을 쓴다.
    ///
    /// 편집은 인덱스·구문 사실이 가리키는 자리에서 **지금 소스**를 다시 파싱해
    /// 찾는다. 자리가 어긋났거나 편집 결과가 파싱되지 않으면 그 편집은 건너뛰고
    /// 이유를 남긴다 — 확인되지 않은 텍스트는 쓰지 않는다. 쓰기는 파일 단위로
    /// 원자적이다(`FileSystem.write`).
    public func mechanicalFixes(apply: Bool, format: String) throws -> CommandOutcome {
        guard format == "text" || format == "json" else {
            throw CartographError.invalidConfiguration(
                path: projectPath, reason: "Fix format must be text or json."
            )
        }
        let context = try loadContext()
        let (graph, report) = unusedCode(in: context)
        // 베이스라인이 이미 받아들인 발견과 `--since` 범위 밖은 건드리지 않는다.
        let diagnostics = AnalysisDiagnostics.unusedImportDiagnostics(for: report)
            + AnalysisDiagnostics.unusedParameterDiagnostics(for: report, in: graph)
        let (kept, suppressedCount) = try filterAndApplyBaseline(diagnostics)

        let importFacts = Dictionary(
            report.unusedImports.map { ("import:\($0.location.path):\($0.spelling)", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let parameterFacts = Dictionary(
            report.unusedParameters.map { ($0.usr, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let entries = kept.compactMap { diagnostic -> PlannedFix? in
            switch diagnostic.ruleIdentifier {
            case AnalysisDiagnostics.Rule.unusedImport:
                guard let subject = diagnostic.subject, let fact = importFacts[subject] else { return nil }
                return PlannedFix(
                    path: fact.location.path, rule: diagnostic.ruleIdentifier,
                    message: diagnostic.message, location: fact.location,
                    request: .removeImport(
                        modulePath: fact.modulePath, scopedKind: fact.scopedKind, at: fact.location
                    )
                )
            case AnalysisDiagnostics.Rule.unusedParameter:
                guard let subject = diagnostic.subject, let fact = parameterFacts[subject] else { return nil }
                return PlannedFix(
                    path: fact.location.path, rule: diagnostic.ruleIdentifier,
                    message: diagnostic.message, location: fact.location,
                    request: .unnameParameter(name: fact.name, at: fact.location)
                )
            default:
                return nil
            }
        }

        var edits: [MechanicalFixDocument.Edit] = []
        var skipped: [MechanicalFixDocument.Skip] = []
        let fixer = MechanicalFixer()
        for (path, fileEntries) in Dictionary(grouping: entries, by: \.path).sorted(by: { $0.key < $1.key }) {
            let source: String
            do {
                source = try environment.fileSystem.readText(at: path)
            } catch {
                skipped += fileEntries.map { $0.skipped(reason: MechanicalFixSkipReason.unreadable.rawValue) }
                continue
            }
            let application = fixer.apply(fileEntries.map(\.request), to: source, path: path)
            for (index, entry) in fileEntries.enumerated() {
                switch application.statuses[index] {
                case let .fixable(replacement):
                    edits.append(MechanicalFixDocument.Edit(
                        file: path, line: entry.location.line, column: entry.location.column,
                        rule: entry.rule, message: entry.message, replacement: replacement
                    ))
                case let .skipped(reason):
                    skipped.append(entry.skipped(reason: reason.rawValue))
                }
            }
            if apply, application.changed {
                do {
                    try environment.fileSystem.write(text: application.source, to: path)
                } catch {
                    throw CartographError.outputUnwritable(path: path, underlying: "\(error)")
                }
            }
        }

        let limitations = analysisLimitations(context: context, symbolGraph: graph)
        let document = MechanicalFixDocument(
            project: projectPath,
            applied: apply,
            edits: edits,
            skipped: skipped,
            suppressedCount: suppressedCount,
            limitations: limitations
        )
        return CommandOutcome(
            output: format == "json"
                ? try Self.encodeSortedJSON(document)
                : Self.renderFixes(document),
            // 드라이런에서는 남은 작업이, 적용 뒤에는 적용하지 못한 편집이
            // `--strict` 의 실패 사유다.
            findingCount: apply ? document.skippedCount : document.editCount,
            suppressedCount: suppressedCount
        )
    }

    private static func renderFixes(_ document: MechanicalFixDocument) -> String {
        var lines = document.edits.map { edit in
            "\(edit.file):\(edit.line):\(edit.column): \(edit.message)"
        }
        lines += document.skipped.map { skip in
            "skipped \(skip.file):\(skip.line):\(skip.column): \(skip.reason) (\(skip.rule))"
        }
        if document.edits.isEmpty, document.skipped.isEmpty {
            lines.append("no mechanical fixes found")
        } else if document.applied {
            lines.append(
                "\(document.editCount) fix(es) in \(document.fileCount) file(s) — applied"
            )
        } else {
            lines.append(
                "\(document.editCount) fix(es) in \(document.fileCount) file(s) — dry run; pass --apply to write"
            )
        }
        if document.suppressedCount > 0 {
            lines.append(
                "\(document.suppressedCount) finding(s) suppressed by the baseline"
            )
        }
        lines += document.limitations.map { "Limitation: \($0)" }
        return lines.map { PrintableText.printable($0) }.joined(separator: "\n") + "\n"
    }
}

/// 계획 단계의 편집 하나.
private struct PlannedFix {
    let path: String
    let rule: String
    let message: String
    let location: SourceLocation
    let request: MechanicalFixRequest

    func skipped(reason: String) -> MechanicalFixDocument.Skip {
        MechanicalFixDocument.Skip(
            file: path, line: location.line, column: location.column,
            rule: rule, reason: reason
        )
    }
}
