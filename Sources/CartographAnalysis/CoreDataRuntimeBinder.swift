import CartographCore

/// 컴파일러가 확인한 지역 Core Data 흐름을 검증된 모델 엔티티와 결합한다.
struct CoreDataRuntimeBinder {
    private struct EntityBinding {
        let name: String
        let parent: String?
        let target: NodeID
    }

    private struct ModelBindings {
        let targets: [String: NodeID]
        let children: [String: Set<String>]

        init?(_ bindings: [EntityBinding]) {
            let grouped = Dictionary(grouping: bindings, by: \.name)
            guard grouped.values.allSatisfy({ rows in
                Set(rows.map(\.target)).count == 1
                    && Set(rows.map { $0.parent ?? "" }).count == 1
            }) else { return nil }
            let resolvedTargets = grouped.compactMapValues { $0.first?.target }
            let parents = grouped.compactMapValues { $0.first?.parent }
            guard parents.values.allSatisfy({ resolvedTargets[$0] != nil }),
                  Self.isAcyclic(names: Set(resolvedTargets.keys), parents: parents) else { return nil }
            targets = resolvedTargets
            children = Dictionary(grouping: parents, by: { $0.value })
                .mapValues { Set($0.map { $0.key }) }
        }

        var allTargets: [NodeID] { targets.values.sorted() }

        func targets(for entity: String) -> [NodeID] {
            guard targets[entity] != nil else { return [] }
            var names: Set<String> = [entity]
            var pending = [entity]
            while let parent = pending.popLast() {
                for child in children[parent] ?? [] where names.insert(child).inserted {
                    pending.append(child)
                }
            }
            return names.compactMap { targets[$0] }.sorted()
        }

        private static func isAcyclic(names: Set<String>, parents: [String: String]) -> Bool {
            for entity in names {
                var visited: Set<String> = [entity]
                var current = parents[entity]
                while let parent = current {
                    guard visited.insert(parent).inserted else { return false }
                    current = parents[parent]
                }
            }
            return true
        }
    }

    private let references: [SourceLocation: [IndexedReference]]
    private let models: [String: ModelBindings]

    init(
        entityFindings: [RuntimeDiscoveryFinding],
        snapshot: IndexSnapshot,
        graph: CodeGraph
    ) {
        references = Dictionary(grouping: snapshot.references.compactMap { reference in
            reference.location.map { ($0, reference) }
        }, by: { $0.0 }).mapValues { $0.map { $0.1 } }
        var bindings: [String: [EntityBinding]] = [:]
        for finding in entityFindings where finding.boundary.kind == .coreDataEntityClass {
            guard finding.status == .resolved,
                  finding.targets.count == 1,
                  let target = finding.targets.first,
                  graph.node(target) != nil,
                  finding.boundary.nameOrigin == .resource,
                  let modelName = finding.boundary.coreDataModelName,
                  let entityName = finding.boundary.resourceObjectID,
                  finding.boundary.targetUSR == target.rawValue else { continue }
            bindings[modelName, default: []].append(.init(
                name: entityName,
                parent: finding.boundary.coreDataSuperentityName,
                target: target
            ))
        }
        models = bindings.compactMapValues(ModelBindings.init)
    }

    func resolve(_ boundary: RuntimeBoundary, source: NodeID?) -> RuntimeDiscoveryFinding {
        if let reason = boundary.reason {
            return finding(boundary, status: .unresolved, source: source, reason: reason)
        }
        switch boundary.kind {
        case .coreDataContainer:
            return resolveContainer(boundary, source: source)
        case .coreDataFetch:
            return resolveFetch(boundary, source: source)
        default:
            return finding(
                boundary,
                status: .unresolved,
                source: source,
                reason: "The boundary is not a Core Data container or fetch."
            )
        }
    }

    private func resolveContainer(
        _ boundary: RuntimeBoundary,
        source: NodeID?
    ) -> RuntimeDiscoveryFinding {
        guard let modelName = boundary.coreDataModelName ?? boundary.name,
              validContainerConstructor(boundary.coreDataContainerLocation) else {
            return finding(
                boundary,
                status: .unindexed,
                source: source,
                reason: "The compiler did not confirm NSPersistentContainer(name:)."
            )
        }
        let targets = models[modelName]?.allTargets ?? []
        guard !targets.isEmpty else {
            return finding(
                boundary,
                status: .unresolved,
                source: source,
                reason: "No current build evidence binds this main-bundle model name."
            )
        }
        return finding(
            boundary,
            status: .resolved,
            source: source,
            targets: targets,
            reason: "Potential main-bundle model metadata dependency; container execution was not observed."
        )
    }

    private func resolveFetch(_ boundary: RuntimeBoundary, source: NodeID?) -> RuntimeDiscoveryFinding {
        guard hasReference(at: boundary.calleeLocation, matching: Self.isFetchCall),
              validContainerConstructor(boundary.coreDataContainerLocation),
              hasReference(at: boundary.coreDataContextLocation, matching: Self.isViewContext),
              hasReference(at: boundary.coreDataRequestLocation, matching: Self.isFetchRequestConstructor),
              hasReference(at: boundary.coreDataResultTypeLocation, matching: Self.isManagedObjectType) else {
            return finding(
                boundary,
                status: .unindexed,
                source: source,
                reason: "The compiler did not confirm the container, viewContext and literal fetch request chain."
            )
        }
        guard let modelName = boundary.coreDataModelName,
              let entityName = boundary.name,
              let model = models[modelName] else {
            return finding(
                boundary,
                status: .unresolved,
                source: source,
                reason: "No current build evidence binds this entity to the proven container model."
            )
        }
        let targets = model.targets(for: entityName)
        guard !targets.isEmpty else {
            return finding(
                boundary,
                status: .unresolved,
                source: source,
                reason: "The entity does not exist in the verified container model hierarchy."
            )
        }
        return finding(boundary, status: .resolved, source: source, targets: targets)
    }

    private func validContainerConstructor(_ location: SourceLocation?) -> Bool {
        hasReference(at: location) {
            $0 == "c:objc(cs)NSPersistentContainer"
                || $0 == "c:objc(cs)NSPersistentContainer(im)initWithName:"
        }
    }

    private func hasReference(
        at location: SourceLocation?,
        matching predicate: (String) -> Bool
    ) -> Bool {
        guard let location else { return false }
        return (references[location] ?? []).contains { predicate($0.targetUSR) }
    }

    private static func isViewContext(_ usr: String) -> Bool {
        usr == "c:objc(cs)NSPersistentContainer(im)viewContext"
            || usr == "c:objc(cs)NSPersistentContainer(py)viewContext"
    }

    private static func isFetchRequestConstructor(_ usr: String) -> Bool {
        usr == "c:objc(cs)NSFetchRequest"
            || usr == "c:objc(cs)NSFetchRequest(im)initWithEntityName:"
    }

    private static func isManagedObjectType(_ usr: String) -> Bool {
        usr == "c:objc(cs)NSManagedObject" || usr == "s:So15NSManagedObjectC"
    }

    private static func isFetchCall(_ usr: String) -> Bool {
        usr == "s:So22NSManagedObjectContextC8CoreDataE5fetchySayxGSo14NSFetchRequestCyxGKSo0gH6ResultRzlF"
    }

    private func finding(
        _ boundary: RuntimeBoundary,
        status: RuntimeDiscoveryStatus,
        source: NodeID?,
        targets: [NodeID] = [],
        candidates: [NodeID] = [],
        reason: String? = nil
    ) -> RuntimeDiscoveryFinding {
        RuntimeDiscoveryFinding(
            boundary: boundary,
            status: status,
            source: source,
            targets: targets,
            candidates: candidates,
            reason: reason
        )
    }
}
