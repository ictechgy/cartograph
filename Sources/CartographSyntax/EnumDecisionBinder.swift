import CartographCore

/// Exact occurrence joins for the deliberately small enum-decision syntax model.
enum EnumDecisionBinder {
    /// - Parameter onIndexedRows: 위치 색인에 담은 심볼·참조·매개변수 행 수를 받는다. 테스트가 결정과 무관한
    ///   행을 색인하지 않는지 센다.
    static func bind(snapshot: IndexSnapshot, files: [String: SourceFileFacts],
                     freshPaths: Set<String>, onIndexedRows: ((Int) -> Void)? = nil) -> [EnumImpactFileFacts]? {
        guard files.values.contains(where: { $0.enumDecisionFacts != nil }) else { return nil }
        let context = BindingContext(snapshot: snapshot,
            locations: lookupLocations(files.values.compactMap(\.enumDecisionFacts)))
        onIndexedRows?(context.indexedRows)
        return files.keys.sorted().compactMap { path in
            guard let scan = files[path]?.enumDecisionFacts else { return nil }
            let fresh = freshPaths.contains(path)
            let inventories = scan.inventories.compactMap { context.inventory($0, fresh: fresh) }
            let inventoryLimitations = inventories.count == scan.inventories.count ? [] : ["unbound-enum-declaration"]
            let fileLimitations = scan.limitations + inventoryLimitations
            let status = !fresh ? "unverifiedFreshness" : (fileLimitations.isEmpty ? "fresh" : "partial")
            return EnumImpactFileFacts(path: path, status: status,
                inventories: inventories,
                decisions: scan.decisions.compactMap { context.decision($0, fresh: fresh) },
                limitations: fileLimitations + (fresh ? [] : ["source-index-freshness-unverified"]))
        }
    }

    /// 목록과 결정이 실제로 조회하는 위치. 이 밖의 행은 어떤 결합에도 쓰이지 않는다.
    private static func lookupLocations(_ scans: [EnumDecisionScanFacts]) -> Set<SourceLocation> {
        var locations: Set<SourceLocation> = []
        for scan in scans {
            for inventory in scan.inventories {
                locations.formUnion([inventory.nameLocation] + inventory.cases.map(\.location))
            }
            for decision in scan.decisions { locations.formUnion(lookupLocations(of: decision)) }
        }
        return locations
    }

    private static func lookupLocations(of decision: EnumDecisionSyntaxFacts) -> [SourceLocation] {
        let subject = decision.subjectParameter.map { [$0.parameterNameLocation, $0.typeNameLocation] } ?? []
        return (decision.explicitCases + decision.guardedCases).map(\.location) + subject
            + [decision.operationLocation, decision.negationLocation].compactMap { $0 }
    }

    private struct BindingContext {
        // Exact standard-library identities. The compiler-index integration fixture must
        // validate these on supported CI toolchains; unknown identities are unresolved.
        static let containsTargets: Set<String> = ["s:STsSQ7ElementRpzrlE8containsySbABF"]
        static let negationTargets: Set<String> = ["s:Sb1nopyS2bFZ"]

        let caseUSRsByEnum: [String: Set<String>]
        let symbols: [String: IndexedSymbol]
        let declarations: [SourceLocation: [IndexedSymbol]]
        let references: [SourceLocation: [IndexedReference]]
        let parameters: [SourceLocation: [IndexedParameter]]
        let indexedRows: Int

        /// 조회할 위치의 행만 묶는다. 결정은 토큰 몇 개만 묻는데 프로젝트 전체 참조를 위치마다 묶으면 참조
        /// 100만 개에서 0.5초와 0.4GB 를 더 썼다. 묻는 위치가 없으면 어떤 조회도 없으므로 스냅샷을 훑지 않는다.
        init(snapshot: IndexSnapshot, locations: Set<SourceLocation>) {
            guard !locations.isEmpty else {
                caseUSRsByEnum = [:]
                symbols = [:]
                declarations = [:]
                references = [:]
                parameters = [:]
                indexedRows = 0
                return
            }
            var cases: [String: Set<String>] = [:]
            var declarations: [SourceLocation: [IndexedSymbol]] = [:]
            for symbol in snapshot.symbols {
                if symbol.kind == .enumCase, let parent = symbol.parentUSR {
                    cases[parent, default: []].insert(symbol.usr)
                }
                if locations.contains(symbol.location) { declarations[symbol.location, default: []].append(symbol) }
            }
            caseUSRsByEnum = cases
            symbols = snapshot.symbolsByUSR()
            self.declarations = declarations
            references = Self.compilerReferences(snapshot.references, at: locations)
            parameters = Dictionary(grouping: snapshot.parameters.filter { locations.contains($0.location) },
                by: \.location)
            indexedRows = [declarations.values.map(\.count), references.values.map(\.count),
                parameters.values.map(\.count)].joined().reduce(0, +)
        }

        private static func compilerReferences(
            _ references: [IndexedReference], at locations: Set<SourceLocation>
        ) -> [SourceLocation: [IndexedReference]] {
            var result: [SourceLocation: [IndexedReference]] = [:]
            for reference in references where reference.origin == .compiler || reference.origin == .compilerAndSyntax {
                guard let location = reference.location, locations.contains(location) else { continue }
                result[location, default: []].append(reference)
            }
            return result
        }

        func declaration(at location: SourceLocation, kind: SymbolKind) -> IndexedSymbol? {
            let rows = (declarations[location] ?? []).filter {
                $0.kind == kind && !$0.usr.hasPrefix("cartograph:")
            }
            let ids = Set(rows.map(\.usr))
            guard ids.count == 1, let id = ids.first else { return nil }
            return symbols[id]
        }

        func inventory(_ raw: EnumInventorySyntaxFacts, fresh: Bool) -> EnumCaseInventory? {
            guard let owner = declaration(at: raw.nameLocation, kind: .enumType) else { return nil }
            var cases: [String] = []
            var limitations = raw.limitations
            for token in raw.cases {
                guard let value = declaration(at: token.location, kind: .enumCase),
                      value.parentUSR == owner.usr else {
                    limitations.append("unbound-enum-case-declaration")
                    continue
                }
                cases.append(value.usr)
            }
            let observed = caseUSRsByEnum[owner.usr] ?? []
            if observed != Set(cases) { limitations.append("incomplete-indexed-enum-inventory") }
            return .init(enumUSR: owner.usr, caseUSRs: cases, location: raw.nameLocation,
                complete: fresh && raw.isComplete && cases.count == raw.cases.count && limitations.isEmpty,
                limitations: limitations)
        }

        func caseReference(at location: SourceLocation) -> (usr: String, parent: String, owners: Set<String>)? {
            let rows = references[location] ?? []
            let ids = Set(rows.map(\.targetUSR))
            guard ids.count == 1, let id = ids.first, let symbol = symbols[id],
                  symbol.kind == .enumCase, let parent = symbol.parentUSR,
                  symbols[parent]?.kind == .enumType, !parent.hasPrefix("cartograph:")
            else { return nil }
            return (id, parent, Set(rows.map(\.sourceUSR)))
        }

        func subjectType(_ subject: EnumSubjectParameterSyntaxFacts?) -> (usr: String, owner: String)? {
            guard let subject else { return nil }
            let matches = (parameters[subject.parameterNameLocation] ?? []).filter {
                $0.name == subject.parameterName
            }
            let identities = Set(matches.map(\.usr))
            guard identities.count == 1, let parameter = matches.first,
                  let owner = symbols[parameter.functionUSR],
                  subject.functionRange.contains(owner.location),
                  subject.functionRange.contains(subject.subjectLocation) else { return nil }
            let refs = (references[subject.typeNameLocation] ?? []).filter {
                $0.sourceUSR == parameter.functionUSR
            }
            let targets = Set(refs.map(\.targetUSR))
            guard targets.count == 1, let usr = targets.first,
                  symbols[usr]?.kind == .enumType, !usr.hasPrefix("cartograph:") else { return nil }
            return (usr, parameter.functionUSR)
        }

        func callTargets(at location: SourceLocation?) -> Set<String> {
            guard let location else { return [] }
            return Set((references[location] ?? []).filter { $0.kind == .call }.map(\.targetUSR))
        }

        func decision(_ raw: EnumDecisionSyntaxFacts, fresh: Bool) -> EnumDecisionFact? {
            guard let kind = EnumDecisionFact.Kind(rawValue: raw.kind.rawValue) else { return nil }
            let membership = kind == .literalMembership || kind == .negatedLiteralMembership
            var explicit: [String] = []
            var guarded: [String] = []
            var parents: Set<String> = []
            var owners: Set<String> = []
            var evidence: [SourceLocation] = raw.fallbackLocations
                + [raw.operationLocation, raw.negationLocation].compactMap { $0 }
            var limitations = raw.limitations
            for (tokens, isGuarded) in [(raw.explicitCases, false), (raw.guardedCases, true)] {
                for token in tokens {
                    guard let bound = caseReference(at: token.location) else {
                        limitations.append("unbound-decision-case")
                        continue
                    }
                    parents.insert(bound.parent)
                    owners.formUnion(bound.owners)
                    evidence.append(token.location)
                    if isGuarded { guarded.append(bound.usr) } else { explicit.append(bound.usr) }
                }
            }
            let subject = subjectType(raw.subjectParameter)
            if let subject {
                parents.insert(subject.usr)
                owners.insert(subject.owner)
                if let rawSubject = raw.subjectParameter {
                    evidence += [rawSubject.subjectLocation, rawSubject.parameterNameLocation, rawSubject.typeNameLocation]
                }
            } else {
                limitations.append(membership ? "unverified-membership-argument-type" : "unverified-switch-subject-type")
            }
            if parents.count != 1 { limitations.append("unresolved-or-mixed-enum-identity") }
            var operationTargets = callTargets(at: raw.operationLocation)
            if membership {
                if operationTargets.count != 1 || !operationTargets.isSubset(of: Self.containsTargets) {
                    limitations.append("unsupported-or-unresolved-membership-target")
                }
                if kind == .negatedLiteralMembership {
                    let negation = callTargets(at: raw.negationLocation)
                    operationTargets.formUnion(negation)
                    if negation.count != 1 || !negation.isSubset(of: Self.negationTargets) {
                        limitations.append("unsupported-or-unresolved-negation-target")
                    }
                }
            }
            if !fresh { limitations.append("source-index-freshness-unverified") }
            let resolved = limitations.isEmpty
            if membership {
                // Even a known contains implementation may invoke custom Equatable.
                limitations.append("literal-set-identity-only: equality semantics and branch reachability are not established")
            }
            return .init(kind: kind, location: raw.range.start, endLocation: raw.range.end,
                enumUSR: parents.count == 1 ? parents.first : nil,
                ownerUSR: owners.count == 1 ? owners.first : nil,
                explicitCaseUSRs: explicit, guardedCaseUSRs: guarded,
                evidenceLocations: evidence, operationTargetUSRs: Array(operationTargets),
                status: resolved ? "resolved" : "unresolved", limitations: limitations)
        }
    }
}
