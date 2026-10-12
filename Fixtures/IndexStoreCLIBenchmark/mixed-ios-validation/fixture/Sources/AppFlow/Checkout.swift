import BridgeKit
import FeatureAlpha
import FeatureBeta

public func checkout(_ value: Int32) -> Int32 {
    return FeatureAlpha.SharedQuote().run(value) + CGCppBridge(value)
}

public func checkoutBeta(_ value: Int32) -> Int32 {
    return FeatureBeta.SharedQuote().run(value)
}

public func directC(_ value: Int32) -> Int32 {
    return CGBase(value)
}

public func overloadControl() -> Int32 {
    return FeatureAlpha.SharedQuote().quote("control")
}

public func unrelated(_ value: Int32) -> Int32 {
    return value + 500
}
