import CoreData
import Foundation

@objc(LegacyRecord)
public final class LegacyRecord: NSManagedObject {}

@objc(CurrentRecord)
public final class CurrentRecord: NSManagedObject {}

if CommandLine.arguments.count == 2 {
    guard let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
        fatalError("Compiled model could not be opened")
    }
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    let record = NSEntityDescription.insertNewObject(forEntityName: "Record", into: context)
    print("loaded=\(NSStringFromClass(type(of: record)))")
}
