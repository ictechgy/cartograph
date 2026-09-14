import CartographCore

/// 실행 사건을 로컬 선언과 결합한 결과. 관측의 의미와 미해결 원인을 섞지 않는다.
public enum RuntimeTraceStatus: String, Codable, Sendable, CaseIterable {
    case observed
    case observedRegistration
    case lookupOnly
    case lookupFailed
    case unresolved
    case ambiguous
    case stale
    case unindexed
}

/// Kit에서 확인한 trace의 현재 입력에 대한 신뢰 상태.
public enum RuntimeTraceEvidenceState: Sendable, Equatable {
    case current
    case invalid(reason: String)
}

/// 원래 사건 순서와 로컬 그래프 결합 결과를 함께 보존한다.
public struct RuntimeTraceFinding: Codable, Sendable, Equatable {
    public let ordinal: Int
    public let event: RuntimeTraceEvent
    public let status: RuntimeTraceStatus
    public let source: NodeID?
    public let targets: [NodeID]
    public let candidates: [NodeID]
    public let reason: String?

    /// 실행 순서를 잃지 않으면서 확정 대상과 후보를 분리한다.
    public init(
        ordinal: Int,
        event: RuntimeTraceEvent,
        status: RuntimeTraceStatus,
        source: NodeID? = nil,
        targets: [NodeID] = [],
        candidates: [NodeID] = [],
        reason: String? = nil
    ) {
        self.ordinal = ordinal
        self.event = event
        self.status = status
        self.source = source
        self.targets = Array(Set(targets)).sorted()
        self.candidates = Array(Set(candidates)).sorted()
        self.reason = reason
    }
}

/// 같은 로컬 source-target에서 반복 관측한 실행 관계.
public struct RuntimeTraceConnection: Codable, Sendable, Equatable {
    public let source: NodeID
    public let target: NodeID
    public let kind: RuntimeBoundaryKind
    public let count: Int
    public let evidenceOrdinals: [Int]

    /// 중복 사건은 횟수와 원래 순서로 남겨 보고서 크기와 실행 근거를 함께 보존한다.
    public init(source: NodeID, target: NodeID, kind: RuntimeBoundaryKind, evidenceOrdinals: [Int]) {
        self.source = source
        self.target = target
        self.kind = kind
        self.evidenceOrdinals = Array(Set(evidenceOrdinals)).sorted()
        count = self.evidenceOrdinals.count
    }
}

/// 자동 수집 사건 전체와, 영향 분석에 더할 수 있는 정확한 로컬 관계.
public struct RuntimeTraceReport: Codable, Sendable, Equatable {
    public let findings: [RuntimeTraceFinding]
    public let connections: [RuntimeTraceConnection]
    public let limitations: [String]
    public let evidenceCurrent: Bool

    /// 사건은 ordinal 순서로, 관계는 source-target-kind 순서로 고정한다.
    public init(
        findings: [RuntimeTraceFinding],
        limitations: [String] = [],
        evidenceCurrent: Bool = true
    ) {
        self.findings = findings.sorted { $0.ordinal < $1.ordinal }
        connections = evidenceCurrent ? Self.connections(from: findings) : []
        self.limitations = Array(Set(limitations)).sorted()
        self.evidenceCurrent = evidenceCurrent
    }

    private static func connections(from findings: [RuntimeTraceFinding]) -> [RuntimeTraceConnection] {
        var ordinals: [ConnectionKey: [Int]] = [:]
        for finding in findings where finding.status == .observed || finding.status == .observedRegistration {
            guard let source = finding.source, let kind = kind(for: finding.event) else { continue }
            for target in finding.targets {
                ordinals[.init(source: source, target: target, kind: kind.rawValue), default: []]
                    .append(finding.ordinal)
            }
        }
        return ordinals.compactMap { key, evidence in
            guard let kind = RuntimeBoundaryKind(rawValue: key.kind) else { return nil }
            return RuntimeTraceConnection(
                source: key.source,
                target: key.target,
                kind: kind,
                evidenceOrdinals: evidence
            )
        }.sorted { lhs, rhs in
            (lhs.source.rawValue, lhs.target.rawValue, lhs.kind.rawValue)
                < (rhs.source.rawValue, rhs.target.rawValue, rhs.kind.rawValue)
        }
    }

    private static func kind(for event: RuntimeTraceEvent) -> RuntimeBoundaryKind? {
        switch (event.api, event.phase) {
        case ("NSClassFromString", "lookup"): .classLookup
        case ("NSProtocolFromString", "lookup"): .protocolLookup
        case (_, "invocation-returned"): .selectorInvocation
        case ("NotificationCenter.addObserver", "registration"): .selectorRegistration
        default: nil
        }
    }

    private struct ConnectionKey: Hashable {
        let source: NodeID
        let target: NodeID
        let kind: String
    }
}

/// 수집기가 본 런타임 이름을 현재 컴파일러 그래프의 정확한 선언 신원과 결합한다.
public struct RuntimeTraceResolver: Sendable {
    public init() {}

    /// 이름이 같다는 이유만으로 연결하지 않고, 수신자·selector·호출자 신원을
    /// 모두 확인한다.
    public func resolve(
        events: [RuntimeTraceEvent],
        files: [RuntimeFileFacts],
        snapshot: IndexSnapshot,
        graph: CodeGraph,
        freshness: [String: RuntimeFreshness],
        evidenceState: RuntimeTraceEvidenceState = .current
    ) -> RuntimeTraceReport {
        let index = RuntimeDiscoveryIndex(files: files, snapshot: snapshot, graph: graph, freshness: freshness)
        switch evidenceState {
        case .current:
            var cache = ResolutionCache(graph: graph)
            return RuntimeTraceReport(findings: events.enumerated().map {
                resolve($0.element, ordinal: $0.offset, index: index, cache: &cache)
            })
        case let .invalid(reason):
            return RuntimeTraceReport(
                findings: events.enumerated().map {
                    RuntimeTraceFinding(ordinal: $0.offset, event: $0.element, status: .stale, reason: reason)
                },
                limitations: [reason],
                evidenceCurrent: false
            )
        }
    }

    private func resolve(
        _ event: RuntimeTraceEvent,
        ordinal: Int,
        index: RuntimeDiscoveryIndex,
        cache: inout ResolutionCache
    ) -> RuntimeTraceFinding {
        let source = resolveSource(event.callerSymbol, index: index, cache: &cache)
        if event.dispatchUncertain == true {
            return finding(event, ordinal: ordinal, status: .unresolved, source: source.node,
                reason: "The receiver or method implementation changed during dispatch, or its identity was unavailable.")
        }
        switch (event.api, event.phase) {
        case ("NSClassFromString", "lookup"):
            return lookup(event, ordinal: ordinal, kind: .classType, source: source,
                index: index, cache: &cache)
        case ("NSProtocolFromString", "lookup"):
            return lookup(event, ordinal: ordinal, kind: .protocolType, source: source,
                index: index, cache: &cache)
        case ("NSSelectorFromString", "lookup"):
            let status: RuntimeTraceStatus = event.result.map { $0 ? .lookupOnly : .lookupFailed } ?? .unindexed
            return finding(
                event,
                ordinal: ordinal,
                status: status,
                source: source.node,
                reason: "Creating a selector token does not prove that any receiver invoked it."
            )
        case (_, "invocation-returned"):
            return selector(event, ordinal: ordinal, source: source, registration: false,
                index: index, cache: &cache)
        case ("NotificationCenter.addObserver", "registration"):
            return selector(event, ordinal: ordinal, source: source, registration: true,
                index: index, cache: &cache)
        default:
            return finding(
                event,
                ordinal: ordinal,
                status: .unindexed,
                source: source.node,
                reason: "The collector event is not an observed runtime dependency."
            )
        }
    }

    private func lookup(
        _ event: RuntimeTraceEvent,
        ordinal: Int,
        kind: SymbolKind,
        source: NodeResolution,
        index: RuntimeDiscoveryIndex,
        cache: inout ResolutionCache
    ) -> RuntimeTraceFinding {
        guard let lookupSucceeded = event.result else {
            return finding(event, ordinal: ordinal, status: .unindexed, source: source.node,
                reason: "The runtime lookup result is unavailable.")
        }
        guard lookupSucceeded else {
            return finding(
                event,
                ordinal: ordinal,
                status: .lookupFailed,
                source: source.node,
                reason: "The runtime lookup returned no class or protocol."
            )
        }
        guard let name = event.name else {
            return finding(event, ordinal: ordinal, status: .unresolved, source: source.node,
                reason: "The runtime lookup name is unavailable.")
        }
        let targets = cache.runtimeTypes(named: name, kind: kind, index: index)
        guard targets.count == 1, let target = targets.first else {
            return finding(
                event,
                ordinal: ordinal,
                status: targets.isEmpty ? .unresolved : .ambiguous,
                source: source.node,
                candidates: targets,
                reason: targets.isEmpty
                    ? "The observed runtime name has no exact local declaration."
                    : "The observed runtime name matches more than one local declaration."
            )
        }
        return connected(event, ordinal: ordinal, source: source, targets: [target], index: index)
    }

    private func selector(
        _ event: RuntimeTraceEvent,
        ordinal: Int,
        source: NodeResolution,
        registration: Bool,
        index: RuntimeDiscoveryIndex,
        cache: inout ResolutionCache
    ) -> RuntimeTraceFinding {
        guard event.result == true,
              let selector = event.name,
              let receiverName = event.receiverClass,
              let isClass = event.receiverIsClass
        else {
            return finding(event, ordinal: ordinal, status: .unresolved, source: source.node,
                reason: "The observed selector has no complete receiver identity.")
        }
        let receivers = cache.runtimeTypes(named: receiverName, kind: .classType, index: index)
        guard receivers.count == 1, let receiver = receivers.first else {
            return finding(
                event,
                ordinal: ordinal,
                status: receivers.isEmpty ? .unresolved : .ambiguous,
                source: source.node,
                candidates: receivers,
                reason: receivers.isEmpty
                    ? "The runtime receiver class has no exact local declaration."
                    : "The runtime receiver class is ambiguous in the local graph."
            )
        }
        if event.calleeSymbol != nil {
            let resolvedCallee = exactCallee(
                event.calleeSymbol,
                receiver: receiver,
                isClass: isClass,
                index: index,
                cache: &cache
            )
            let exact: [NodeID]
            if let resolvedCallee {
                exact = [resolvedCallee]
            } else if calleeSupportsIndexedFallback(
                event.calleeSymbol,
                selector: selector,
                receiver: receiver,
                isClass: isClass,
                index: index,
                cache: &cache
            ) {
                exact = objectiveCIndexedMethods(
                    named: selector,
                    receiver: receiver,
                    isClass: isClass,
                    index: index,
                    cache: cache
                )
            } else {
                exact = []
            }
            guard exact.count == 1 else {
                return finding(
                    event,
                    ordinal: ordinal,
                    status: exact.isEmpty ? .unresolved : .ambiguous,
                    source: source.node,
                    candidates: exact,
                    reason: exact.isEmpty
                        ? "The exact runtime implementation has no local compiler identity."
                        : "The exact runtime implementation maps to more than one local method."
                )
            }
            return connected(event, ordinal: ordinal, source: source, targets: exact,
                observedStatus: registration ? .observedRegistration : .observed,
                observedReason: registration
                    ? "The registration returned; this does not prove the callback was invoked."
                    : nil, index: index)
        }
        let targets = cache.runtimeMethods(
            named: selector,
            receiver: receiver,
            isClass: isClass,
            index: index
        )
        guard targets.count == 1 else {
            return finding(
                event,
                ordinal: ordinal,
                status: targets.isEmpty ? .unresolved : .ambiguous,
                source: source.node,
                candidates: targets,
                reason: targets.isEmpty
                    ? "The receiver has no exact method for the observed selector and dispatch kind."
                    : "The receiver has more than one nearest method for the observed selector."
            )
        }
        return connected(
            event,
            ordinal: ordinal,
            source: source,
            targets: targets,
            observedStatus: registration ? .observedRegistration : .observed,
            observedReason: registration
                ? "The registration returned; this does not prove the callback was invoked."
                : nil,
            index: index
        )
    }

    private func connected(
        _ event: RuntimeTraceEvent,
        ordinal: Int,
        source: NodeResolution,
        targets: [NodeID],
        observedStatus: RuntimeTraceStatus = .observed,
        observedReason: String? = nil,
        index: RuntimeDiscoveryIndex
    ) -> RuntimeTraceFinding {
        guard let sourceNode = source.node else {
            return finding(event, ordinal: ordinal, status: source.status, targets: targets, reason: source.reason)
        }
        if let status = freshnessStatus(of: sourceNode, index: index) {
            return finding(event, ordinal: ordinal, status: status, source: sourceNode, candidates: targets,
                reason: "The observed caller is not backed by a current local index unit.")
        }
        for target in targets {
            if let status = freshnessStatus(of: target, index: index) {
                return finding(event, ordinal: ordinal, status: status, source: sourceNode, candidates: targets,
                    reason: "An observed target is not backed by a current local index unit.")
            }
        }
        return finding(
            event,
            ordinal: ordinal,
            status: observedStatus,
            source: sourceNode,
            targets: targets,
            reason: observedReason
        )
    }

    private func resolveSource(
        _ symbol: String?,
        index: RuntimeDiscoveryIndex,
        cache: inout ResolutionCache
    ) -> NodeResolution {
        guard let symbol, !symbol.isEmpty else {
            return .unindexed("The collector could not identify an exact local caller symbol.")
        }
        if let cached = cache.sources[symbol] { return cached }
        let resolved = resolveUncachedSource(symbol, index: index, cache: &cache)
        cache.sources[symbol] = resolved
        return resolved
    }

    private func resolveUncachedSource(
        _ symbol: String,
        index: RuntimeDiscoveryIndex,
        cache: inout ResolutionCache
    ) -> NodeResolution {
        if let usr = swiftUSR(from: symbol), index.graph.node(NodeID(usr)) != nil {
            return .resolved(NodeID(usr))
        }
        if let objectiveC = objectiveCCaller(from: symbol) {
            let receivers = cache.runtimeTypes(named: objectiveC.receiver, kind: .classType, index: index)
            guard receivers.count == 1, let receiver = receivers.first else {
                return receivers.isEmpty
                    ? .unindexed("The Objective-C caller class is not in the local graph.")
                    : .ambiguous("The Objective-C caller class is ambiguous in the local graph.")
            }
            let methods = cache.runtimeMethods(
                named: objectiveC.selector,
                receiver: receiver,
                isClass: objectiveC.isClass,
                index: index
            )
            guard methods.count == 1, let method = methods.first else {
                return methods.isEmpty
                    ? .unindexed("The Objective-C caller method is not in the local graph.")
                    : .ambiguous("The Objective-C caller method is ambiguous in the local graph.")
            }
            return .resolved(method)
        }
        return .unindexed("The caller symbol is not an exact Swift USR or Objective-C method identity.")
    }

    private func exactCallee(
        _ symbol: String?,
        receiver: NodeID,
        isClass: Bool,
        index: RuntimeDiscoveryIndex,
        cache: inout ResolutionCache
    ) -> NodeID? {
        guard let symbol, !symbol.isEmpty else { return nil }
        var candidates: [NodeID] = []
        if let usr = swiftUSR(from: symbol) {
            candidates.append(NodeID(usr))
            if usr.hasSuffix("To") {
                candidates.append(NodeID(String(usr.dropLast(2))))
            }
        } else if let objectiveC = objectiveCCaller(from: symbol) {
            let receivers = cache.runtimeTypes(named: objectiveC.receiver, kind: .classType, index: index)
            guard receivers == [receiver], objectiveC.isClass == isClass else { return nil }
            let methods = cache.runtimeMethods(
                named: objectiveC.selector,
                receiver: receiver,
                isClass: isClass,
                index: index
            )
            return methods.count == 1 ? methods.first : nil
        }

        let distances = index.ancestorDistances(of: receiver)
        for candidate in candidates {
            guard index.graph.node(candidate) != nil,
                  let declaration = index.declarationByID[candidate],
                  [.method, .initializer].contains(declaration.node.kind),
                  declaration.fact.isStatic == isClass,
                  let owner = index.graph.semanticParent(of: candidate),
                  distances[owner] != nil
            else { continue }
            return candidate
        }
        return nil
    }

    private func calleeSupportsIndexedFallback(
        _ symbol: String?,
        selector: String,
        receiver: NodeID,
        isClass: Bool,
        index: RuntimeDiscoveryIndex,
        cache: inout ResolutionCache
    ) -> Bool {
        guard let symbol else { return false }
        if swiftUSR(from: symbol) != nil { return true }
        guard let objectiveC = objectiveCCaller(from: symbol),
              objectiveC.selector == selector,
              objectiveC.isClass == isClass
        else { return false }
        return cache.runtimeTypes(named: objectiveC.receiver, kind: .classType, index: index) == [receiver]
    }

    /// 실제 IMP가 정확히 symbolication된 사건에만 ObjC USR의 selector 부분을 사용한다.
    /// Swift base name을 selector로 추측하지 않고 컴파일러 USR 전체와 대조한다.
    private func objectiveCIndexedMethods(
        named selector: String,
        receiver: NodeID,
        isClass: Bool,
        index: RuntimeDiscoveryIndex,
        cache: ResolutionCache
    ) -> [NodeID] {
        let distances = index.ancestorDistances(of: receiver)
        let matches = (cache.objectiveCMethods[.init(selector: selector, isClass: isClass)] ?? []).compactMap {
            nodeID -> GraphNode? in
            guard let node = index.graph.node(nodeID),
                  let owner = index.graph.semanticParent(of: node.id) else { return nil }
            return distances[owner] != nil
                ? node
                : nil
        }
        let nearest = matches.compactMap { node in
            index.graph.semanticParent(of: node.id).flatMap { distances[$0] }
        }.min()
        return matches.filter { node in
            index.graph.semanticParent(of: node.id).flatMap { distances[$0] } == nearest
        }.map(\.id)
    }

    private func swiftUSR(from symbol: String) -> String? {
        if symbol.hasPrefix("_$s") {
            return "s:" + String(symbol.dropFirst(3))
        }
        if symbol.hasPrefix("$s") {
            return "s:" + String(symbol.dropFirst(2))
        }
        return nil
    }

    private func objectiveCCaller(from symbol: String) -> ObjectiveCCaller? {
        guard symbol.count >= 5,
              (symbol.hasPrefix("-[") || symbol.hasPrefix("+[")),
              symbol.hasSuffix("]")
        else { return nil }
        let body = symbol.dropFirst(2).dropLast()
        guard let separator = body.firstIndex(of: " ") else { return nil }
        let receiver = String(body[..<separator])
        let selector = String(body[body.index(after: separator)...])
        guard !receiver.isEmpty, !selector.isEmpty else { return nil }
        return ObjectiveCCaller(receiver: receiver, selector: selector, isClass: symbol.first == "+")
    }

    private func freshnessStatus(of node: NodeID, index: RuntimeDiscoveryIndex) -> RuntimeTraceStatus? {
        guard let path = index.graph.node(node)?.location?.path else { return .unindexed }
        switch index.freshness[path] ?? .unknownIndexDate {
        case .fresh, .notApplicable: return nil
        case .sourceNewerThanIndex: return .stale
        default: return .unindexed
        }
    }

    private func finding(
        _ event: RuntimeTraceEvent,
        ordinal: Int,
        status: RuntimeTraceStatus,
        source: NodeID? = nil,
        targets: [NodeID] = [],
        candidates: [NodeID] = [],
        reason: String? = nil
    ) -> RuntimeTraceFinding {
        RuntimeTraceFinding(
            ordinal: ordinal,
            event: event,
            status: status,
            source: source,
            targets: targets,
            candidates: candidates,
            reason: reason
        )
    }

    private struct ObjectiveCCaller {
        let receiver: String
        let selector: String
        let isClass: Bool
    }

    private struct NodeResolution {
        let node: NodeID?
        let status: RuntimeTraceStatus
        let reason: String?

        static func resolved(_ node: NodeID) -> NodeResolution {
            NodeResolution(node: node, status: .observed, reason: nil)
        }

        static func unindexed(_ reason: String) -> NodeResolution {
            NodeResolution(node: nil, status: .unindexed, reason: reason)
        }

        static func ambiguous(_ reason: String) -> NodeResolution {
            NodeResolution(node: nil, status: .ambiguous, reason: reason)
        }
    }

    private struct RuntimeTypeKey: Hashable {
        let name: String
        let kind: String
    }

    private struct RuntimeMethodKey: Hashable {
        let selector: String
        let receiver: NodeID
        let isClass: Bool
    }

    private struct ObjectiveCMethodKey: Hashable {
        let selector: String
        let isClass: Bool
    }

    private struct ResolutionCache {
        var sources: [String: NodeResolution] = [:]
        var types: [RuntimeTypeKey: [NodeID]] = [:]
        var methods: [RuntimeMethodKey: [NodeID]] = [:]
        let objectiveCMethods: [ObjectiveCMethodKey: [NodeID]]

        init(graph: CodeGraph) {
            var indexed: [ObjectiveCMethodKey: [NodeID]] = [:]
            for node in graph.sortedNodes {
                guard [.method, .initializer].contains(node.kind), let usr = node.usr else { continue }
                for (marker, isClass) in [("(im)", false), ("(cm)", true)] {
                    guard let range = usr.range(of: marker, options: .backwards) else { continue }
                    let selector = String(usr[range.upperBound...])
                    guard !selector.isEmpty else { continue }
                    indexed[.init(selector: selector, isClass: isClass), default: []].append(node.id)
                }
            }
            objectiveCMethods = indexed.mapValues { Array(Set($0)).sorted() }
        }

        mutating func runtimeTypes(
            named name: String,
            kind: SymbolKind,
            index: RuntimeDiscoveryIndex
        ) -> [NodeID] {
            let key = RuntimeTypeKey(name: name, kind: kind.rawValue)
            if let cached = types[key] { return cached }
            let resolved = index.runtimeTypes(named: name, kind: kind)
            types[key] = resolved
            return resolved
        }

        mutating func runtimeMethods(
            named selector: String,
            receiver: NodeID,
            isClass: Bool,
            index: RuntimeDiscoveryIndex
        ) -> [NodeID] {
            let key = RuntimeMethodKey(selector: selector, receiver: receiver, isClass: isClass)
            if let cached = methods[key] { return cached }
            let resolved = index.runtimeMethods(named: selector, receiver: receiver, isClass: isClass)
            methods[key] = resolved
            return resolved
        }
    }
}
