public struct LiveStore: Store {
    public init() {}
    public func read() -> String { "live" }
}

extension LiveStore {
    public func extensionOnly() -> String { "extension" }
}
