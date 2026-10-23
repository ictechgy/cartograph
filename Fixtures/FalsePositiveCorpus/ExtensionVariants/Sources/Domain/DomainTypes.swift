public struct InferredToken { public init() {} }
public struct DefaultToken { public init() {} }
public struct AliasToken { public init() {} }

public struct Box<Value> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

public enum DomainSpace {
    public struct Nested { public init() {} }
}
