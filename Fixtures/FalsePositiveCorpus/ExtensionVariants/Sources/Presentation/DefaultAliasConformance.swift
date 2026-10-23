import Domain
import Data

public protocol DefaultContract {
    associatedtype Result
    static func result() -> Result
}

extension DefaultContract where Result == DataType {
    public static func result() -> DataType { DataType(31) }
}

extension DefaultToken: DefaultContract {
    public typealias Result = DataType
}

public protocol AliasContract {
    associatedtype Result
    func aliasResult() -> Result
}

public typealias AliasContractName = AliasContract

extension AliasToken: AliasContractName {
    public typealias Result = DataType
    public func aliasResult() -> DataType { DataType(37) }
}
