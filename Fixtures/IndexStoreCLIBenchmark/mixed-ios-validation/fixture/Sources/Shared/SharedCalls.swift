import BridgeKit

public protocol QuoteSource {}

public extension QuoteSource {
    func extensionQuote(_ value: Int32) -> Int32 {
        return CGBridge(value)
    }
}

public struct SharedQuote: QuoteSource {
    public init() {}

    public func quote(_ value: Int32) -> Int32 {
        return CGQuoteEngine.quote(value)
    }

    public func quote(_ value: String) -> Int32 {
        return 0
    }

    public func run(_ value: Int32) -> Int32 {
        return quote(value) + extensionQuote(value)
    }

    public func untouched(_ value: Int32) -> Int32 {
        return value
    }
}
