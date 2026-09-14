@testable import CartographSyntax
import Testing

@Suite("Core Data container와 fetch 구문 흐름")
struct CoreDataSourceScannerTests {
    @Test("같은 함수의 불변 container에서 나온 context와 literal request를 연결한다")
    func findsLocalContainerAndFetch() throws {
        let source = """
            import CoreData
            func load() throws {
                let container = NSPersistentContainer(name: "Store")
                container.persistentStoreDescriptions = []
                let context = container.viewContext
                let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
                _ = try context.fetch(request)
            }
            """
        let facts = CoreDataSourceScanner().scan(source: source, path: "/p/Store.swift")
        #expect(facts.boundaries.map(\.kind) == [.coreDataContainer, .coreDataFetch])
        let container = try #require(facts.boundaries.first)
        #expect(container.name == "Store")
        #expect(container.coreDataModelName == "Store")
        #expect(container.reason == nil)
        let fetch = try #require(facts.boundaries.last)
        #expect(fetch.name == "Record")
        #expect(fetch.coreDataModelName == "Store")
        #expect(fetch.coreDataContainerLocation?.line == 3)
        #expect(fetch.coreDataContextLocation?.line == 5)
        #expect(fetch.coreDataRequestLocation?.line == 6)
        #expect(fetch.coreDataResultTypeLocation?.column == 34)
        #expect(fetch.reason == nil)
    }

    @Test("직접 container.viewContext를 써도 같은 지역 container만 연결한다")
    func findsDirectViewContext() throws {
        let source = """
            func load() throws {
                let container = NSPersistentContainer(name: "Store")
                let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
                _ = try container.viewContext.fetch(request)
            }
            """
        let facts = CoreDataSourceScanner().scan(source: source, path: "/p/Store.swift")
        let fetch = try #require(facts.boundaries.last)
        #expect(fetch.kind == .coreDataFetch)
        #expect(fetch.coreDataContextLocation?.line == 4)
        #expect(fetch.reason == nil)
    }

    @Test("parameter나 다른 context의 같은 entity fetch는 연결하지 않는다")
    func rejectsUnprovenContext() throws {
        let source = """
            func load(_ context: NSManagedObjectContext) throws {
                let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
                _ = try context.fetch(request)
            }
            """
        let facts = CoreDataSourceScanner().scan(source: source, path: "/p/Store.swift")
        let fetch = try #require(facts.boundaries.first)
        #expect(fetch.kind == .coreDataFetch)
        #expect(fetch.name == "Record")
        #expect(fetch.coreDataModelName == nil)
        #expect(fetch.reason?.contains("not derived") == true)
    }

    @Test("전역·mutable·조건부 container와 두 인자 model 주입을 미확정으로 남긴다")
    func rejectsUnsupportedContainers() {
        let sources = [
            "let container = NSPersistentContainer(name: \"Store\")",
            "func load() { var container = NSPersistentContainer(name: \"Store\") }",
            "func load() { if ready { let container = NSPersistentContainer(name: \"Store\") } }",
            "func load() { #if DEBUG\n"
                + "let container = NSPersistentContainer(name: \"Store\")\n#endif }",
            "func load() { "
                + "let container = NSPersistentContainer(name: \"Store\", managedObjectModel: model) }",
        ]
        for source in sources {
            let facts = CoreDataSourceScanner().scan(source: source, path: "/p/Store.swift")
            #expect(facts.boundaries.count == 1)
            #expect(facts.boundaries.first?.kind == .coreDataContainer)
            #expect(facts.boundaries.first?.reason != nil)
        }
    }

    @Test("구체적인 fetch result class에는 새 fetch 경계를 만들지 않는다")
    func skipsConcreteGenericFetchResults() {
        let source = """
            func load() throws {
                let container = NSPersistentContainer(name: "Store")
                let context = container.viewContext
                let request = NSFetchRequest<Record>(entityName: "Record")
                _ = try context.fetch(request)
            }
            """
        let facts = CoreDataSourceScanner().scan(source: source, path: "/p/Store.swift")
        #expect(facts.boundaries.map(\.kind) == [.coreDataContainer])
    }

    @Test("let request와 context 객체를 변경하거나 외부로 넘기면 이후 fetch를 연결하지 않는다")
    func invalidatesReferenceMutationsAndEscapes() throws {
        let mutations = [
            "request.entity = NSEntityDescription()",
            "context.persistentStoreCoordinator = nil",
            "mutate(request)",
            "let escaped = request",
            "let closure = { request.entity = NSEntityDescription() }",
            "if ready { request.entity = NSEntityDescription() }",
            "if ready { mutate(request) }",
            "if ready { container.viewContext.persistentStoreCoordinator = nil }",
        ]
        for mutation in mutations {
            let source = """
                func load() throws {
                    let container = NSPersistentContainer(name: "Store")
                    let context = container.viewContext
                    let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
                    \(mutation)
                    _ = try context.fetch(request)
                }
                """
            let facts = CoreDataSourceScanner().scan(source: source, path: "/p/Store.swift")
            let fetch = try #require(facts.boundaries.last)
            #expect(fetch.kind == .coreDataFetch)
            #expect(fetch.reason != nil)
        }
    }
}
