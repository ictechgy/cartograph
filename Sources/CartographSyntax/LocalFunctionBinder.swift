import CartographCore

/// 인덱스 소유자와 실제 지역 함수 참조 사슬이 모두 증명된 자리만 세분한다.
enum LocalFunctionBinder {
    private struct Use {
        let source: CartographCore.SourceLocation
        let target: CartographCore.SourceLocation
        let fact: LocalFunctionReferenceFacts
    }

    /// 구문 보강 결과와 각 미보강 지역 함수의 설명을 함께 돌려준다.
    struct Result {
        let snapshot: IndexSnapshot
        let diagnostics: [LocalFunctionDiagnostic]
    }

    /// 범위가 실제로 묻는 행만 담은 색인: 소유자·지역 함수 자리의 심볼, 유일한 소유자들의 참조, 이미 있는
    /// 소스 보완 선언의 USR. 프로젝트 전체를 위치·소스 USR 마다 묶으면 참조 100만 개에서 0.3초와 0.4GB 를 더 썼다.
    private struct BindingIndex {
        let byLocation: [SourceLocation: [IndexedSymbol]]
        let references: [String: [IndexedReference]]
        /// 지역 함수 키는 항상 소스 보완 이름 공간이라, 이미 있는 선언인지는 그 이름 공간의 USR 만 보면 된다.
        let localUSRs: Set<String>

        var indexedRows: Int {
            byLocation.values.map(\.count).reduce(0, +) + references.values.map(\.count).reduce(0, +)
                + localUSRs.count
        }
    }

    /// 색인은 바깥 타입이 만든다. 중첩 타입이 `owners` 를 부르면 타입 순환이 된다.
    private static func bindingIndex(_ snapshot: IndexSnapshot, scopes: [LocalFunctionScopeFacts]) -> BindingIndex {
        let locations = Set(scopes.flatMap { [$0.ownerLocation] + $0.functions.map(\.location) })
        var byLocation: [SourceLocation: [IndexedSymbol]] = [:]
        var localUSRs: Set<String> = []
        for symbol in snapshot.symbols {
            if locations.contains(symbol.location) { byLocation[symbol.location, default: []].append(symbol) }
            if SourceLocalSymbol.contains(symbol.usr) { localUSRs.insert(symbol.usr) }
        }
        let ownerUSRs = Set(scopes.compactMap { scope -> String? in
            let candidates = owners(for: scope, byLocation: byLocation)
            return candidates.count == 1 ? candidates.first?.usr : nil
        })
        var references: [String: [IndexedReference]] = [:]
        for reference in snapshot.references where ownerUSRs.contains(reference.sourceUSR) {
            references[reference.sourceUSR, default: []].append(reference)
        }
        return BindingIndex(byLocation: byLocation, references: references, localUSRs: localUSRs)
    }

    /// 컴파일러 투영을 정규화하고, 실제로 세분하지 못한 지역 함수를 설명한다.
    ///
    /// - Parameter onIndexedRows: 색인에 담은 행 수를 받는다. 테스트가 범위와 무관한 행을 색인하지 않는지 센다.
    static func enrichWithDiagnostics(
        _ input: IndexSnapshot,
        scopes: [LocalFunctionScopeFacts],
        freshPaths: Set<String>,
        edgeKinds: Set<EdgeKind>,
        freshnessFailures: [String: LocalFunctionSkipReason] = [:],
        onIndexedRows: ((Int) -> Void)? = nil
    ) -> Result {
        let snapshot = compilerProjection(input)
        let scopes = scopes.filter { !$0.functions.isEmpty }
        // 지역 함수가 하나도 없으면 아래 반복이 아무것도 바꾸지 않으므로 색인 없이 투영만 돌려준다.
        guard !scopes.isEmpty else {
            onIndexedRows?(0)
            return Result(snapshot: snapshot, diagnostics: [])
        }
        let index = bindingIndex(snapshot, scopes: scopes)
        onIndexedRows?(index.indexedRows)
        let byLocation = index.byLocation
        let references = index.references
        let filtered = edgeKinds.isEmpty || edgeKinds.isSuperset(of: [.call, .reference, .member])
            ? nil : LocalFunctionSkipReason.filteredEdgeKinds
        var additions: [IndexedSymbol] = []
        var localUses: [IndexedReference] = []
        var moved: [IndexedReference: String] = [:]
        var diagnostics: [LocalFunctionDiagnostic] = []

        for scope in scopes where !scope.functions.isEmpty {
            let owners = owners(for: scope, byLocation: byLocation)
            let owner = owners.count == 1 ? owners.first : nil

            if let failure = freshnessFailure(
                for: scope.ownerLocation.path,
                freshPaths: freshPaths,
                failures: freshnessFailures
            ) {
                diagnostics += Self.diagnostics(
                    for: scope,
                    reason: failure,
                    ownerUSR: owner?.usr
                )
                continue
            }
            if let filtered {
                diagnostics += Self.diagnostics(
                    for: scope,
                    reason: filtered,
                    ownerUSR: owner?.usr
                )
                continue
            }
            if scope.hasUnsupportedSyntax {
                let reason = scope.reason ?? .unsupportedSyntax
                diagnostics += scope.functions.compactMap { local in
                    let localReason = local.reason ?? reason
                    return LocalFunctionDiagnostic(
                        name: local.indexName,
                        location: local.location,
                        ownerName: scope.ownerName,
                        ownerUSR: owner?.usr,
                        reason: LocalFunctionSkipReason.preferred(localReason, reason) ?? reason
                    )
                }
                continue
            }
            guard let owner else {
                diagnostics += Self.diagnostics(
                    for: scope,
                    reason: .ambiguousOwner,
                    ownerUSR: nil
                )
                continue
            }

            let binding = bind(
                scope,
                owner: owner,
                references: references[owner.usr, default: []],
                byLocation: byLocation,
                localUSRs: index.localUSRs
            )
            additions += binding.symbols
            localUses += binding.uses
            moved.merge(binding.moved) { first, _ in first }
            let localsByLocation = Dictionary(grouping: scope.functions, by: \.location)
            diagnostics += binding.diagnostics.flatMap { location, reason in
                localsByLocation[location, default: []].map { local in
                    LocalFunctionDiagnostic(name: local.indexName, location: local.location,
                        ownerName: scope.ownerName, ownerUSR: owner.usr, reason: reason)
                }
            }
        }

        guard !additions.isEmpty else {
            return Result(snapshot: snapshot, diagnostics: normalized(diagnostics))
        }

        var result = snapshot
        result.symbols += additions.sorted { $0.usr < $1.usr }
        result.references = snapshot.references.map { reference in
            guard let owner = moved[reference] else { return reference }
            return IndexedReference(
                sourceUSR: owner,
                targetUSR: reference.targetUSR,
                kind: reference.kind,
                location: reference.location,
                targetKind: reference.targetKind,
                origin: movedOrigin(reference.origin),
                position: reference.position, receiverTypeUSR: reference.receiverTypeUSR
            )
        } + localUses
        return Result(snapshot: result, diagnostics: normalized(diagnostics))
    }

    private struct Binding {
        var symbols: [IndexedSymbol] = []
        var uses: [IndexedReference] = []
        var moved: [IndexedReference: String] = [:]
        var diagnostics: [SourceLocation: LocalFunctionSkipReason] = [:]

        mutating func diagnose(_ local: LocalFunctionFacts, _ reason: LocalFunctionSkipReason) {
            diagnostics[local.location] = LocalFunctionSkipReason.preferred(diagnostics[local.location], reason)
        }
    }

    private static func bind(
        _ scope: LocalFunctionScopeFacts,
        owner: IndexedSymbol,
        references: [IndexedReference],
        byLocation: [CartographCore.SourceLocation: [IndexedSymbol]],
        localUSRs: Set<String>
    ) -> Binding {
        let named = Dictionary(grouping: scope.functions, by: \.name)
        let candidates = scope.functions.filter {
            $0.isSupported
                && named[$0.name]?.count == 1
                && !scope.blockedNames.contains($0.name)
                && byLocation[$0.location] == nil
        }
        guard Set(candidates.map(\.location)).count == candidates.count else {
            var result = Binding()
            for local in scope.functions {
                if let reason = local.reason {
                    result.diagnose(local, reason)
                } else if !local.isSupported {
                    result.diagnose(local, .unsupportedSyntax)
                } else {
                    result.diagnose(local, .ambiguousName)
                }
            }
            return result
        }
        let candidateLocations = Set(candidates.map(\.location))
        let byName = Dictionary(uniqueKeysWithValues: candidates.map { ($0.name, $0) })
        let atSite = Dictionary(grouping: references.compactMap { reference -> (SourceLocation, IndexedReference)? in
            guard let location = reference.location else { return nil }
            return (location, reference)
        }, by: \.0).mapValues { $0.map(\.1) }
        let conflictLocations = Set(scope.references.compactMap { fact -> SourceLocation? in
            guard fact.isUnqualified, let local = byName[fact.name],
                  local.scopeStart <= fact.location, fact.location < local.scopeEnd,
                  atSite[fact.location] != nil else { return nil }
            return local.location
        })
        let uses: [Use] = scope.references.compactMap { fact in
            guard fact.isUnqualified, let local = byName[fact.name],
                  local.scopeStart <= fact.location, fact.location < local.scopeEnd,
                  atSite[fact.location] == nil else { return nil }
            return Use(
                source: fact.localOwner ?? scope.ownerLocation,
                target: local.location,
                fact: fact
            )
        }
        let selected = promoted(candidates, uses: uses, owner: scope.ownerLocation)
        let identifiers = Dictionary(uniqueKeysWithValues: candidates.filter {
            selected.contains($0.location)
        }.map {
            ($0.location, SourceLocalSymbol.identifier(
                ownerUSR: owner.usr,
                location: $0.location,
                name: $0.indexName
            ))
        })

        var result = Binding()
        var emitted: Set<SourceLocation> = []
        for local in candidates where selected.contains(local.location) {
            guard let usr = identifiers[local.location] else { continue }
            guard !localUSRs.contains(usr) else {
                result.diagnose(local, .existingDeclaration)
                continue
            }
            result.symbols.append(IndexedSymbol(
                usr: usr,
                name: local.indexName,
                kind: .function,
                module: owner.module,
                location: local.location,
                parentUSR: local.parentLocation.flatMap { identifiers[$0] } ?? owner.usr,
                accessibility: .privateLevel
            ))
            emitted.insert(local.location)
        }
        for use in uses where selected.contains(use.target) {
            guard let target = identifiers[use.target],
                  let source = use.source == scope.ownerLocation
                    ? owner.usr : identifiers[use.source]
            else { continue }
            result.uses.append(IndexedReference(
                sourceUSR: source,
                targetUSR: target,
                kind: use.fact.isCall ? .call : .reference,
                location: use.fact.location,
                origin: .syntax
            ))
        }
        let sourceSites = Dictionary(grouping: scope.references, by: \.location)
        for reference in references where reference.kind == .call || reference.kind == .reference {
            guard let location = reference.location,
                  let facts = sourceSites[location], facts.count == 1,
                  let fact = facts.first,
                  let local = fact.localOwner,
                  let usr = identifiers[local]
            else { continue }
            result.moved[reference] = usr
        }

        for local in scope.functions where !emitted.contains(local.location) {
            if let reason = local.reason {
                result.diagnose(local, reason)
            } else if !local.isSupported {
                result.diagnose(local, .unsupportedSyntax)
            } else if byLocation[local.location] != nil {
                result.diagnose(local, .existingDeclaration)
            } else if named[local.name]?.count != 1 {
                result.diagnose(local, .ambiguousName)
            } else if scope.blockedNames.contains(local.name) {
                result.diagnose(local, .shadowedName)
            } else if !candidateLocations.contains(local.location) {
                result.diagnose(local, .unsupportedSyntax)
            } else if conflictLocations.contains(local.location) {
                result.diagnose(local, .conflictingIndexReference)
            } else if !selected.contains(local.location) {
                result.diagnose(local, .noEntryChain)
            } else {
                result.diagnose(local, .existingDeclaration)
            }
        }
        return result
    }

    private static func owners(
        for scope: LocalFunctionScopeFacts,
        byLocation: [SourceLocation: [IndexedSymbol]]
    ) -> [IndexedSymbol] {
        byLocation[scope.ownerLocation, default: []].filter {
            [.function, .method, .initializer, .deinitializer].contains($0.kind)
                && GraphNode.baseName(ofIndexName: $0.name) == scope.ownerName
                && !$0.attributes.contains(.implicit)
                && !$0.isExternal
        }
    }

    private static func freshnessFailure(
        for path: String,
        freshPaths: Set<String>,
        failures: [String: LocalFunctionSkipReason]
    ) -> LocalFunctionSkipReason? {
        if let failure = failures[path] { return failure }
        return freshPaths.contains(path) ? nil : .sourceNotFresh
    }

    private static func diagnostics(
        for scope: LocalFunctionScopeFacts,
        reason: LocalFunctionSkipReason,
        ownerUSR: String?
    ) -> [LocalFunctionDiagnostic] {
        scope.functions.map {
            LocalFunctionDiagnostic(
                name: $0.indexName,
                location: $0.location,
                ownerName: scope.ownerName,
                ownerUSR: ownerUSR,
                reason: reason
            )
        }
    }

    /// 이미 보완한 스냅샷도 매번 원래 소유자에서 다시 시작한다. 소스가 낡아졌거나
    /// 필터가 달라졌을 때 과거의 구문 근거가 현재 사실처럼 남지 않게 한다.
    private static func compilerProjection(_ snapshot: IndexSnapshot) -> IndexSnapshot {
        let locals = snapshot.symbols.filter { SourceLocalSymbol.contains($0.usr) }
        guard !locals.isEmpty else { return snapshot }
        let byUSR = snapshot.symbolsByUSR()
        var owners: [String: String] = [:]
        for local in locals {
            var current = local.parentUSR
            var visited: Set<String> = [local.usr]
            while let usr = current, SourceLocalSymbol.contains(usr), visited.insert(usr).inserted {
                current = byUSR[usr]?.parentUSR
            }
            // 임의로 만든 불완전한 입력에는 컴파일러 소유자가 없다.
            guard let current, !SourceLocalSymbol.contains(current), byUSR[current] != nil else { return snapshot }
            owners[local.usr] = current
        }
        var result = snapshot
        result.symbols.removeAll { owners[$0.usr] != nil }
        result.references = snapshot.references.compactMap { reference in
            guard owners[reference.targetUSR] == nil else { return nil }
            guard let owner = owners[reference.sourceUSR] else { return reference }
            return IndexedReference(
                sourceUSR: owner,
                targetUSR: reference.targetUSR,
                kind: reference.kind,
                location: reference.location,
                targetKind: reference.targetKind,
                origin: restoredOrigin(reference.origin)
            )
        }
        return result
    }

    private static func movedOrigin(_ origin: ReferenceOrigin) -> ReferenceOrigin {
        origin == .compiler ? .compilerAndSyntax : origin
    }

    private static func restoredOrigin(_ origin: ReferenceOrigin) -> ReferenceOrigin {
        origin == .compilerAndSyntax ? .compiler : origin
    }

    private struct DiagnosticKey: Hashable {
        let name: String
        let location: SourceLocation
        let reason: LocalFunctionSkipReason
    }

    private static func normalized(_ diagnostics: [LocalFunctionDiagnostic]) -> [LocalFunctionDiagnostic] {
        var byKey: [DiagnosticKey: LocalFunctionDiagnostic] = [:]
        for diagnostic in diagnostics {
            let key = DiagnosticKey(
                name: diagnostic.name,
                location: diagnostic.location,
                reason: diagnostic.reason
            )
            guard let existing = byKey[key] else {
                byKey[key] = diagnostic
                continue
            }
            if existing.ownerUSR == nil, diagnostic.ownerUSR != nil {
                byKey[key] = diagnostic
            }
        }
        return byKey.values.sorted { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            if lhs.reason.rawValue != rhs.reason.rawValue {
                return lhs.reason.rawValue < rhs.reason.rawValue
            }
            return (lhs.ownerUSR ?? "") < (rhs.ownerUSR ?? "")
        }
    }

    /// 자기·상호 재귀만으로 살리지 않고 인덱스 소유자에서 시작하는
    /// 실제 참조 사슬을 따른다.
    private static func promoted(
        _ candidates: [LocalFunctionFacts],
        uses: [Use],
        owner: CartographCore.SourceLocation
    ) -> Set<CartographCore.SourceLocation> {
        let byLocation = Dictionary(uniqueKeysWithValues: candidates.map { ($0.location, $0) })
        let outgoing = Dictionary(grouping: uses, by: \.source).mapValues { $0.map(\.target) }
        var selected: Set<CartographCore.SourceLocation> = []
        var pending: [CartographCore.SourceLocation: Set<CartographCore.SourceLocation>] = [:]
        var queue = [owner]
        var head = 0
        while head < queue.count {
            let source = queue[head]
            head += 1
            let targets = outgoing[source, default: []]
                + (pending.removeValue(forKey: source) ?? []).sorted()
            for target in targets {
                guard let local = byLocation[target] else { continue }
                if let parent = local.parentLocation, !selected.contains(parent) {
                    pending[parent, default: []].insert(target)
                } else if selected.insert(target).inserted {
                    queue.append(target)
                }
            }
        }
        return selected
    }
}
