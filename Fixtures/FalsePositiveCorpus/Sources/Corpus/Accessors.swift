/// 접근자 본문에서만 부르는 코드. 게터는 정점이 아니라 간선이 사라지기 쉽다.
public func calledOnlyFromGetter() -> Int { 1 }
public func calledOnlyFromWillSet() -> Int { 3 }
public func neverCalledAtAll() -> Int { 4 }

public struct AccessorHost {
    public init() {}
    public var fromGetter: Int { calledOnlyFromGetter() }
    public var observed: Int = 0 {
        willSet { _ = calledOnlyFromWillSet() }
    }
}
