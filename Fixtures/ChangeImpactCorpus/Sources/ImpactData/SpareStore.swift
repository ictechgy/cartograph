/// 같은 요구사항의 형제 증인이다. LiveStore 구현 변경의 소비자가 되어서는 안 된다.
public struct SpareStore: Store {
    public init() {}
    public func read() -> String { "spare" }
}

public func unrelatedUtility() -> String { "unrelated" }
