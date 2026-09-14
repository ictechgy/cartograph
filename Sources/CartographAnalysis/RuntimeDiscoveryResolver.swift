import CartographCore

/// 구문에서 본 런타임 경계를 정확한 컴파일러 참조·선언 신원에 결합한다.
public struct RuntimeDiscoveryResolver: Sendable {
    public init() {}

    /// 인덱스와 같은 상태의 경계만 정적 연결로 인정한다.
    public func resolve(files: [RuntimeFileFacts], snapshot: IndexSnapshot, graph: CodeGraph,
                        freshness: [String: RuntimeFreshness]) -> RuntimeDiscoveryReport {
        let index = RuntimeDiscoveryIndex(files: files, snapshot: snapshot, graph: graph, freshness: freshness)
        let boundaries = files.flatMap(\.boundaries)
        let registryKinds: Set<RuntimeBoundaryKind> = [.registryEntry, .registryLookup, .registryAlias]
        let coreDataKinds: Set<RuntimeBoundaryKind> = [.coreDataContainer, .coreDataFetch]
        let entities = boundaries.filter { $0.kind == .coreDataEntityClass }.map { index.resolve($0) }
        let coreData = boundaries.contains { coreDataKinds.contains($0.kind) }
            ? CoreDataRuntimeBinder(entityFindings: entities, snapshot: snapshot, graph: graph) : nil
        let ordinary = boundaries.filter { $0.kind != .coreDataEntityClass && !registryKinds.contains($0.kind) }
            .map { index.resolve($0, coreData: coreData) }
        let registries = boundaries.contains { registryKinds.contains($0.kind) }
            ? RuntimeRegistryResolver().resolve(files: files, snapshot: snapshot, graph: graph, freshness: freshness)
                .findings : []
        let findings = entities + ordinary + registries
        return RuntimeDiscoveryReport(findings: index.joinNotifications(findings),
            limitations: files.flatMap(\.limitations))
    }
}

/// 소스 위치와 노출 이름 색인을 한 번 만들어 경계마다 전체 그래프를 순회하지 않는다.
struct RuntimeDiscoveryIndex {
    struct Declaration {
        let fact: RuntimeDeclaration
        let node: GraphNode
    }

    let graph: CodeGraph
    let freshness: [String: RuntimeFreshness]
    let references: [SourceLocation: [IndexedReference]]
    let declarations: [Declaration]
    let declarationByID: [NodeID: Declaration]
    let managedObjectClasses: Set<NodeID>
    let nsObjectClasses: Set<NodeID>
    let graphNodesByLocation: [SourceLocation: [GraphNode]]

    init(files: [RuntimeFileFacts], snapshot: IndexSnapshot, graph: CodeGraph,
         freshness: [String: RuntimeFreshness]) {
        self.graph = graph
        self.freshness = freshness
        graphNodesByLocation = Dictionary(grouping: graph.sortedNodes.filter { $0.location != nil }) { $0.location! }
        references = Dictionary(grouping: snapshot.references.filter { $0.location != nil }) { $0.location! }
        let byLocation = Dictionary(grouping: snapshot.symbols, by: \.location)
        declarations = files.flatMap(\.declarations).compactMap { fact in
            let candidates = (byLocation[fact.location] ?? []).filter {
                $0.name == fact.indexName && $0.kind == fact.kind && !$0.isExternal
            }
            let swift = candidates.filter { !$0.usr.hasPrefix("c:") }
            let preferred = swift.isEmpty ? candidates : swift
            let ids = Set(preferred.map(\.usr))
            guard ids.count == 1, let usr = ids.first, let node = graph.node(NodeID(usr)) else { return nil }
            return Declaration(fact: fact, node: node)
        }
        declarationByID = Dictionary(declarations.map { ($0.node.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var managed = Set(snapshot.references.compactMap { reference -> NodeID? in
            guard reference.kind == .inheritance,
                  Self.isManagedObjectUSR(reference.targetUSR),
                  graph.node(NodeID(reference.sourceUSR)) != nil
            else { return nil }
            return NodeID(reference.sourceUSR)
        })
        var queue = Array(managed)
        while let base = queue.popLast() {
            for edge in graph.incomingEdges(to: base) where edge.kind == .inheritance {
                if managed.insert(edge.source).inserted { queue.append(edge.source) }
            }
        }
        managedObjectClasses = managed
        nsObjectClasses = Self.inheritedClasses(
            snapshot: snapshot,
            graph: graph,
            externalBaseUSRs: ["c:objc(cs)NSObject", "s:So8NSObjectC"]
        )
    }

    func resolve(_ boundary: RuntimeBoundary, coreData: CoreDataRuntimeBinder? = nil) -> RuntimeDiscoveryFinding {
        let resource = boundary.nameOrigin == .resource || boundary.nameOrigin == .bridge
        if !resource, let status = freshnessStatus(path: boundary.location.path) {
            return finding(boundary, status, reason: "Rebuild this file before binding runtime evidence.")
        }
        if let reason = boundary.reason, resource {
            return finding(boundary, .unresolved, reason: reason)
        }
        if boundary.kind == .selectorReference { return selectorReference(boundary) }
        var source: NodeID?
        if !resource {
            guard let location = boundary.calleeLocation else {
                return finding(boundary, .unindexed, reason: "The API call has no compiler anchor.")
            }
            // 최상위 코드는 합성 entry point에서 reference로 연결되기도 한다. 구문이 실제 호출을
            // 확인했으므로 같은 위치의 시스템 함수 reference도 신원 근거로 쓸 수 있다.
            let calls = (references[location] ?? []).filter { $0.kind == .call || $0.kind == .reference }
            let accepted = calls.filter {
                graph.node(NodeID($0.targetUSR)) == nil
                    && RuntimeSystemAPI.accepts($0.targetUSR, kind: boundary.kind)
            }
            guard !accepted.isEmpty else {
                let owners = sourceOwners(calls, boundary: boundary)
                return finding(boundary, calls.isEmpty ? .unindexed : .shadowed,
                    source: owners.count == 1 ? owners.first : lexicalOwnerForDiagnostic(boundary),
                    reason: "The compiler did not resolve this call to a supported system API.")
            }
            let sources = sourceOwners(accepted, boundary: boundary)
            guard sources.count == 1 else {
                return finding(boundary, .unindexed, reason: "The API call has no unique indexed owner.")
            }
            source = sources.first
            for proof in boundary.nameAPIReferences ?? [] {
                let refs = references[proof.location] ?? []
                guard refs.contains(where: {
                    graph.node(NodeID($0.targetUSR)) == nil && RuntimeSystemAPI.acceptsNameProof($0.targetUSR, api: proof.api)
                }) else {
                    return finding(boundary, refs.isEmpty ? .unindexed : .shadowed, source: source,
                        reason: "A name-building operation did not resolve to the expected system implementation.")
                }
            }
        }
        switch boundary.kind {
        case .classLookup, .protocolLookup, .interfaceBuilderClass:
            return classLookup(boundary, source: source)
        case .selectorLookup:
            return finding(boundary, boundary.name == nil ? .dynamic : .lookupOnly, source: source,
                reason: "Creating a selector token is not evidence of a method invocation.")
        case .selectorInvocation, .selectorRegistration, .interfaceBuilderAction, .interfaceBuilderOutlet:
            return member(boundary, source: source)
        case .notificationObserver:
            if boundary.receiverOrigin == .explicitTarget {
                return member(boundary, source: source)
            }
            guard notificationKey(boundary) != nil else { return finding(boundary, .dynamic, source: source) }
            // 클로저 USR이 없으면 등록을 담은 선언을 명시적 callback container로 사용한다.
            return finding(boundary, .resolved, source: source, targets: source.map { [$0] } ?? [],
                reason: "The callback is contained in the registration declaration.")
        case .notificationPost:
            return finding(boundary, notificationKey(boundary) == nil ? .dynamic : .unresolved, source: source,
                reason: "No statically matched observer is in the analyzed scope.")
        case .notificationSubscription:
            return notificationSubscription(boundary, source: source)
        case .coreDataEntityClass:
            return coreDataEntityClass(boundary)
        case .coreDataContainer, .coreDataFetch:
            return coreData?.resolve(boundary, source: source)
                ?? finding(boundary, .unresolved, source: source,
                    reason: "This boundary needs verified model binding evidence.")
        case .registryEntry, .registryLookup, .registryAlias:
            return finding(boundary, .unresolved, source: source,
                reason: "This boundary needs a verified registry or model binding.")
        case .keyValueRead, .keyValueWrite:
            return keyValueAccess(boundary, source: source)
        case .keyPathRead, .keyPathWrite:
            return keyPathAccess(boundary, source: source)
        case .bridgeHandler:
            guard let usr = boundary.targetUSR, graph.node(NodeID(usr)) != nil else {
                return finding(boundary, .unresolved, reason: "The bridge has no exact indexed handler.")
            }
            return checked(boundary, source: nil, targets: [NodeID(usr)])
        case .selectorReference:
            return selectorReference(boundary)
        }
    }

    private func classLookup(_ boundary: RuntimeBoundary, source: NodeID?) -> RuntimeDiscoveryFinding {
        guard let name = boundary.name else { return finding(boundary, .dynamic, source: source) }
        let kind: SymbolKind = boundary.kind == .protocolLookup ? .protocolType : .classType
        let targets = boundary.kind == .interfaceBuilderClass
            ? declarations.filter { $0.node.kind == kind && matchesType(boundary.receiverTypeName ?? name, $0) }
                .map(\.node.id)
            : runtimeTypes(named: name, kind: kind)
        guard Set(targets).count == 1 else {
            return finding(boundary, targets.isEmpty ? .unresolved : .ambiguous, source: source,
                candidates: targets, reason: "The runtime class/protocol name has no unique local declaration.")
        }
        return checked(boundary, source: source, targets: targets)
    }

    private func notificationSubscription(
        _ boundary: RuntimeBoundary,
        source: NodeID?
    ) -> RuntimeDiscoveryFinding {
        guard notificationKey(boundary) != nil else {
            return finding(boundary, .dynamic, source: source,
                reason: "The notification name has no unique compiler-confirmed identity.")
        }
        guard notificationCenterIdentity(boundary) != nil else {
            return finding(boundary, .unresolved, source: source,
                reason: "The notification center has no supported stable or local identity proof.")
        }
        if boundary.api == "publisher" {
            guard let consumer = boundary.subscriptionConsumer else {
                return finding(boundary, .lookupOnly, source: source,
                    reason: "The compiler confirmed publisher construction; no supported consumer was proven.")
            }
            let references = (references[consumer.location] ?? []).filter {
                $0.kind == .call || $0.kind == .reference
            }
            let accepted = references.filter {
                graph.node(NodeID($0.targetUSR)) == nil
                    && RuntimeSystemAPI.acceptsSubscriptionConsumer($0.targetUSR, api: consumer.api)
            }
            guard !accepted.isEmpty else {
                return finding(boundary, references.isEmpty ? .unindexed : .shadowed, source: source,
                    reason: "The publisher consumer did not resolve to a supported system API.")
            }
            let owners = sourceOwners(accepted, boundary: boundary)
            guard owners.count == 1, owners.first == source else {
                return finding(boundary, .unindexed, source: source,
                    reason: "The publisher and its consumer have no single compiler-confirmed owner.")
            }
            return finding(boundary, .resolved, source: source,
                reason: "The compiler confirmed a potential subscription site; callback execution was not observed.")
        }
        if boundary.api == "notifications" {
            guard let consumer = boundary.subscriptionConsumer, consumer.api == "for-await" else {
                return finding(boundary, .lookupOnly, source: source,
                    reason: "The async notification sequence has no direct for-await consumer.")
            }
            let iteration = (references[consumer.location] ?? []).filter {
                $0.kind == .call || $0.kind == .reference
            }
            guard RuntimeSystemAPI.confirmsAsyncNotificationIteration(iteration.map(\.targetUSR)) else {
                return finding(boundary, iteration.isEmpty ? .unindexed : .shadowed, source: source,
                    reason: "The compiler did not confirm NotificationCenter async iteration.")
            }
            let owners = sourceOwners(iteration, boundary: boundary)
            guard owners.count == 1, owners.first == source else {
                return finding(boundary, .unindexed, source: source,
                    reason: "The async sequence and iteration have no single compiler-confirmed owner.")
            }
            return finding(boundary, .resolved, source: source,
                reason: "The compiler confirmed a potential async subscription; iteration was not observed.")
        }
        return finding(boundary, .resolved, source: source,
            reason: "The compiler confirmed a supported registration site; callback execution was not observed.")
    }

    private func coreDataEntityClass(_ boundary: RuntimeBoundary) -> RuntimeDiscoveryFinding {
        guard let name = boundary.receiverTypeName ?? boundary.name else {
            return finding(boundary, .unresolved, reason: "The Core Data entity has no represented class.")
        }
        let matching = declarations.filter {
            $0.node.kind == .classType && matchesType(name, $0)
        }
        guard matching.count <= 1 else {
            return finding(boundary, .ambiguous, candidates: matching.map(\.node.id),
                reason: "The represented class is ambiguous across indexed modules.")
        }
        let managed = matching.filter { managedObjectClasses.contains($0.node.id) }
        guard managed.count == 1, let target = managed.first else {
            let reason = matching.isEmpty
                ? "The represented class does not exist in the indexed Swift sources."
                : "The represented class is not an indexed NSManagedObject subclass."
            return finding(boundary, .unresolved, candidates: matching.map(\.node.id), reason: reason)
        }
        guard runtimeTypes(named: name).contains(target.node.id) else {
            return finding(boundary, .unresolved, candidates: [target.node.id],
                reason: "The represented class needs an Objective-C runtime name or a module-qualified Swift name.")
        }
        if boundary.coreDataCodeGeneration == "category" {
            let extensionName = name.split(separator: ".").last.map(String.init)
            guard target.fact.qualifiedName == target.fact.name, extensionName == target.fact.name else {
                return finding(boundary, .unresolved, candidates: [target.node.id],
                    reason: "The generated Core Data extension does not name the indexed Swift class.")
            }
        }
        return checked(boundary, source: nil, targets: [target.node.id])
    }

    private func keyValueAccess(
        _ boundary: RuntimeBoundary,
        source: NodeID?
    ) -> RuntimeDiscoveryFinding {
        guard let key = boundary.name, !key.isEmpty, !key.contains(".") else {
            return finding(boundary, .dynamic, source: source,
                reason: "KVC requires one literal key without a key path.")
        }
        let receivers = receiverTypes(boundary)
        guard receivers.count == 1, let receiver = receivers.first,
              let receiverDeclaration = declarationByID[receiver], receiverDeclaration.fact.isFinal,
              nsObjectClasses.contains(receiver)
        else {
            return finding(boundary, receivers.count > 1 ? .ambiguous : .unresolved, source: source,
                reason: "KVC receiver must be one compiler-confirmed final NSObject subclass.")
        }
        let ancestors = Set(ancestorDistances(of: receiver).keys)
        if hasKeyValueOverrideOrAlternateAccessor(
            key: key,
            kind: boundary.kind,
            owners: ancestors
        ) {
            return finding(boundary, .unresolved, source: source,
                reason: "A KVC override or higher-priority accessor changes key dispatch.")
        }
        let properties = declarations.filter { declaration in
            guard declaration.node.kind == .property,
                  declaration.fact.attributes.contains(.objc),
                  declaration.fact.objectiveCName == key,
                  !declaration.fact.isStatic,
                  let owner = graph.semanticParent(of: declaration.node.id), ancestors.contains(owner)
            else { return false }
            return true
        }
        guard properties.count == 1, let property = properties.first else {
            return finding(boundary, properties.count > 1 ? .ambiguous : .unresolved, source: source,
                candidates: properties.map(\.node.id),
                reason: "KVC key has no unique explicit @objc property on the receiver hierarchy.")
        }
        if boundary.kind == .keyValueWrite {
            guard !property.fact.isImmutable else {
                return finding(boundary, .unresolved, source: source, candidates: [property.node.id],
                    reason: "KVC write cannot target an immutable Swift property.")
            }
            guard property.fact.isSettable else {
                return finding(boundary, .unresolved, source: source, candidates: [property.node.id],
                    reason: "KVC write has no supported Swift setter evidence.")
            }
        }
        return checked(boundary, source: source, targets: [property.node.id])
    }

    private func keyPathAccess(
        _ boundary: RuntimeBoundary,
        source: NodeID?
    ) -> RuntimeDiscoveryFinding {
        let rawPaths = boundary.keyPaths ?? boundary.name.map { [$0] } ?? []
        let paths = rawPaths.compactMap(RuntimeKeyPath.components)
        guard !rawPaths.isEmpty, paths.count == rawPaths.count else {
            return finding(boundary, .dynamic, source: source,
                reason: "The KVC key path is empty, malformed or exceeds 16 segments.")
        }
        let receivers = receiverTypes(boundary)
        guard receivers.count == 1, let root = receivers.first,
              let rootDeclaration = declarationByID[root], rootDeclaration.fact.isFinal,
              nsObjectClasses.contains(root)
        else {
            return finding(boundary, receivers.count > 1 ? .ambiguous : .unresolved, source: source,
                reason: "KVC key path receiver must be one compiler-confirmed final NSObject subclass.")
        }
        var targets: [NodeID] = []
        var seen: Set<NodeID> = []
        for components in paths {
            var receiver = root
            for (offset, key) in components.enumerated() {
                let isLast = offset == components.count - 1
                let writes = boundary.kind == .keyPathWrite && isLast
                let accessKind: RuntimeBoundaryKind = writes ? .keyValueWrite : .keyValueRead
                let owners = Set(ancestorDistances(of: receiver).keys)
                if hasKeyPathOverride(kind: boundary.kind, owners: owners)
                    || hasKeyValueOverrideOrAlternateAccessor(key: key, kind: accessKind, owners: owners) {
                    return finding(boundary, .unresolved, source: source,
                        reason: "A KVC override or higher-priority accessor changes segment '\(key)'.")
                }
                let properties = kvcProperties(key: key, owners: owners)
                guard properties.count == 1, let property = properties.first else {
                    return finding(boundary, properties.count > 1 ? .ambiguous : .unresolved,
                        source: source, candidates: properties.map(\.node.id),
                        reason: "KVC key path segment '\(key)' has no unique explicit @objc property.")
                }
                if writes, property.fact.isImmutable || !property.fact.isSettable {
                    return finding(boundary, .unresolved, source: source, candidates: [property.node.id],
                        reason: "The final KVC key path segment has no supported Swift setter evidence.")
                }
                if seen.insert(property.node.id).inserted { targets.append(property.node.id) }
                if !isLast {
                    guard let next = nextKeyPathReceiver(property) else {
                        return finding(boundary, .unresolved, source: source, candidates: [property.node.id],
                            reason: "An intermediate KVC property has no exact final NSObject type reference.")
                    }
                    receiver = next
                }
            }
        }
        return checked(
            boundary,
            source: source,
            targets: targets,
            reason: "Targets are properties used by the path; intermediate targets are not setter executions."
        )
    }

    private func kvcProperties(key: String, owners: Set<NodeID>) -> [Declaration] {
        declarations.filter { declaration in
            guard declaration.node.kind == .property,
                  declaration.fact.attributes.contains(.objc),
                  declaration.fact.objectiveCName == key,
                  !declaration.fact.isStatic,
                  let owner = graph.semanticParent(of: declaration.node.id), owners.contains(owner)
            else { return false }
            return true
        }
    }

    private func nextKeyPathReceiver(_ property: Declaration) -> NodeID? {
        guard let typeName = property.fact.valueTypeName,
              let location = property.fact.valueTypeLocation
        else { return nil }
        let candidates = Set((references[location] ?? []).compactMap { reference -> NodeID? in
            guard NodeID(reference.sourceUSR) == property.node.id,
                  let declaration = declarationByID[NodeID(reference.targetUSR)],
                  declaration.node.kind == .classType,
                  declaration.fact.isFinal,
                  nsObjectClasses.contains(declaration.node.id),
                  matchesType(typeName, declaration)
            else { return nil }
            return declaration.node.id
        })
        return candidates.count == 1 ? candidates.first : nil
    }

    private func hasKeyPathOverride(kind: RuntimeBoundaryKind, owners: Set<NodeID>) -> Bool {
        let indexNames: Set<String>
        let objectiveCSelectors: Set<String>
        if kind == .keyPathWrite {
            indexNames = ["setValue(_:forKeyPath:)", "value(forKeyPath:)"]
            objectiveCSelectors = ["setValue:forKeyPath:", "valueForKeyPath:"]
        } else {
            indexNames = ["value(forKeyPath:)"]
            objectiveCSelectors = ["valueForKeyPath:"]
        }
        return declarations.contains { declaration in
            guard declaration.node.kind == .method, !declaration.fact.isStatic,
                  let owner = graph.semanticParent(of: declaration.node.id), owners.contains(owner)
            else { return false }
            return indexNames.contains(declaration.fact.indexName)
                || declaration.fact.objectiveCName.map(objectiveCSelectors.contains) == true
        }
    }

    private func hasKeyValueOverrideOrAlternateAccessor(
        key: String,
        kind: RuntimeBoundaryKind,
        owners: Set<NodeID>
    ) -> Bool {
        let capitalized = key.prefix(1).uppercased() + String(key.dropFirst())
        let indexNames: Set<String>
        let objectiveCSelectors: Set<String>
        if kind == .keyValueRead {
            indexNames = ["get\(capitalized)()", "is\(capitalized)()", "_get\(capitalized)()", "_\(key)()",
                "value(forKey:)"]
            objectiveCSelectors = ["get\(capitalized)", "is\(capitalized)", "_get\(capitalized)", "_\(key)",
                "valueForKey:"]
        } else {
            indexNames = ["set\(capitalized)(_:)", "setValue(_:forKey:)"]
            objectiveCSelectors = ["set\(capitalized):", "setValue:forKey:"]
        }
        return declarations.contains { declaration in
            guard !declaration.fact.isStatic,
                  let owner = graph.semanticParent(of: declaration.node.id)
            else { return false }
            guard owners.contains(owner) else { return false }
            if declaration.node.kind == .method {
                return indexNames.contains(declaration.fact.indexName)
                    || declaration.fact.objectiveCName.map(objectiveCSelectors.contains) == true
            }
            guard kind == .keyValueRead,
                  declaration.node.kind == .property,
                  declaration.fact.objectiveCName != key
            else { return false }
            return declaration.fact.objectiveCName.map(objectiveCSelectors.contains) == true
        }
    }

    private func selectorReference(_ boundary: RuntimeBoundary) -> RuntimeDiscoveryFinding {
        guard let location = boundary.referencedTargetLocation else {
            return finding(boundary, .unindexed, reason: "The selector has no exact declaration reference.")
        }
        let refs = (references[location] ?? []).filter { graph.node(NodeID($0.targetUSR)) != nil }
        let targets = Set(refs.map { NodeID($0.targetUSR) })
        let sources = Set(refs.map { NodeID($0.sourceUSR) }).filter { graph.node($0) != nil }
        guard targets.count == 1, sources.count == 1 else {
            return finding(boundary, .unindexed, candidates: Array(targets),
                reason: "The selector's compiler reference is not unique.")
        }
        return checked(boundary, source: sources.first, targets: Array(targets), status: .alreadyIndexed)
    }

    private func member(_ boundary: RuntimeBoundary, source: NodeID?, selector: String? = nil)
        -> RuntimeDiscoveryFinding {
        let direct = boundary.referencedTargetLocation.flatMap { location in
            let matches = (references[location] ?? []).compactMap { declarationByID[NodeID($0.targetUSR)] }
            return Set(matches.map(\.node.id)).count == 1 ? matches.first : nil
        }
        let name = selector ?? boundary.name
        guard direct != nil || name != nil else { return finding(boundary, .dynamic, source: source) }
        let candidates = declarations.filter { declaration in
            if boundary.kind == .interfaceBuilderOutlet {
                return declaration.node.kind == .property && declaration.fact.objectiveCName == name
            }
            guard [.method, .initializer].contains(declaration.node.kind) else { return false }
            if let direct { return declaration.node.id == direct.node.id }
            return declaration.fact.objectiveCName != nil && declaration.fact.objectiveCName == name
        }
        let receivers = receiverTypes(boundary)
        guard receivers.count == 1, let receiver = receivers.first else {
            return finding(boundary, receivers.count > 1 ? .ambiguous : .unresolved, source: source,
                candidates: candidates.map(\.node.id), reason: "The runtime receiver type is not uniquely known.")
        }
        let distances = ancestorDistances(of: receiver)
        let compatible = candidates.filter { declaration in
            guard let owner = graph.semanticParent(of: declaration.node.id) else { return false }
            return distances[owner] != nil
        }
        let nearestDistance = compatible.compactMap {
            graph.semanticParent(of: $0.node.id).flatMap { distances[$0] }
        }.min()
        let nearest = compatible.filter {
            graph.semanticParent(of: $0.node.id).flatMap { distances[$0] } == nearestDistance
        }
        guard nearest.count == 1, let target = nearest.first else {
            return finding(boundary, compatible.isEmpty ? .unresolved : .ambiguous, source: source,
                candidates: compatible.map(\.node.id), reason: "The receiver has no unique matching runtime member.")
        }
        var targets: Set<NodeID> = [target.node.id]
        // 도달 가능한 override도 잠재 타깃이다. 형제 타입은 수신자 호환성으로 걸러 낸다.
        var queue = [target.node.id]
        while let current = queue.popLast() {
            for edge in graph.incomingEdges(to: current) where edge.kind == .overrides {
                guard let owner = graph.semanticParent(of: edge.source),
                      ancestors(of: owner).contains(receiver), targets.insert(edge.source).inserted else { continue }
                queue.append(edge.source)
            }
        }
        return checked(boundary, source: source, targets: Array(targets))
    }

    private func receiverTypes(_ boundary: RuntimeBoundary) -> [NodeID] {
        guard let hint = boundary.receiverTypeName else { return [] }
        if let location = boundary.receiverTypeLocation {
            let refs = references[location] ?? []
            let ids = Set(refs.compactMap { reference -> NodeID? in
                let id = NodeID(reference.targetUSR)
                guard let node = graph.node(id) else { return nil }
                if node.kind == .classType { return id }
                return node.kind == .initializer ? graph.semanticParent(of: id) : nil
            })
            // 틀린 타입 힌트를 이름으로 덮어 쓰지 않는다.
            if !refs.isEmpty { return Array(ids).sorted() }
        }
        return declarations.filter { $0.node.kind == .classType && matchesType(hint, $0) }.map(\.node.id)
    }

    private func matchesType(_ name: String, _ declaration: Declaration) -> Bool {
        name == declaration.fact.qualifiedName
            || name == (declaration.node.module.map { $0 + "." } ?? "") + declaration.fact.qualifiedName
            || name == declaration.fact.objectiveCName
    }

    private static func isManagedObjectUSR(_ usr: String) -> Bool {
        usr == "c:objc(cs)NSManagedObject"
            || usr == "s:So15NSManagedObjectC"
    }

    private static func inheritedClasses(
        snapshot: IndexSnapshot,
        graph: CodeGraph,
        externalBaseUSRs: Set<String>
    ) -> Set<NodeID> {
        var result = Set(snapshot.references.compactMap { reference -> NodeID? in
            guard reference.kind == .inheritance,
                  externalBaseUSRs.contains(reference.targetUSR),
                  graph.node(NodeID(reference.sourceUSR)) != nil
            else { return nil }
            return NodeID(reference.sourceUSR)
        })
        var queue = Array(result)
        while let base = queue.popLast() {
            for edge in graph.incomingEdges(to: base) where edge.kind == .inheritance {
                if result.insert(edge.source).inserted { queue.append(edge.source) }
            }
        }
        return result
    }

    private func ancestors(of node: NodeID) -> Set<NodeID> {
        var result: Set<NodeID> = [node]
        var queue = [node]
        while let next = queue.popLast() {
            for edge in graph.outgoingEdges(from: next) where edge.kind == .inheritance {
                if result.insert(edge.target).inserted { queue.append(edge.target) }
            }
        }
        return result
    }

    func ancestorDistances(of node: NodeID) -> [NodeID: Int] {
        var distances = [node: 0]
        var queue = [node]
        var head = 0
        while head < queue.count {
            let next = queue[head]
            head += 1
            for edge in graph.outgoingEdges(from: next) where edge.kind == .inheritance {
                guard distances[edge.target] == nil else { continue }
                distances[edge.target] = (distances[next] ?? 0) + 1
                queue.append(edge.target)
            }
        }
        return distances
    }

    /// 실행 수집도 동일한 선언 신원 색인으로 런타임 이름을 대조한다.
    func runtimeTypes(named name: String, kind: SymbolKind = .classType) -> [NodeID] {
        declarations.filter { declaration in
            guard declaration.node.kind == kind else { return false }
            if kind == .protocolType, declaration.fact.objectiveCName == nil,
               !declaration.node.attributes.contains(.objc),
               !declaration.node.attributes.contains(.objcAccessible) { return false }
            return declaration.fact.objectiveCName == name
                || (declaration.node.module.map { $0 + "." } ?? "") + declaration.fact.qualifiedName == name
        }.map(\.node.id)
    }

    /// 실제 수신자 클래스가 알려진 selector는 클래스/인스턴스 메서드를 섞지 않는다.
    func runtimeMethods(named selector: String, receiver: NodeID, isClass: Bool) -> [NodeID] {
        let distances = ancestorDistances(of: receiver)
        let matches = declarations.filter { declaration in
            guard [.method, .initializer].contains(declaration.node.kind),
                  declaration.fact.objectiveCName == selector, declaration.fact.isStatic == isClass,
                  let owner = graph.semanticParent(of: declaration.node.id) else { return false }
            return distances[owner] != nil
        }
        let nearest = matches.compactMap { graph.semanticParent(of: $0.node.id).flatMap { distances[$0] } }.min()
        return matches.filter { graph.semanticParent(of: $0.node.id).flatMap { distances[$0] } == nearest }
            .map(\.node.id)
    }

    private func checked(_ boundary: RuntimeBoundary, source: NodeID?, targets: [NodeID],
                         status: RuntimeDiscoveryStatus = .resolved,
                         reason: String? = nil) -> RuntimeDiscoveryFinding {
        for target in targets {
            if let path = graph.node(target)?.location?.path, let stale = freshnessStatus(path: path) {
                return finding(boundary, stale, source: source, candidates: targets,
                    reason: "A target declaration is not backed by a current index unit.")
            }
        }
        return finding(boundary, status, source: source, targets: targets, reason: reason)
    }

    private func freshnessStatus(path: String) -> RuntimeDiscoveryStatus? {
        switch freshness[path] ?? .unknownIndexDate {
        case .fresh, .notApplicable: return nil
        case .sourceNewerThanIndex: return .stale
        default: return .unindexed
        }
    }

    private func sourceOwners(_ accepted: [IndexedReference], boundary: RuntimeBoundary) -> Set<NodeID> {
        let sources = Set(accepted.map { NodeID($0.sourceUSR) }).filter { graph.node($0) != nil }
        if let location = boundary.enclosingDeclarationLocation {
            let exact = sources.filter { graph.node($0)?.location == location }
            if exact.count == 1, let node = exact.first.flatMap({ graph.node($0) }), !node.kind.isTypeDeclaration {
                return exact
            }
        }
        // receivedBy도 call로 정규화되어 같은 자리에 수신자 타입이 생긴다. 그 타입을 실제
        // 호출 주체로 고르면 모든 메서드가 영향을 받는 허상 경로가 생긴다.
        return sources.filter { graph.node($0).map { !$0.kind.isTypeDeclaration && $0.kind != .module } == true }
    }

    private func lexicalOwnerForDiagnostic(_ boundary: RuntimeBoundary) -> NodeID? {
        guard let location = boundary.enclosingDeclarationLocation else { return nil }
        let nodes = (graphNodesByLocation[location] ?? []).filter { !$0.kind.isTypeDeclaration }
        return nodes.count == 1 ? nodes.first?.id : nil
    }

    private func finding(_ boundary: RuntimeBoundary, _ status: RuntimeDiscoveryStatus,
                         source: NodeID? = nil, targets: [NodeID] = [], candidates: [NodeID] = [],
                         reason: String? = nil) -> RuntimeDiscoveryFinding {
        .init(boundary: boundary, status: status, source: source, targets: targets,
            candidates: candidates, reason: reason)
    }

    func joinNotifications(_ findings: [RuntimeDiscoveryFinding]) -> [RuntimeDiscoveryFinding] {
        let observers = Dictionary(grouping: findings.filter {
            [.notificationObserver, .notificationSubscription].contains($0.boundary.kind)
                && $0.status == .resolved && notificationKey($0.boundary) != nil
        }) { notificationKey($0.boundary)! }
        return findings.map { entry in
            guard entry.boundary.kind == .notificationPost, entry.status == .unresolved,
                  let key = notificationKey(entry.boundary), let handlers = observers[key], !handlers.isEmpty
            else { return entry }
            let matching = handlers.filter {
                notificationCentersMatch($0.boundary, entry.boundary)
                    && notificationObjectsMatch(observer: $0.boundary, post: entry.boundary)
                    && notificationRegistrationPrecedesPost($0.boundary, entry.boundary)
                    && !notificationWasRemoved($0.boundary, before: entry.boundary)
                    && !notificationSubscriptionWasCancelled($0.boundary, before: entry.boundary)
            }
            guard !matching.isEmpty else {
                return finding(entry.boundary, .unresolved, source: entry.source,
                    candidates: handlers.flatMap(\.targets),
                    reason: "The notification center or observer object filter is not proven compatible.")
            }
            let targets = matching.flatMap { handler in
                handler.boundary.kind == .notificationSubscription
                    ? handler.source.map { [$0] } ?? [] : handler.targets
            }
            return checked(entry.boundary, source: entry.source, targets: targets)
        }
    }

    private func notificationKey(_ boundary: RuntimeBoundary) -> String? {
        if let name = boundary.notificationName { return "literal:" + name }
        if boundary.kind != .notificationObserver || boundary.receiverOrigin != .explicitTarget,
           let name = boundary.name { return "literal:" + name }
        guard let location = boundary.notificationNameLocation else { return nil }
        let constants = Set((references[location] ?? []).compactMap { reference -> NodeID? in
            guard let declaration = declarationByID[NodeID(reference.targetUSR)], declaration.fact.isImmutable,
                  declaration.fact.isStatic || declaration.fact.kind == .variable else { return nil }
            return declaration.node.id
        })
        if constants.count == 1 { return constants.first.map { "constant:" + $0.rawValue } }
        let systemConstants = Set((references[location] ?? []).compactMap {
            RuntimeSystemAPI.notificationConstantIdentity($0.targetUSR)
        })
        return systemConstants.count == 1 ? systemConstants.first.map { "system:" + $0 } : nil
    }

    private enum NotificationCenterIdentity: Equatable {
        case stable(String)
        case local(SourceLocation)
    }

    private func notificationCenterIdentity(_ boundary: RuntimeBoundary) -> NotificationCenterIdentity? {
        guard let location = boundary.notificationCenterLocation else { return nil }
        return notificationCenterIdentity(
            location: location,
            ownerLocation: boundary.notificationCenterOwnerLocation
        )
    }

    private func notificationCenterIdentity(
        location: SourceLocation,
        ownerLocation: SourceLocation?
    ) -> NotificationCenterIdentity? {
        let centerReferences = references[location] ?? []
        if centerReferences.contains(where: { RuntimeSystemAPI.isDefaultNotificationCenter($0.targetUSR) }) {
            return .stable("NSNotificationCenter.default")
        }
        if centerReferences.contains(where: { RuntimeSystemAPI.isWorkspaceNotificationCenter($0.targetUSR) }),
           let ownerLocation,
           (references[ownerLocation] ?? []).contains(where: {
               RuntimeSystemAPI.isSharedWorkspace($0.targetUSR)
           }) {
            return .stable("NSWorkspace.shared.notificationCenter")
        }
        guard ownerLocation == nil,
              centerReferences.contains(where: { $0.targetUSR == "c:objc(cs)NSNotificationCenter" })
        else { return nil }
        return .local(location)
    }

    private func notificationCentersMatch(_ lhs: RuntimeBoundary, _ rhs: RuntimeBoundary) -> Bool {
        guard let left = notificationCenterIdentity(lhs), left == notificationCenterIdentity(rhs) else {
            return false
        }
        guard case .local = left else { return true }
        return lhs.enclosingDeclarationLocation == rhs.enclosingDeclarationLocation
    }

    private func notificationObjectsMatch(observer: RuntimeBoundary, post: RuntimeBoundary) -> Bool {
        if observer.notificationObjectIsNil == true { return true }
        guard observer.notificationObjectIsNil == false, post.notificationObjectIsNil == false,
              let observerLocation = notificationObjectIdentity(observer),
              observerLocation == notificationObjectIdentity(post)
        else { return false }
        return observer.enclosingDeclarationLocation == post.enclosingDeclarationLocation
    }

    private func notificationRegistrationPrecedesPost(
        _ observer: RuntimeBoundary,
        _ post: RuntimeBoundary
    ) -> Bool {
        let usesLocalCenter: Bool
        if case .local? = notificationCenterIdentity(observer) { usesLocalCenter = true }
        else { usesLocalCenter = false }
        let usesLocalObject = observer.notificationObjectIsNil == false
            && notificationObjectIdentity(observer) != nil
        if !usesLocalCenter && !usesLocalObject { return true }
        return observer.location < post.location
    }

    private func notificationWasRemoved(_ observer: RuntimeBoundary, before post: RuntimeBoundary) -> Bool {
        return (post.notificationRemovalReferences ?? []).contains { removal in
            guard removal.registrationLocation == observer.location,
                  observer.location < removal.removalLocation,
                  removal.removalLocation < post.location,
                  notificationCenterIdentity(
                    location: removal.notificationCenterLocation,
                    ownerLocation: removal.notificationCenterOwnerLocation
                  ) == notificationCenterIdentity(observer)
            else { return false }
            return (references[removal.removalLocation] ?? []).contains {
                ($0.kind == .call || $0.kind == .reference)
                    && RuntimeSystemAPI.isNotificationRemoval($0.targetUSR)
            }
        }
    }

    private func notificationSubscriptionWasCancelled(
        _ subscription: RuntimeBoundary,
        before post: RuntimeBoundary
    ) -> Bool {
        guard subscription.kind == .notificationSubscription else { return false }
        return (post.notificationCancellationReferences ?? []).contains { cancellation in
            guard cancellation.registrationLocation == subscription.location,
                  subscription.location < cancellation.cancellationLocation,
                  cancellation.cancellationLocation < post.location
            else { return false }
            return (references[cancellation.cancellationLocation] ?? []).contains {
                ($0.kind == .call || $0.kind == .reference)
                    && RuntimeSystemAPI.isNotificationCancellation($0.targetUSR)
            }
        }
    }

    private func notificationObjectIdentity(_ boundary: RuntimeBoundary) -> SourceLocation? {
        guard let location = boundary.notificationObjectLocation else { return nil }
        let isClassConstruction = (references[location] ?? []).contains { reference in
            if reference.targetUSR.hasPrefix("c:objc(cs)") { return true }
            guard let node = graph.node(NodeID(reference.targetUSR)) else { return false }
            if node.kind == .classType { return true }
            guard node.kind == .initializer, let owner = graph.semanticParent(of: node.id) else { return false }
            return graph.node(owner)?.kind == .classType
        }
        return isClassConstruction ? location : nil
    }
}

/// 문자열 철자가 아니라 컴파일러가 정한 시스템 심볼의 신원으로 API를 확인한다.
private enum RuntimeSystemAPI {
    private static let notificationConstants: Set<String> = [
        "c:@NSApplicationDidBecomeActiveNotification",
        "c:@NSApplicationDidChangeScreenParametersNotification",
        "c:@NSWindowDidChangeScreenProfileNotification",
        "c:@NSWorkspaceDidLaunchApplicationNotification",
        "c:@AVCaptureSessionDidStartRunningNotification",
        "c:@AVCaptureSessionDidStopRunningNotification",
        "c:@UIApplicationDidReceiveMemoryWarningNotification",
    ]
    private static let notificationAsyncSequenceAPI =
        "s:So20NSNotificationCenterC10FoundationE13notifications" +
        "5named6objectAbCE13NotificationsCSo0A4Namea_yXlSgtF"
    private static let notificationConstantAliases: [String: String] = [
        "s:So18NSNotificationNamea12AVFoundationE31AVCaptureSessionDidStartRunningABvgZ":
            "c:@AVCaptureSessionDidStartRunningNotification",
        "s:So18NSNotificationNamea12AVFoundationE31AVCaptureSessionDidStartRunningABvpZ":
            "c:@AVCaptureSessionDidStartRunningNotification",
        "s:So18NSNotificationNamea12AVFoundationE30AVCaptureSessionDidStopRunningABvgZ":
            "c:@AVCaptureSessionDidStopRunningNotification",
        "s:So18NSNotificationNamea12AVFoundationE30AVCaptureSessionDidStopRunningABvpZ":
            "c:@AVCaptureSessionDidStopRunningNotification",
    ]

    static func notificationConstantIdentity(_ usr: String) -> String? {
        if notificationConstants.contains(usr) { return usr }
        return notificationConstantAliases[usr]
    }

    static func isDefaultNotificationCenter(_ usr: String) -> Bool {
        usr == "c:objc(cs)NSNotificationCenter(cpy)defaultCenter"
            || usr == "c:objc(cs)NSNotificationCenter(cm)defaultCenter"
    }

    static func isWorkspaceNotificationCenter(_ usr: String) -> Bool {
        usr == "c:objc(cs)NSWorkspace(py)notificationCenter"
            || usr == "c:objc(cs)NSWorkspace(im)notificationCenter"
    }

    static func isSharedWorkspace(_ usr: String) -> Bool {
        usr == "c:objc(cs)NSWorkspace(cpy)sharedWorkspace"
            || usr == "c:objc(cs)NSWorkspace(cm)sharedWorkspace"
    }

    static func isNotificationRemoval(_ usr: String) -> Bool {
        usr == "c:objc(cs)NSNotificationCenter(im)removeObserver:"
    }

    static func isNotificationCancellation(_ usr: String) -> Bool {
        usr == "s:7Combine14AnyCancellableC6cancelyyF"
    }

    static func confirmsAsyncNotificationIteration(_ usrs: [String]) -> Bool {
        let values = Set(usrs)
        return values.contains(
            "s:So20NSNotificationCenterC10FoundationE13NotificationsC17makeAsyncIteratorAE0G0VyF"
        ) && values.contains(
            "s:So20NSNotificationCenterC10FoundationE13NotificationsC8IteratorV4nextAC12NotificationVSgyYaF"
        )
    }

    static func acceptsSubscriptionConsumer(_ usr: String, api: String) -> Bool {
        if api == "sink" {
            return usr.hasPrefix("s:7Combine9PublisherP") && usr.contains("E4sink")
        }
        if api == "onReceive" { return usr.hasPrefix("s:7SwiftUI4ViewPAAE9onReceive") }
        return false
    }

    static func acceptsNameProof(_ usr: String, api: String) -> Bool {
        let name = api.split(separator: ".").last.map(String.init) ?? api
        if name == "Selector" || name == "NSSelectorFromString" {
            return accepts(usr, kind: .selectorLookup)
        }
        if api == "String.+" { return usr.hasPrefix("s:SS1poiy") }
        if name == "Name" {
            return usr.hasPrefix("s:So18NSNotificationNamea") || usr == "c:@T@NSNotificationName"
        }
        if name == "Notification" { return usr.hasPrefix("s:10Foundation12NotificationV4name") }
        if api == "NSPredicate.format" {
            return usr == "s:So11NSPredicateC10FoundationE6format_ABSSh_s7CVarArg_pdtcfc"
                || usr == "c:objc(cs)NSPredicate(cm)predicateWithFormat:argumentArray:"
        }
        return false
    }

    static func accepts(_ usr: String, kind: RuntimeBoundaryKind) -> Bool {
        switch kind {
        case .coreDataContainer:
            return usr == "c:objc(cs)NSPersistentContainer"
                || usr == "c:objc(cs)NSPersistentContainer(im)initWithName:"
        case .coreDataFetch:
            return usr == "s:So22NSManagedObjectContextC8CoreDataE5fetchySayxGSo14NSFetchRequestCyxGKSo0gH6ResultRzlF"
        case .classLookup:
            return cFunction(usr, names: ["NSClassFromString", "objc_getClass", "objc_lookUpClass"])
                || swiftFunction(usr, module: "Foundation", name: "NSClassFromString")
                || objcMethod(usr, owners: ["NSBundle"], names: ["classNamed:"])
        case .protocolLookup:
            return cFunction(usr, names: ["NSProtocolFromString", "objc_getProtocol"])
                || swiftFunction(usr, module: "Foundation", name: "NSProtocolFromString")
        case .selectorLookup:
            return cFunction(usr, names: ["NSSelectorFromString", "sel_registerName", "sel_getUid"])
                || swiftFunction(usr, module: "Foundation", name: "NSSelectorFromString")
                || usr.hasPrefix("s:10ObjectiveC8SelectorV")
        case .selectorInvocation:
            return objcMethod(usr, owners: ["NSObject"], names: [
                "performSelector:", "performSelector:withObject:", "performSelector:withObject:withObject:",
                "performSelector:withObject:afterDelay:", "performSelector:withObject:afterDelay:inModes:",
            ])
        case .selectorRegistration:
            return objcMethod(usr, owners: ["UIControl", "NSTimer", "CADisplayLink", "NSMenuItem"], names: nil)
                || objcMethod(usr, owners: ["UIGestureRecognizer", "UITapGestureRecognizer", "UIPanGestureRecognizer",
                    "UILongPressGestureRecognizer", "UISwipeGestureRecognizer", "UIPinchGestureRecognizer",
                    "UIRotationGestureRecognizer", "UIScreenEdgePanGestureRecognizer"], names: ["initWithTarget:action:"])
        case .notificationObserver:
            return objcMethod(usr, owners: ["NSNotificationCenter"], names: [
                "addObserver:selector:name:object:", "addObserverForName:object:queue:usingBlock:",
            ])
        case .notificationPost:
            return objcMethod(usr, owners: ["NSNotificationCenter"], names: [
                "postNotificationName:object:", "postNotificationName:object:userInfo:", "postNotification:",
            ])
        case .notificationSubscription:
            return usr.hasPrefix("s:So20NSNotificationCenterC10FoundationE9publisher")
                || usr == notificationAsyncSequenceAPI
        case .keyValueRead:
            return objcMethod(usr, owners: ["NSObject"], names: ["valueForKey:"])
        case .keyValueWrite:
            return objcMethod(usr, owners: ["NSObject"], names: ["setValue:forKey:"])
        case .keyPathRead:
            return objcMethod(usr, owners: ["NSObject"], names: ["valueForKeyPath:"])
                || objcMethod(usr, owners: ["NSPredicate"], names: ["evaluateWithObject:"])
        case .keyPathWrite:
            return objcMethod(usr, owners: ["NSObject"], names: ["setValue:forKeyPath:"])
        default: return false
        }
    }

    private static func cFunction(_ usr: String, names: [String]) -> Bool {
        names.contains { usr == "c:@F@" + $0 }
    }

    private static func swiftFunction(_ usr: String, module: String, name: String) -> Bool {
        usr.hasPrefix("s:\(module.utf8.count)\(module)\(name.utf8.count)\(name)")
    }

    private static func objcMethod(_ usr: String, owners: [String], names: [String]?) -> Bool {
        owners.contains { owner in
            ["(cs)", "(pl)"].contains { ownerKind in
                ["(im)", "(cm)"].contains { methodKind in
                    let prefix = "c:objc\(ownerKind)\(owner)\(methodKind)"
                    guard usr.hasPrefix(prefix) else { return false }
                    return names.map { $0.contains(String(usr.dropFirst(prefix.count))) } ?? true
                }
            }
        }
    }
}
