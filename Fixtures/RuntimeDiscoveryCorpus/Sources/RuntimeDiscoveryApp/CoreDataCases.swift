import CoreData

@objc(CorpusManagedEntity)
final class CorpusManagedEntity: NSManagedObject {}

final class PlainEntity: NSObject {}

func fetchByEntityNameOnly() -> NSFetchRequest<CorpusManagedEntity> {
    NSFetchRequest(entityName: "Managed")
}
