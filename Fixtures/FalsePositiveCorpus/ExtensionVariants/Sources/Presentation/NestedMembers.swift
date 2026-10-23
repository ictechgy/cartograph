import Domain
import Data

extension DomainSpace.Nested {
    public struct Adapter {
        public let data: DataType
        public init(_ data: DataType) { self.data = data }
    }

    public static func makeAdapter() -> Adapter { Adapter(DataType(29)) }
}
