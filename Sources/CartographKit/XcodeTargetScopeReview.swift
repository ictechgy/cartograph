import CartographCore
import Foundation

extension CartographService {
    /// 전역 경고를 지우지 않고, 검증한 Xcode universe 밖 경로만 별도 근거로 분리한다.
    func xcodeTargetScope(path: String, fingerprint: String?, context: AnalysisContext, limit: Int) -> TargetScopeDocument {
        let fileSystem = environment.fileSystem
        let root = (try? fileSystem.realPath(at: projectPath)) ?? projectPath
        let notes = [
            "xcode-target-scope: matched producer capture, not a signed receipt or test-coverage proof. "
                + "Selectors are static review candidates for this exact project/scheme/plan/configuration/destination only; "
                + "they do not authorize skipping other tests or predict failures.",
            "xcode-target-scope-boundary: single local Swift project with explicit source phases only. "
                + "Other projects, destinations, scripts, packages, synchronized groups and conditional membership remain unsupported.",
        ]
        do {
            guard let fingerprint else { throw AnalysisSessionError.unavailable }
            let evidence = try XcodeTargetScopeStore(fileSystem: fileSystem).read(path: path, root: root, fingerprint: fingerprint)
            let inventory = context.projectFileInventory ?? projectFileInventory()
            let included = Set(inventory.sourceFiles.map(fileSystem.canonicalPath))
            let indexed = Dictionary((context.snapshot.sourceFreshnessDates ?? [:]).map {
                (fileSystem.canonicalPath($0.key), $0.value)
            }, uniquingKeysWith: min)
            let admissions = Dictionary(grouping: context.snapshot.sourceRecordAdmissions ?? [],
                by: { fileSystem.canonicalPath($0.path) })
            let targets = Dictionary(uniqueKeysWithValues: evidence.receipt.targets.map { ($0.id, $0) })
            let selectedSources = evidence.owners.filter { evidence.closure.contains($0.value) }.keys.sorted()
            var blockers: [String] = []
            for source in selectedSources {
                let relative = String(source.dropFirst(root.count + 1))
                guard included.contains(source) else { blockers.append("filtered-selected-source:" + relative); continue }
                guard let date = indexed[source], let modified = fileSystem.modificationDate(at: source), date >= modified else {
                    blockers.append("missing-or-stale-selected-unit:" + relative); continue
                }
                guard let owner = evidence.owners[source], let module = targets[owner]?.module,
                      let records = admissions[source], !records.isEmpty,
                      records.allSatisfy({ $0.module == module && !$0.unit.isEmpty && !$0.record.isEmpty
                          && $0.timestamp >= modified }) else {
                    blockers.append("unverified-source-record-module:" + relative); continue
                }
            }
            let candidates = Set(inventory.allSourceFiles + inventory.limitationFiles + inventory.discoveryExclusions
                + context.missingSourcePaths + context.unreadableSourcePaths)
            var rows: [TargetScopeDocument.Path] = []
            for candidate in candidates.sorted() {
                let source = fileSystem.canonicalPath(candidate)
                let owner = evidence.owners[source]
                let inside = owner.map(evidence.closure.contains)
                var reasons: [String] = []
                if indexed[source] == nil { reasons.append("no-observed-index-unit") }
                if !included.contains(source) { reasons.append("outside-analysis-source-filter") }
                if inventory.discoveryExclusions.contains(candidate) { reasons.append("source-discovery-exclusion") }
                if context.missingSourcePaths.contains(candidate) { reasons.append("missing-source") }
                if context.unreadableSourcePaths.contains(candidate) { reasons.append("unreadable-source") }
                guard !reasons.isEmpty else { continue }
                let relative = source.hasPrefix(root + "/") ? String(source.dropFirst(root.count + 1)) : source
                rows.append(.init(path: relative, classification: inside == true ? "within-selected-targets"
                    : inside == false ? "outside-selected-targets" : "unknown", targets: owner.flatMap { targets[$0]?.name }.map { [$0] } ?? [],
                    blockers: reasons))
                if inside != false { blockers.append("unresolved-coverage:" + relative) }
            }
            if rows.count > limit || selectedSources.count > limit { blockers.append("membership-output-truncated") }
            guard fingerprint == (try sessionInputFingerprint()) else { throw AnalysisSessionError.inputChangedDuringRefresh(attempts: 1) }
            let selectedNames = evidence.receipt.selectedTargetIDs.compactMap { targets[$0]?.name }.sorted()
            var document = TargetScopeDocument(format: "target-scope-review", version: 1, evidenceStatus: "matched-capture",
                selectedTargets: selectedNames, dependencyTargets: evidence.closure.compactMap { targets[$0]?.name }.sorted(),
                schemeIdentity: "matched-xcode-capture", paths: Array(rows.prefix(limit)), pathCount: rows.count,
                omittedPaths: max(0, rows.count - limit), limitations: notes)
            document.xcode = .init(project: evidence.receipt.project, scheme: evidence.receipt.scheme,
                testPlan: evidence.receipt.testPlan, configuration: evidence.receipt.configuration,
                destination: evidence.receipt.destination, architecture: evidence.receipt.architecture,
                selectionStatus: blockers.isEmpty ? "review-candidates" : "refused", blockers: blockers.sorted(),
                selectorTargetByModule: evidence.selectorTargets,
                selectedSourcePaths: Array(selectedSources.prefix(limit)).map { String($0.dropFirst(root.count + 1)) },
                coveredBlockerCodes: blockers.isEmpty ? ["unindexed-sources", "configured-path-filter", "source-discovery-exclusions"] : [])
            return document
        } catch {
            return .init(format: "target-scope-review", version: 1, evidenceStatus: "unknown", selectedTargets: [],
                dependencyTargets: [], schemeIdentity: "unverified", paths: [], pathCount: 0, omittedPaths: 0,
                limitations: notes + ["xcode-target-scope-unknown: \(error). Rebuild and recapture; run the whole suite."])
        }
    }
}
