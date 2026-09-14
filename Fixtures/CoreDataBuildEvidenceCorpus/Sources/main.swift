import CoreData
import Foundation

func exerciseVerifiedContainer() throws {
    let container = NSPersistentContainer(name: "Store")
    let semaphore = DispatchSemaphore(value: 0)
    var loadError: Error?
    container.persistentStoreDescriptions = [NSPersistentStoreDescription()]
    container.persistentStoreDescriptions[0].type = NSInMemoryStoreType
    container.loadPersistentStores { _, error in
        loadError = error
        semaphore.signal()
    }
    semaphore.wait()
    if let loadError { throw loadError }
    let object = NSEntityDescription.insertNewObject(forEntityName: "Record", into: container.viewContext)
    let context = container.viewContext
    let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
    let fetched = try context.fetch(request)
    try context.save()
    let secondContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    secondContext.persistentStoreCoordinator = container.persistentStoreCoordinator
    let separatelyFetched = try sameEntityFromUnprovenContext(secondContext)
    print(
        "loaded=\(NSStringFromClass(type(of: object)));fetched=\(fetched.count);"
            + "separate=\(separatelyFetched)"
    )
}

func sameEntityFromUnprovenContext(_ context: NSManagedObjectContext) throws -> Int {
    let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
    return try context.fetch(request).count
}

func changedRequestFromLocalContainer() throws {
    let container = NSPersistentContainer(name: "Store")
    let context = container.viewContext
    let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
    request.entity = NSEntityDescription()
    _ = try context.fetch(request)
}

func changedContextFromLocalContainer() throws {
    let container = NSPersistentContainer(name: "Store")
    let context = container.viewContext
    context.persistentStoreCoordinator = nil
    let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
    _ = try context.fetch(request)
}

try exerciseVerifiedContainer()
