import Domain
import Data

public func exerciseVariants() -> Int {
    InferredToken().output().value
        + Box(DataType(23)).item().value
        + DomainSpace.Nested.makeAdapter().data.value
        + DefaultToken.result().value
        + AliasToken().aliasResult().value
}
