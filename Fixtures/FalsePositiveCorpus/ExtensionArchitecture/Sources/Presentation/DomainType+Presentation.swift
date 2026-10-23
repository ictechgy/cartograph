import Domain
import Data

public protocol AppProtocol {
    associatedtype Payload
    var original: DomainType { get }
    func payload() -> Payload
}

extension DomainType: AppProtocol {
    public typealias Payload = DataType
    public var original: DomainType { self }
    public func payload() -> DataType { DataType() }
}

public func exerciseExtension() {
    _ = DomainType().payload()
}
