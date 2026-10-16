import CartographCore

/// Review candidates for observed enum-case additions. This is not a behavioral-bug verdict.
public struct EnumChangeReview: Codable, Sendable, Equatable {
    public struct AddedCase: Codable, Sendable, Equatable {
        public let usr: String
        public let name: String
        public let location: SourceLocation
    }
    public struct Change: Codable, Sendable, Equatable {
        public let enumUSR: String
        public let name: String
        public let module: String
        public let location: SourceLocation
        public let beforeCaseCount: Int
        public let currentCaseCount: Int
        public let addedCases: [AddedCase]
        public let addedCaseCount: Int
    }
    public struct Candidate: Codable, Sendable, Equatable {
        public let enumUSR: String
        public let ownerUSR: String?
        public let location: SourceLocation
        public let endLocation: SourceLocation
        public let kind: EnumDecisionFact.Kind
        public let reason: String
        public let addedCaseUSRs: [String]
        public let addedCaseCount: Int
        public let explicitCaseUSRs: [String]
        public let explicitCaseCount: Int
        public let guardedCaseUSRs: [String]
        public let guardedCaseCount: Int
        public let evidenceLocations: [SourceLocation]
        public let evidenceCount: Int
        public let operationTargetUSRs: [String]
        public let operationTargetCount: Int
        public let limitations: [String]
    }
    public struct UnresolvedDecision: Codable, Sendable, Equatable {
        public let enumUSR: String?
        public let location: SourceLocation
        public let endLocation: SourceLocation
        public let evidenceLocations: [SourceLocation]
        public let evidenceCount: Int
        public let kind: EnumDecisionFact.Kind
        public let explicitCaseUSRs: [String]
        public let explicitCaseCount: Int
        public let operationTargetUSRs: [String]
        public let operationTargetCount: Int
        public let limitations: [String]
    }
    public struct Issue: Codable, Sendable, Equatable {
        public let kind: String
        public let enumUSR: String?
        public let path: String?
    }
    public let status: String
    public let changes: [Change]
    public let changeCount: Int
    public let candidates: [Candidate]
    public let candidateCount: Int
    public let issues: [Issue]
    public let issueCount: Int
    public let unresolvedDecisions: [UnresolvedDecision]
    public let unresolvedDecisionCount: Int
    public let unattributedDecisionCount: Int
    public let truncated: Bool
    public let limitations: [String]
}

/// Uses compiler identities and located syntax facts; never invents an edge to a new case.
public struct EnumChangeImpactAnalyzer: Sendable {
    public init() {}

    public func analyze(before: IndexSnapshot, current: IndexSnapshot,
                        selected: Set<NodeID>, limit: Int, admittedConsumerPaths: Set<String>? = nil) -> EnumChangeReview {
        let cap = max(0, limit)
        let oldSymbols = before.symbolsByUSR()
        let newSymbols = current.symbolsByUSR()
        var relevant: Set<String> = []
        for id in selected {
            for symbols in [oldSymbols, newSymbols] {
                guard let symbol = symbols[id.rawValue] else { continue }
                if symbol.kind == .enumType { relevant.insert(symbol.usr) }
                if symbol.kind == .enumCase, let parent = symbol.parentUSR { relevant.insert(parent) }
            }
        }
        var issues: [EnumChangeReview.Issue] = []
        var changes: [EnumChangeReview.Change] = []
        var additions: [String: [String]] = [:]
        var truncated = false
        let limitations: [String] = relevant.isEmpty ? [] : [
            "Candidates identify source decisions to review if an added case reaches them; they do not prove a bug or runtime path.",
            "Case additions are between these indexed snapshots. Build configuration, conditional compilation and indexing scope may differ.",
            "Supported patterns: switch default/@unknown default and direct finite array-literal contains, including direct negation.",
            "if/guard case, equality/inequality, filters, dynamic or aliased collections and allCases are not evaluated.",
            "A legacy baseline without enum inventories must be recaptured with enum-decision support."
        ]
        if !relevant.isEmpty && before.enumImpactFiles == nil {
            issues.append(.init(kind: "baseline-enum-facts-unavailable", enumUSR: nil, path: nil))
        }
        if !relevant.isEmpty && current.enumImpactFiles == nil {
            issues.append(.init(kind: "current-enum-facts-unavailable", enumUSR: nil, path: nil))
        }
        let oldInventories = inventories(before.enumImpactFiles)
        let newInventories = inventories(current.enumImpactFiles)
        let oldCasesByEnum = casesByEnum(oldSymbols)
        let newCasesByEnum = casesByEnum(newSymbols)
        for usr in relevant.sorted() {
            guard let old = oldSymbols[usr], let new = newSymbols[usr],
                  old.kind == .enumType, new.kind == .enumType,
                  old.module == new.module, !usr.hasPrefix("cartograph:") else {
                issues.append(.init(kind: "unmatched-enum-identity", enumUSR: usr, path: newSymbols[usr]?.location.path))
                continue
            }
            guard let oldRows = oldInventories[usr], oldRows.count == 1,
                  let newRows = newInventories[usr], newRows.count == 1,
                  valid(oldRows[0], symbols: oldSymbols, observed: oldCasesByEnum),
                  valid(newRows[0], symbols: newSymbols, observed: newCasesByEnum) else {
                issues.append(.init(kind: "incomplete-enum-inventory", enumUSR: usr, path: new.location.path))
                continue
            }
            let oldCases = Set(oldRows[0].caseUSRs)
            let currentCases = Set(newRows[0].caseUSRs)
            let added = currentCases.subtracting(oldCases).sorted()
            guard !added.isEmpty else { continue }
            additions[usr] = added
            let shown = added.prefix(cap).compactMap { id -> EnumChangeReview.AddedCase? in
                guard let symbol = newSymbols[id] else { return nil }
                return .init(usr: id, name: symbol.name, location: symbol.location)
            }
            truncated = truncated || shown.count < added.count
            changes.append(.init(enumUSR: usr, name: new.name, module: new.module,
                location: new.location, beforeCaseCount: oldCases.count, currentCaseCount: currentCases.count,
                addedCases: shown, addedCaseCount: added.count))
        }

        var candidates: [EnumChangeReview.Candidate] = []
        var unresolved: [EnumChangeReview.UnresolvedDecision] = []
        var unattributed = 0
        if !additions.isEmpty {
            let fileGroups = Dictionary(grouping: current.enumImpactFiles ?? [], by: \.path)
            let indexedPaths = Set(current.symbols.filter {
                !$0.isExternal && $0.location.path.hasSuffix(".swift")
                    && (admittedConsumerPaths?.contains($0.location.path) ?? true)
            }.map { $0.location.path })
            for path in indexedPaths.sorted() {
                guard let rows = fileGroups[path], rows.count == 1 else {
                    issues.append(.init(kind: "current-consumer-coverage-incomplete", enumUSR: nil, path: path))
                    continue
                }
                let file = rows[0]
                let fileLimits = file.status == "fresh" ? [] : file.limitations + ["file-coverage-\(file.status)"]
                if file.status != "fresh" {
                    issues.append(.init(kind: "current-consumer-coverage-incomplete", enumUSR: nil, path: path))
                }
                for decision in file.decisions {
                    guard let enumUSR = decision.enumUSR else {
                        unattributed += 1
                        unresolved.append(.init(enumUSR: nil, location: decision.location,
                            endLocation: decision.endLocation,
                            evidenceLocations: Array(decision.evidenceLocations.prefix(cap)),
                            evidenceCount: decision.evidenceLocations.count, kind: decision.kind,
                            explicitCaseUSRs: Array(decision.explicitCaseUSRs.prefix(cap)),
                            explicitCaseCount: decision.explicitCaseUSRs.count,
                            operationTargetUSRs: Array(decision.operationTargetUSRs.prefix(cap)),
                            operationTargetCount: decision.operationTargetUSRs.count,
                            limitations: decision.limitations + fileLimits + ["not-attributed-to-selected-enum"]))
                        truncated = truncated || decision.explicitCaseUSRs.count > cap
                            || decision.operationTargetUSRs.count > cap || decision.evidenceLocations.count > cap
                        continue
                    }
                    guard let added = additions[enumUSR] else { continue }
                    guard decision.status == "resolved", file.status == "fresh" else {
                        unresolved.append(.init(enumUSR: enumUSR, location: decision.location,
                            endLocation: decision.endLocation,
                            evidenceLocations: Array(decision.evidenceLocations.prefix(cap)),
                            evidenceCount: decision.evidenceLocations.count, kind: decision.kind,
                            explicitCaseUSRs: Array(decision.explicitCaseUSRs.prefix(cap)),
                            explicitCaseCount: decision.explicitCaseUSRs.count,
                            operationTargetUSRs: Array(decision.operationTargetUSRs.prefix(cap)),
                            operationTargetCount: decision.operationTargetUSRs.count, limitations: decision.limitations + fileLimits))
                        truncated = truncated || decision.explicitCaseUSRs.count > cap
                            || decision.operationTargetUSRs.count > cap || decision.evidenceLocations.count > cap
                        continue
                    }
                    // Guarded cases deliberately do not establish unconditional handling.
                    let explicit = Set(decision.explicitCaseUSRs)
                    let unhandled = added.filter { !explicit.contains($0) }
                    guard !unhandled.isEmpty else { continue }
                    let membership = decision.kind == .literalMembership || decision.kind == .negatedLiteralMembership
                    let evidence = decision.evidenceLocations
                    let targets = decision.operationTargetUSRs
                    truncated = truncated || unhandled.count > cap || decision.explicitCaseUSRs.count > cap
                        || decision.guardedCaseUSRs.count > cap || evidence.count > cap || targets.count > cap
                    candidates.append(.init(
                        enumUSR: enumUSR, ownerUSR: decision.ownerUSR,
                        location: decision.location, endLocation: decision.endLocation, kind: decision.kind,
                        reason: membership ? "added-case-outside-explicit-literal-set" : "added-case-not-unconditionally-handled-before-fallback",
                        addedCaseUSRs: Array(unhandled.prefix(cap)), addedCaseCount: unhandled.count,
                        explicitCaseUSRs: Array(decision.explicitCaseUSRs.prefix(cap)),
                        explicitCaseCount: decision.explicitCaseUSRs.count,
                        guardedCaseUSRs: Array(decision.guardedCaseUSRs.prefix(cap)),
                        guardedCaseCount: decision.guardedCaseUSRs.count,
                        evidenceLocations: Array(evidence.prefix(cap)), evidenceCount: evidence.count,
                        operationTargetUSRs: Array(targets.prefix(cap)), operationTargetCount: targets.count,
                        limitations: decision.limitations))
                }
            }
        }
        candidates.sort {
            let a = ($0.enumUSR, $0.location.path, $0.location.line, $0.location.column, $0.kind.rawValue)
            let b = ($1.enumUSR, $1.location.path, $1.location.line, $1.location.column, $1.kind.rawValue)
            return a < b
        }
        unresolved.sort {
            ($0.enumUSR ?? "", $0.location.path, $0.location.line, $0.location.column, $0.kind.rawValue)
                < ($1.enumUSR ?? "", $1.location.path, $1.location.line, $1.location.column, $1.kind.rawValue)
        }
        issues.sort { ($0.kind, $0.enumUSR ?? "", $0.path ?? "") < ($1.kind, $1.enumUSR ?? "", $1.path ?? "") }
        truncated = truncated || changes.count > cap || candidates.count > cap || issues.count > cap || unresolved.count > cap
        return EnumChangeReview(
            status: relevant.isEmpty ? "notApplicable"
                : (!issues.isEmpty || !unresolved.isEmpty || unattributed > 0 ? "partial"
                    : (candidates.isEmpty ? "noCandidates" : "review")),
            changes: Array(changes.prefix(cap)), changeCount: changes.count,
            candidates: Array(candidates.prefix(cap)), candidateCount: candidates.count,
            issues: Array(issues.prefix(cap)), issueCount: issues.count,
            unresolvedDecisions: Array(unresolved.prefix(cap)), unresolvedDecisionCount: unresolved.count,
            unattributedDecisionCount: unattributed,
            truncated: truncated, limitations: limitations)
    }

    private func inventories(_ files: [EnumImpactFileFacts]?) -> [String: [EnumCaseInventory]] {
        Dictionary(grouping: (files ?? []).filter { $0.status == "fresh" }.flatMap(\.inventories), by: \.enumUSR)
    }

    private func casesByEnum(_ symbols: [String: IndexedSymbol]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for symbol in symbols.values where symbol.kind == .enumCase {
            if let parent = symbol.parentUSR { result[parent, default: []].insert(symbol.usr) }
        }
        return result
    }

    private func valid(_ inventory: EnumCaseInventory, symbols: [String: IndexedSymbol],
                       observed: [String: Set<String>]) -> Bool {
        guard inventory.complete, let owner = symbols[inventory.enumUSR], owner.kind == .enumType else { return false }
        return (observed[inventory.enumUSR] ?? []) == Set(inventory.caseUSRs)
            && inventory.caseUSRs.allSatisfy {
                symbols[$0]?.kind == .enumCase && symbols[$0]?.parentUSR == inventory.enumUSR
            }
    }
}
