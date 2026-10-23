import Domain
import Data

public protocol InferredContract {
    associatedtype Output
    func output() -> Output
}

extension InferredToken: InferredContract {
    public func output() -> DataType { DataType(11) }
}
