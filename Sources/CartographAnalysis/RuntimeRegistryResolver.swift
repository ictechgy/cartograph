import CartographCore

/// compiler가 확인한 Swift Dictionary registry 후보를 정적 연결로 결합한다.
///
/// 이 resolver는 registry 이름이나 함수 이름을 추측하지 않는다. 구문 위치의 reference,
/// 표준 Dictionary subscript USR, registry literal의 실제 함수 reference가 모두 맞을 때만
/// lookup을 factory로 확장한다. lookup은 실행 관측이 아니라 가능한 정적 의존성이다.
public struct RuntimeRegistryResolver: Sendable {
    /// 인덱스 근거를 확인하는 resolver를 만든다.
    public init() {}

    /// registry 경계를 현재 인덱스와 그래프에 대조한다.
    public func resolve(
        files: [RuntimeFileFacts],
        snapshot: IndexSnapshot,
        graph: CodeGraph,
        freshness: [String: RuntimeFreshness]
    ) -> RuntimeDiscoveryReport {
        let index = RuntimeRegistryIndex(files: files, snapshot: snapshot, graph: graph, freshness: freshness)
        let boundaries = files.flatMap(\.boundaries).filter { Self.registryKinds.contains($0.kind) }
        return RuntimeDiscoveryReport(
            findings: boundaries.map(index.resolve),
            limitations: files.flatMap(\.limitations)
        )
    }

    private static let registryKinds: Set<RuntimeBoundaryKind> = [
        .registryEntry, .registryLookup, .registryAlias,
    ]
}

private struct RuntimeRegistryIndex {
    private static let dictionarySubscriptUSRs: Set<String> = [
        // Swift 6.4 arm64 index: Dictionary<Key, Value>.subscript get/set.
        "s:SDyq_Sgxcig", "s:SDyq_Sgxcip",
    ]
    private static let dictionaryLiteralPrefix = "s:SD17dictionaryLiteral"
    private static let maxAliasDepth = 64

    private let graph: CodeGraph
    private let freshness: [String: RuntimeFreshness]
    private let referencesByLocation: [SourceLocation: [IndexedReference]]
    private let referencesBySource: [String: [IndexedReference]]
    private let symbolsByLocation: [SourceLocation: [IndexedSymbol]]
    private let entriesByDeclaration: [SourceLocation: [RuntimeBoundary]]
    private let aliasesByUSR: [String: RuntimeBoundary]

    init(
        files: [RuntimeFileFacts], snapshot: IndexSnapshot,
        graph: CodeGraph, freshness: [String: RuntimeFreshness]
    ) {
        self.graph = graph
        self.freshness = freshness
        let locatedReferences = snapshot.references.compactMap { reference in
            reference.location.map { (location: $0, reference: reference) }
        }
        let referencesByLocation = Dictionary(grouping: locatedReferences, by: \.location)
            .mapValues { $0.map(\.reference) }
        self.referencesByLocation = referencesByLocation
        referencesBySource = Dictionary(grouping: snapshot.references, by: \.sourceUSR)
        symbolsByLocation = Dictionary(grouping: snapshot.symbols, by: \.location)
        let entries = files.flatMap(\.boundaries).filter { $0.kind == .registryEntry }
        entriesByDeclaration = Dictionary(grouping: entries) { $0.registryDeclarationLocation ?? $0.location }
        let aliases = files.flatMap(\.boundaries).filter { $0.kind == .registryAlias }
        let aliasReferences = aliases.flatMap { alias in
            referencesByLocation[alias.registryReferenceLocation ?? alias.location, default: []].map {
                ($0.sourceUSR, alias)
            }
        }
        aliasesByUSR = Dictionary(aliasReferences, uniquingKeysWith: { first, _ in first })
    }

    func resolve(_ boundary: RuntimeBoundary) -> RuntimeDiscoveryFinding {
        guard let status = freshnessStatus(path: boundary.location.path) else {
            return resolveCurrent(boundary)
        }
        return finding(boundary, status, reason: "Rebuild this file before binding registry evidence.")
    }

    private func resolveCurrent(_ boundary: RuntimeBoundary) -> RuntimeDiscoveryFinding {
        switch boundary.kind {
        case .registryEntry: return entry(boundary)
        case .registryLookup: return lookup(boundary)
        case .registryAlias: return alias(boundary)
        default:
            return finding(boundary, .unindexed, reason: "The boundary is not a registry boundary.")
        }
    }

    private func entry(_ boundary: RuntimeBoundary) -> RuntimeDiscoveryFinding {
        guard boundary.name != nil, boundary.nameOrigin == .literal else {
            return finding(boundary, .dynamic, reason: "The registry entry key is not one literal string.")
        }
        guard let declarationLocation = boundary.registryDeclarationLocation else {
            return finding(boundary, .unindexed, reason: "The registry entry has no exact declaration location.")
        }
        let sameKeyEntries = entriesByDeclaration[declarationLocation, default: []].filter { $0.name == boundary.name }
        if sameKeyEntries.count > 1 {
            let candidates = sameKeyEntries.compactMap { namedFunctionTarget(at: $0.referencedTargetLocation) }
            return finding(boundary, .ambiguous, candidates: candidates,
                reason: "The registry literal contains duplicate keys.")
        }
        if let reason = boundary.reason {
            return finding(boundary, .unresolved, reason: reason)
        }
        guard let target = namedFunctionTarget(at: boundary.referencedTargetLocation) else {
            return finding(boundary, .unresolved, reason: "The registry value has no unique indexed named function.")
        }
        guard let registryUSR = uniqueDeclarationUSR(at: declarationLocation),
              hasDictionaryLiteralProof(registryUSR) else {
            return finding(boundary, .unresolved, candidates: [target],
                reason: "The registry declaration is not compiler-proven as a standard Dictionary literal.")
        }
        let source = graph.node(NodeID(registryUSR)) == nil ? nil : NodeID(registryUSR)
        return checked(boundary, source: source, targets: [target], status: .alreadyIndexed)
    }

    private func lookup(_ boundary: RuntimeBoundary) -> RuntimeDiscoveryFinding {
        guard let key = boundary.name, boundary.nameOrigin == .literal else {
            return finding(boundary, .dynamic, reason: "The registry lookup key is not one literal string.")
        }
        guard let declarationLocation = boundary.registryDeclarationLocation else {
            return finding(boundary, .unresolved, reason: boundary.reason ?? "The registry declaration is unresolved.")
        }
        if let reason = boundary.reason {
            return finding(boundary, .unresolved, reason: reason)
        }
        guard let subscriptLocation = boundary.calleeLocation,
              hasDictionarySubscriptProof(at: subscriptLocation) else {
            return finding(boundary, .unresolved,
                reason: "The lookup is not compiler-proven as a standard Dictionary subscript.")
        }
        guard let entry = uniqueEntry(key: key, declarationLocation: declarationLocation) else {
            let candidates = entriesByDeclaration[declarationLocation, default: []]
                .filter { $0.name == key }
                .compactMap { namedFunctionTarget(at: $0.referencedTargetLocation) }
            return finding(boundary, candidates.isEmpty ? .unresolved : .ambiguous,
                candidates: candidates, reason: "The registry key has no unique supported entry.")
        }
        guard entry.reason == nil,
              let target = namedFunctionTarget(at: entry.referencedTargetLocation) else {
            return finding(boundary, .unresolved, reason: entry.reason
                ?? "The registry value has no unique indexed named function.")
        }
        guard registryReferenceMatches(
            boundary.registryReferenceLocation, declarationLocation: declarationLocation
        ) else {
            return finding(boundary, .unresolved,
                reason: "The lookup reference does not identify the recorded registry declaration.")
        }
        let source = sourceOwner(at: boundary.registryReferenceLocation, boundary: boundary)
        guard let source else {
            return finding(boundary, .unresolved, candidates: [target],
                reason: "The registry lookup has no unique indexed caller.")
        }
        return checked(boundary, source: source, targets: [target])
    }

    private func alias(_ boundary: RuntimeBoundary) -> RuntimeDiscoveryFinding {
        guard let declarationLocation = boundary.registryDeclarationLocation,
              let referenceLocation = boundary.registryReferenceLocation else {
            return finding(boundary, .unresolved, reason: "The immutable registry alias has no exact reference chain.")
        }
        if let reason = boundary.reason {
            return finding(boundary, .unresolved, reason: reason)
        }
        guard registryReferenceMatches(referenceLocation, declarationLocation: declarationLocation) else {
            return finding(boundary, .unresolved,
                reason: "The alias reference does not identify the recorded registry declaration.")
        }
        guard let aliasUSR = uniqueDeclarationUSR(at: boundary.location),
              let targetUSR = uniqueDeclarationUSR(at: declarationLocation),
              let source = graph.node(NodeID(aliasUSR)), let target = graph.node(NodeID(targetUSR)) else {
            return finding(boundary, .unresolved, reason: "The alias declarations are not uniquely indexed.")
        }
        guard graph.outgoingEdges(from: source.id).contains(where: { $0.target == target.id }) else {
            return finding(boundary, .unresolved, reason: "The compiler did not record the alias reference.")
        }
        return checked(boundary, source: source.id, targets: [target.id], status: .alreadyIndexed)
    }

    private func uniqueEntry(key: String, declarationLocation: SourceLocation) -> RuntimeBoundary? {
        let entries = entriesByDeclaration[declarationLocation, default: []].filter { $0.name == key }
        return entries.count == 1 ? entries.first : nil
    }

    private func namedFunctionTarget(at location: SourceLocation?) -> NodeID? {
        guard let location else { return nil }
        let refs = referencesByLocation[location, default: []].filter { $0.kind == .reference }
        let targets = Set(refs.compactMap { reference -> NodeID? in
            let id = NodeID(reference.targetUSR)
            guard let node = graph.node(id), node.kind == .function, !node.isExternal else { return nil }
            return id
        })
        return targets.count == 1 ? targets.first : nil
    }

    private func uniqueDeclarationUSR(at location: SourceLocation) -> String? {
        let candidates = symbolsByLocation[location, default: []].filter {
            [.variable, .property].contains($0.kind) && !$0.isExternal
        }
        return candidates.count == 1 ? candidates[0].usr : nil
    }

    private func hasDictionaryLiteralProof(_ sourceUSR: String) -> Bool {
        referencesBySource[sourceUSR, default: []].contains {
            $0.targetUSR.hasPrefix(Self.dictionaryLiteralPrefix)
        }
    }

    private func hasDictionarySubscriptProof(at location: SourceLocation) -> Bool {
        let refs = referencesByLocation[location, default: []]
        return refs.contains { Self.dictionarySubscriptUSRs.contains($0.targetUSR) && $0.kind == .call }
            && refs.contains { Self.dictionarySubscriptUSRs.contains($0.targetUSR) && $0.kind == .reference }
    }

    private func registryReferenceMatches(
        _ location: SourceLocation?, declarationLocation: SourceLocation
    ) -> Bool {
        guard let location else { return false }
        let mapSources: Set<String> = Set(
            entriesByDeclaration[declarationLocation, default: []].flatMap { entry -> [String] in
            guard let valueLocation = entry.referencedTargetLocation else { return [] }
            return referencesByLocation[valueLocation, default: []].map(\.sourceUSR)
            }
        )
        guard !mapSources.isEmpty else { return false }
        var current = Set(referencesByLocation[location, default: []].map(\.targetUSR))
        var visited: Set<SourceLocation> = []
        for _ in 0..<Self.maxAliasDepth {
            if !current.isDisjoint(with: mapSources) { return true }
            let aliases = current.compactMap { aliasesByUSR[$0] }
            guard let alias = aliases.first, aliases.count == 1,
                  let aliasReference = alias.registryReferenceLocation,
                  visited.insert(aliasReference).inserted else { return false }
            current = Set(referencesByLocation[aliasReference, default: []].map(\.targetUSR))
        }
        return false
    }

    private func sourceOwner(at location: SourceLocation?, boundary: RuntimeBoundary) -> NodeID? {
        guard let location else { return nil }
        let refs = referencesByLocation[location, default: []].filter { [.call, .reference].contains($0.kind) }
        let sources = Set(refs.map { NodeID($0.sourceUSR) }).filter { graph.node($0) != nil }
        if let enclosing = boundary.enclosingDeclarationLocation {
            let exact = sources.filter { graph.node($0)?.location == enclosing }
            if exact.count == 1 { return exact.first }
        }
        let callable = sources.filter {
            graph.node($0).map { !$0.kind.isTypeDeclaration && $0.kind != .module } == true
        }
        return callable.count == 1 ? callable.first : nil
    }

    private func checked(
        _ boundary: RuntimeBoundary, source: NodeID?, targets: [NodeID],
        status: RuntimeDiscoveryStatus = .resolved
    ) -> RuntimeDiscoveryFinding {
        for target in targets {
            if let path = graph.node(target)?.location?.path, let targetStatus = freshnessStatus(path: path) {
                return finding(boundary, targetStatus, source: source, candidates: targets,
                    reason: "A registry target declaration is not backed by a current index unit.")
            }
        }
        return finding(boundary, status, source: source, targets: targets)
    }

    private func freshnessStatus(path: String) -> RuntimeDiscoveryStatus? {
        switch freshness[path] ?? .unknownIndexDate {
        case .fresh, .notApplicable: return nil
        case .sourceNewerThanIndex: return .stale
        default: return .unindexed
        }
    }

    private func finding(
        _ boundary: RuntimeBoundary, _ status: RuntimeDiscoveryStatus,
        source: NodeID? = nil, targets: [NodeID] = [], candidates: [NodeID] = [], reason: String? = nil
    ) -> RuntimeDiscoveryFinding {
        RuntimeDiscoveryFinding(
            boundary: boundary, status: status, source: source,
            targets: targets, candidates: candidates, reason: reason
        )
    }
}
