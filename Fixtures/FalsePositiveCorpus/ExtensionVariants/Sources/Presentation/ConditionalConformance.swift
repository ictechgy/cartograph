import Domain
import Data

public protocol ConditionalContract {
    associatedtype Item
    func item() -> Item
}

extension Box: ConditionalContract where Value == DataType {
    public func item() -> DataType { value }
}
