@testable import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("Core Data container와 fetch 모델 결합")
struct CoreDataRuntimeBinderTests {
    private let path = "/p/Store.swift"

    @Test("검증된 main-bundle 모델은 container source를 모든 엔티티 클래스와 연결한다")
    func resolvesContainerMetadataDependencies() {
        let graph = TestGraph.make(["caller": [], "record": []])
        let binder = CoreDataRuntimeBinder(
            entityFindings: [entityFinding(target: "record")],
            snapshot: snapshot(),
            graph: graph
        )
        let finding = binder.resolve(containerBoundary(), source: NodeID("caller"))
        #expect(finding.status == .resolved)
        #expect(finding.targets == [NodeID("record")])
        #expect(finding.reason?.contains("not observed") == true)
    }

    @Test("같은 local container의 viewContext와 literal request proof가 모두 있어야 fetch를 연결한다")
    func resolvesProvenFetch() {
        let graph = TestGraph.make(["caller": [], "record": []])
        let binder = CoreDataRuntimeBinder(
            entityFindings: [entityFinding(target: "record")],
            snapshot: snapshot(),
            graph: graph
        )
        let finding = binder.resolve(fetchBoundary(), source: NodeID("caller"))
        #expect(finding.status == .resolved)
        #expect(finding.targets == [NodeID("record")])
    }

    @Test("evidence가 없거나 다른 context API이면 같은 entity 문자열도 연결하지 않는다")
    func rejectsMissingEvidenceAndDifferentContext() {
        let graph = TestGraph.make(["caller": [], "record": []])
        let missing = CoreDataRuntimeBinder(entityFindings: [], snapshot: snapshot(), graph: graph)
            .resolve(fetchBoundary(), source: NodeID("caller"))
        #expect(missing.status == .unresolved)

        var wrong = snapshot()
        wrong.references.removeAll { $0.location == location(4) }
        wrong.references.append(.init(
            sourceUSR: "caller",
            targetUSR: "c:objc(cs)NSManagedObjectContext",
            kind: .reference,
            location: location(4)
        ))
        let unproven = CoreDataRuntimeBinder(
            entityFindings: [entityFinding(target: "record")],
            snapshot: wrong,
            graph: graph
        ).resolve(fetchBoundary(), source: NodeID("caller"))
        #expect(unproven.status == .unindexed)

        var shadowed = snapshot()
        shadowed.references.removeAll { $0.location == location(7) }
        shadowed.references.append(.init(
            sourceUSR: "caller",
            targetUSR: "s:4User5fetchyyF",
            kind: .call,
            location: location(7)
        ))
        let wrongFetch = CoreDataRuntimeBinder(
            entityFindings: [entityFinding(target: "record")],
            snapshot: shadowed,
            graph: graph
        ).resolve(fetchBoundary(), source: NodeID("caller"))
        #expect(wrongFetch.status == .unindexed)
    }

    @Test("raw modelName이나 targetUSR가 실제 resolved target과 다르면 evidence로 쓰지 않는다")
    func rejectsUnverifiedResourceClaims() {
        let graph = TestGraph.make(["caller": [], "record": []])
        let mismatch = RuntimeDiscoveryFinding(
            boundary: entityBoundary(targetUSR: "other"),
            status: .resolved,
            targets: [NodeID("record")]
        )
        let finding = CoreDataRuntimeBinder(
            entityFindings: [mismatch],
            snapshot: snapshot(),
            graph: graph
        ).resolve(containerBoundary(), source: NodeID("caller"))
        #expect(finding.status == .unresolved)
        #expect(finding.targets.isEmpty)
    }

    @Test("기본 parent fetch는 모든 verified descendant class를 함께 연결하고 cycle은 거부한다")
    func expandsDefaultFetchToDescendants() {
        let graph = TestGraph.make(["caller": [], "parent": [], "child": []])
        let findings = [
            entityFinding(target: "parent", entity: "Parent"),
            entityFinding(target: "child", entity: "Child", parent: "Parent"),
        ]
        let binder = CoreDataRuntimeBinder(entityFindings: findings, snapshot: snapshot(), graph: graph)
        let fetched = binder.resolve(fetchBoundary(entity: "Parent"), source: NodeID("caller"))
        #expect(fetched.status == .resolved)
        #expect(fetched.targets == [NodeID("child"), NodeID("parent")])

        let cycle = CoreDataRuntimeBinder(entityFindings: [
            entityFinding(target: "parent", entity: "Parent", parent: "Child"),
            entityFinding(target: "child", entity: "Child", parent: "Parent"),
        ], snapshot: snapshot(), graph: graph)
        #expect(cycle.resolve(fetchBoundary(entity: "Parent"), source: NodeID("caller")).status == .unresolved)
    }

    private func snapshot() -> IndexSnapshot {
        IndexSnapshot(references: [
            .init(sourceUSR: "caller", targetUSR: "c:objc(cs)NSPersistentContainer(im)initWithName:",
                  kind: .call, location: location(3)),
            .init(sourceUSR: "caller", targetUSR: "c:objc(cs)NSPersistentContainer(im)viewContext",
                  kind: .call, location: location(4)),
            .init(sourceUSR: "caller", targetUSR: "c:objc(cs)NSFetchRequest(im)initWithEntityName:",
                  kind: .call, location: location(5)),
            .init(sourceUSR: "caller", targetUSR: "c:objc(cs)NSManagedObject",
                  kind: .reference, location: location(6)),
            .init(
                sourceUSR: "caller",
                targetUSR: "s:So22NSManagedObjectContextC8CoreDataE5fetchySayxGSo14NSFetchRequestCyxGKSo0gH6ResultRzlF",
                kind: .call,
                location: location(7)
            ),
        ])
    }

    private func entityFinding(
        target: String,
        entity: String = "Record",
        parent: String? = nil
    ) -> RuntimeDiscoveryFinding {
        RuntimeDiscoveryFinding(
            boundary: entityBoundary(targetUSR: target, entity: entity, parent: parent),
            status: .resolved,
            targets: [NodeID(target)]
        )
    }

    private func entityBoundary(
        targetUSR: String,
        entity: String = "Record",
        parent: String? = nil
    ) -> RuntimeBoundary {
        RuntimeBoundary(
            kind: .coreDataEntityClass,
            api: "representedClassName",
            location: location(20),
            name: "GeneratedRecord",
            nameOrigin: .resource,
            receiverTypeName: "GeneratedRecord",
            receiverOrigin: .annotation,
            targetUSR: targetUSR,
            resourceObjectID: entity,
            coreDataCodeGeneration: "class",
            coreDataModelName: "Store",
            coreDataSuperentityName: parent
        )
    }

    private func containerBoundary() -> RuntimeBoundary {
        RuntimeBoundary(
            kind: .coreDataContainer,
            api: "NSPersistentContainer.init(name:)",
            location: location(3),
            calleeLocation: location(3),
            name: "Store",
            nameOrigin: .literal,
            coreDataModelName: "Store",
            coreDataContainerLocation: location(3)
        )
    }

    private func fetchBoundary(entity: String = "Record") -> RuntimeBoundary {
        RuntimeBoundary(
            kind: .coreDataFetch,
            api: "NSManagedObjectContext.fetch(_:)",
            location: location(7),
            calleeLocation: location(7),
            name: entity,
            nameOrigin: .literal,
            coreDataModelName: "Store",
            coreDataContainerLocation: location(3),
            coreDataContextLocation: location(4),
            coreDataRequestLocation: location(5),
            coreDataResultTypeLocation: location(6)
        )
    }

    private func location(_ line: Int) -> CartographCore.SourceLocation {
        CartographCore.SourceLocation(path: path, line: line, column: 1)
    }
}
