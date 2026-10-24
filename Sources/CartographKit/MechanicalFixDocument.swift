import CartographAnalysis
import CartographCore
import CartographSyntax
import Foundation

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
    /// 선택 검증의 결과. 기존 드라이런·명시 적용 문서에는 키가 없다.
    public let verification: MechanicalFixVerificationReport?

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
        limitations: [String],
        verification: MechanicalFixVerificationReport? = nil
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
        self.verification = verification
    }
}

extension CartographService {
    /// `fix` 가 고치는 두 경고 — `unused-import` 와 `unused-parameter` — 의 진단.
    ///
    /// `fix` 는 베이스라인이 받아들인 발견을 건드리지 않고, `baseline` 은 같은 목록을 기록한다
    /// (`collectAllDiagnostics()`). 두 자리가 목록을 따로 들면 한쪽에만 규칙이 늘어, 베이스라인이 기록하지 못한
    /// 발견이 `fix --strict` 드라이런을 영원히 실패시킨다.
    static func mechanicallyFixableDiagnostics(for report: UnusedCodeReport, in graph: CodeGraph) -> [Diagnostic] {
        AnalysisDiagnostics.unusedImportDiagnostics(for: report)
            + AnalysisDiagnostics.unusedParameterDiagnostics(for: report, in: graph)
    }

    /// 기계적 수정 계획을 세우고, `apply` 면 파일을 쓴다.
    ///
    /// 편집은 인덱스·구문 사실이 가리키는 자리에서 **지금 소스**를 다시 파싱해
    /// 찾는다. 자리가 어긋났거나 편집 결과가 파싱되지 않으면 그 편집은 건너뛰고
    /// 이유를 남긴다 — 확인되지 않은 텍스트는 쓰지 않는다. 쓰기는 파일 단위로
    /// 원자적이다(`FileSystem.write`).
    public func mechanicalFixes(apply: Bool, format: String) throws -> CommandOutcome {
        try mechanicalFixes(apply: apply, format: format, verification: nil)
    }

    /// 검증을 선택하면 편집 전 바이트를 보관하고 실패 시 이 명령의 변경만 복구한다.
    public func mechanicalFixes(apply: Bool, format: String,
                                verification: MechanicalFixVerification?) throws -> CommandOutcome {
        if let verification {
            try verification.validate()
            guard apply else {
                throw CartographError.invalidConfiguration(path: projectPath,
                    reason: "Verification requires explicit apply; no command was executed.")
            }
        }
        guard format == "text" || format == "json" else {
            throw CartographError.invalidConfiguration(
                path: projectPath, reason: "Fix format must be text or json."
            )
        }
        let context = try loadContext()
        let (graph, report) = unusedCode(in: context, computingSuperfluousIgnores: false)
        // 베이스라인이 이미 받아들인 발견과 `--since` 범위 밖은 건드리지 않는다.
        let diagnostics = Self.mechanicallyFixableDiagnostics(for: report, in: graph)
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
        var prepared: [PreparedMechanicalEdit] = []
        var preparedBytes = 0
        let fixer = MechanicalFixer()
        for (path, fileEntries) in Dictionary(grouping: entries, by: \.path).sorted(by: { $0.key < $1.key }) {
            let source: String
            let original: Data
            do {
                original = try environment.fileSystem.readData(at: path)
                guard let decoded = String(data: original, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                source = decoded
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
                if verification != nil {
                    guard prepared.count < MechanicalFixVerification.maximumFiles,
                          original.count <= MechanicalFixVerification.maximumSourceBytes - preparedBytes else {
                        throw CartographError.invalidConfiguration(path: projectPath,
                            reason: "Verified fixes exceed 10000 files or 64 MiB; narrow the scope. No files changed.")
                    }
                    preparedBytes += original.count
                    prepared.append(.init(path: path, original: original,
                                          replacement: Data(application.source.utf8)))
                    continue
                }
                do {
                    try environment.fileSystem.write(text: application.source, to: path)
                } catch {
                    throw CartographError.outputUnwritable(path: path, underlying: "\(error)")
                }
            }
        }

        let verificationReport = try verification.map { option in
            do {
                return try MechanicalFixTransaction(edits: prepared, project: projectPath,
                    fileSystem: environment.fileSystem, verification: option).perform()
            } catch let error as CartographError {
                throw error
            } catch {
                throw CartographError.outputUnwritable(
                    path: PrintableText.printable(option.recoveryDirectory ?? projectPath),
                    underlying: "Could not prepare recovery evidence; no source files changed. "
                        + PrintableText.printable(String(describing: error)))
            }
        }
        let limitations = analysisLimitations(context: context, symbolGraph: graph) + (verificationReport == nil ? [
            "fix-build-not-verified: edits are parse-checked only, not type-checked or built; writes are atomic "
                + "per file, not across the full edit set. Review the diff and rebuild all relevant targets."
        ] : [
            "fix-verification-scope: only the selected argv command was checked. Original dirty source bytes "
                + "are retained in the private recovery directory. Rollback restores only unchanged Cartograph-owned "
                + "edits; verifier side effects, Git operations, build outputs and concurrent changes are not reverted. "
                + "SIGKILL, power loss and hostile commands cannot be automatically recovered."
        ])
        let document = MechanicalFixDocument(
            project: projectPath,
            applied: apply && (verificationReport.map { $0.passed || !$0.rollback.hasPrefix("restored") } ?? true),
            edits: edits,
            skipped: skipped,
            suppressedCount: suppressedCount,
            limitations: limitations,
            verification: verificationReport
        )
        return CommandOutcome(
            output: format == "json"
                ? try Self.encodeSortedJSON(document)
                : Self.renderFixes(document),
            // 드라이런에서는 남은 작업이, 적용 뒤에는 적용하지 못한 편집이
            // `--strict` 의 실패 사유다.
            findingCount: apply ? document.skippedCount : document.editCount,
            suppressedCount: suppressedCount,
            incompleteAnalysis: verificationReport.flatMap { $0.passed ? nil :
                "Fix verification \($0.status); rollback \($0.rollback). Inspect "
                    + PrintableText.printable($0.recoveryDirectory) + "." }
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
        } else if let verification = document.verification, !verification.passed {
            lines.append("\(document.editCount) planned fix(es) — verification \(verification.status); "
                + "rollback \(verification.rollback)")
        } else if document.applied {
            lines.append(
                "\(document.editCount) fix(es) in \(document.fileCount) file(s) — applied"
            )
        } else {
            lines.append(
                "\(document.editCount) fix(es) in \(document.fileCount) file(s) — dry run; pass --apply to write"
            )
        }
        if let verification = document.verification {
            lines.append("Verification: \(verification.status). Recovery evidence: \(verification.recoveryDirectory)")
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
