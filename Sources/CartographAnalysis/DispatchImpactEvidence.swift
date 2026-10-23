import CartographCore

/// A bounded refinement of static candidates, never a claim about runtime safety.
public struct ImpactReceiverPrecision: Sendable, Equatable, Codable {
    public let mode: String
    public let excludedTransitions: Int
    public let reason: String?
    public let stateBudget: Int
    public let transitionBudget: Int?
    public let examinedTransitions: Int?
    public let visitedStates: Int?
    public let exclusions: [Exclusion]?
    public let exclusionsOmitted: Int?

    public struct Exclusion: Sendable, Equatable, Codable, Hashable {
        public let caller: NodeID
        public let callee: NodeID
        public let requiredReceiver: NodeID
        public let observedReceivers: [String]
        public let locations: [SourceLocation]
        public let observedReceiversOmitted: Int?
        public let locationsOmitted: Int?
    }
}

extension ImpactReceiverPrecision {
    public var truncated: Bool {
        (exclusionsOmitted ?? 0) > 0 || (exclusions ?? []).contains {
            ($0.observedReceiversOmitted ?? 0) > 0 || ($0.locationsOmitted ?? 0) > 0
        }
    }

    public func limited(to limit: Int) -> Self {
        let cap = max(0, min(128, limit))
        let shown = (exclusions ?? []).prefix(cap).map { item in
            Exclusion(caller: item.caller, callee: item.callee, requiredReceiver: item.requiredReceiver,
                observedReceivers: Array(item.observedReceivers.prefix(cap)),
                locations: Array(item.locations.prefix(cap)),
                observedReceiversOmitted: omitted(item.observedReceivers.count, item.observedReceiversOmitted, cap),
                locationsOmitted: omitted(item.locations.count, item.locationsOmitted, cap))
        }
        return Self(mode: mode, excludedTransitions: excludedTransitions, reason: reason, stateBudget: stateBudget,
            transitionBudget: transitionBudget, examinedTransitions: examinedTransitions, visitedStates: visitedStates,
            exclusions: shown.isEmpty ? nil : shown,
            exclusionsOmitted: excludedTransitions > shown.count ? excludedTransitions - shown.count : nil)
    }

    public func fallingBack(reason: String) -> Self {
        Self(mode: "conservative-fallback", excludedTransitions: 0, reason: reason, stateBudget: stateBudget,
            transitionBudget: transitionBudget, examinedTransitions: examinedTransitions, visitedStates: visitedStates,
            exclusions: nil, exclusionsOmitted: nil)
    }

    private func omitted(_ count: Int, _ prior: Int?, _ cap: Int) -> Int? {
        let total = (prior ?? 0) + max(0, count - cap)
        return total > 0 ? total : nil
    }
}

/// Compiler receiver types alone do not identify `self`. The caller must supply
/// source files whose ephemeral joins were revalidated against the same bytes.
public struct DispatchImpactEvidence: Sendable {
    private struct Pair: Hashable { let caller: String; let callee: String }
    private let calls: [Pair: [IndexedReference]]
    private let selfCalls: Set<SelfReceiverCall>
    private let finalClasses: Set<String>
    private let symbols: [String: IndexedSymbol]
    private let freshPaths: Set<String>

    public init(snapshot: IndexSnapshot, verifiedSourcePaths: Set<String>) {
        let files = (snapshot.dispatchReceiverFiles ?? []).filter { verifiedSourcePaths.contains($0.path) }
        freshPaths = Set(files.map(\.path))
        selfCalls = Set(files.flatMap(\.selfCalls))
        finalClasses = Set(files.flatMap(\.finalClassUSRs))
        symbols = snapshot.symbolsByUSR()
        // Keep all observed calls, including unknown origins/locations. One good
        // occurrence cannot certify another occurrence of the same graph edge.
        calls = Dictionary(grouping: snapshot.references.filter { $0.kind != .member },
            by: { Pair(caller: $0.sourceUSR, callee: $0.targetUSR) })
    }

    func finalOwner(of method: NodeID) -> NodeID? {
        guard let symbol = symbols[method.rawValue], safe(symbol), symbol.kind == .method,
              let owner = symbol.parentUSR, finalClasses.contains(owner),
              let type = symbols[owner], safe(type), type.kind == .classType else { return nil }
        return NodeID(owner)
    }

    private func safe(_ symbol: IndexedSymbol) -> Bool {
        !symbol.isExternal && symbol.usr.hasPrefix("s:") && freshPaths.contains(symbol.location.path)
            && !symbol.attributes.contains(where: {
                $0.isObjectiveCRelated || [.dynamicDispatch, .dynamicReplacement, .runtimeManaged,
                    .implicit, .sourceUnavailable].contains($0)
            })
    }

    func exclusion(_ visit: ImpactVisit, requiring receiver: NodeID) -> ImpactReceiverPrecision.Exclusion {
        let target = visit.dispatchContract ?? visit.via
        let observed = calls[Pair(caller: visit.node.rawValue, callee: target.rawValue)] ?? []
        let receivers = Set(observed.compactMap(\.receiverTypeUSR)).sorted()
        let locations = Set(observed.compactMap(\.location)).sorted()
        return .init(caller: visit.node, callee: target, requiredReceiver: receiver,
            observedReceivers: Array(receivers.prefix(128)), locations: Array(locations.prefix(128)),
            observedReceiversOmitted: receivers.count > 128 ? receivers.count - 128 : nil,
            locationsOmitted: locations.count > 128 ? locations.count - 128 : nil)
    }

    enum Transition { case unknown, sameInstance, disjoint }

    func transition(_ visit: ImpactVisit, requiring receiver: NodeID) -> Transition {
        let target = visit.dispatchContract ?? visit.via
        let kinds = Set(visit.edges).subtracting(visit.relationship == .dispatchCaller ? [.overrides] : [])
        guard kinds == [.call], [.dependent, .dispatchCaller].contains(visit.relationship),
              let targetSymbol = symbols[target.rawValue], safe(targetSymbol),
              let occurrences = calls[Pair(caller: visit.node.rawValue, callee: target.rawValue)],
              !occurrences.isEmpty,
              occurrences.allSatisfy({ $0.kind == .call && $0.origin == .compiler && $0.location.map {
                  freshPaths.contains($0.path)
              } == true }) else { return .unknown }
        if occurrences.allSatisfy({ reference in
            guard let type = reference.receiverTypeUSR, type != receiver.rawValue,
                  finalClasses.contains(type), let symbol = symbols[type], safe(symbol)
            else { return false }
            return true
        }) { return .disjoint }
        if occurrences.allSatisfy({ reference in
            guard reference.receiverTypeUSR != nil, let location = reference.location else { return false }
            return selfCalls.contains(SelfReceiverCall(callerUSR: reference.sourceUSR,
                calleeUSR: reference.targetUSR, location: location))
        }) { return .sameInstance }
        return .unknown
    }
}

extension ImpactAnalyzer {
    /// Keep receiver state separate from node identity. If distinct states merge,
    /// the existing node-only `via` format cannot express both paths faithfully;
    /// fall back for the whole request rather than dropping an unknown path.
    func analyzeReceivers(changing: Set<NodeID>, in graph: CodeGraph, maxDepth: Int?,
                          dependencies: [ImpactDependency], evidence: DispatchImpactEvidence,
                          stateBudget: Int) -> ImpactReport {
        struct State: Hashable { let node: NodeID; let receiver: NodeID? }
        let stateBudget = max(1, min(50_000, stateBudget))
        // Distinct states do not bound repeated witness-to-contract projections.
        // Charge every candidate, including revisits and excluded transitions.
        let transitionBudget = stateBudget * 4
        var examinedTransitions = 0
        var visitedStates = 0
        func fallback(_ reason: String) -> ImpactReport {
            let original = analyze(changing: changing, in: graph, maxDepth: maxDepth,
                additionalDependencies: dependencies)
            return ImpactReport(changed: original.changed, affected: original.affected,
                truncatedByDepth: original.truncatedByDepth,
                receiverPrecision: .init(mode: "conservative-fallback", excludedTransitions: 0,
                    reason: reason, stateBudget: stateBudget, transitionBudget: transitionBudget,
                    examinedTransitions: examinedTransitions, visitedStates: visitedStates,
                    exclusions: nil, exclusionsOmitted: nil))
        }
        let runtime = Dictionary(grouping: dependencies.filter {
            graph.contains($0.source) && graph.contains($0.target)
        }, by: \.target)
        let initial = changing.sorted().filter(graph.contains).map { State(node: $0, receiver: nil) }
        visitedStates = initial.count
        guard initial.count <= stateBudget else { return fallback("receiver-state-budget") }
        var frontier = initial
        var seen = Set(initial)
        var statesByNode = Dictionary(uniqueKeysWithValues: initial.map { ($0.node, $0) })
        var visits: [NodeID: ImpactVisit] = [:]
        var depth = 0
        var excluded = 0
        var exclusions: [ImpactReceiverPrecision.Exclusion] = []
        var truncated = false
        let depthLimit = maxDepth.map { max(0, $0) }
        while !frontier.isEmpty {
            var next: [State] = []
            for state in frontier {
                for candidate in receiverCandidates(from: state.node, depth: depth, graph: graph, runtime: runtime) {
                    guard examinedTransitions < transitionBudget else {
                        return fallback("receiver-transition-budget")
                    }
                    examinedTransitions += 1
                    let required = candidate.relationship == .dispatchCaller
                        ? evidence.finalOwner(of: state.node) : state.receiver
                    var propagated: NodeID?
                    if let required {
                        switch evidence.transition(candidate, requiring: required) {
                        case .disjoint:
                            excluded += 1
                            if exclusions.count < 128 {
                                exclusions.append(evidence.exclusion(candidate, requiring: required))
                            }
                            continue
                        case .sameInstance: propagated = required
                        case .unknown: propagated = nil
                        }
                    }
                    let proposed = State(node: candidate.node, receiver: propagated)
                    // Seeds are unknown too. A constrained revisit of a base seed
                    // must not overwrite the independent reason it was selected.
                    if let prior = statesByNode[proposed.node], prior != proposed {
                        return fallback("receiver-state-convergence")
                    }
                    if seen.contains(proposed) { continue }
                    if let depthLimit, depth >= depthLimit { truncated = true; continue }
                    guard seen.count < stateBudget else { return fallback("receiver-state-budget") }
                    seen.insert(proposed)
                    visitedStates = seen.count
                    statesByNode[proposed.node] = proposed
                    visits[proposed.node] = candidate
                    next.append(proposed)
                }
            }
            frontier = next.sorted { $0.node < $1.node }
            depth += 1
        }
        return ImpactReport(changed: changing.sorted(), affected: visits.values.sorted(by: Self.visitPrecedes),
            truncatedByDepth: truncated,
            receiverPrecision: .init(mode: excluded > 0 ? "bounded-final-self" : "conservative-no-exclusion", excludedTransitions: excluded,
                reason: "Only fresh exact self calls and distinct final Swift receiver types are refined; aliases, nonfinal and runtime paths remain conservative.",
                stateBudget: stateBudget, transitionBudget: transitionBudget,
                examinedTransitions: examinedTransitions, visitedStates: visitedStates, exclusions: exclusions.isEmpty ? nil : exclusions,
                exclusionsOmitted: excluded > exclusions.count ? excluded - exclusions.count : nil))
    }
}
