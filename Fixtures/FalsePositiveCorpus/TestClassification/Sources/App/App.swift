public func impactLeaf() -> Int { 42 }

// 실제 앱의 디버깅 이름을 일반화했다. XCTest를 상속하지 않는다.
public final class DebugPanel {
    public init() {}
    public func test_debugOne() { _ = impactLeaf() }
    public func test_debugTwo() { _ = impactLeaf() }
    public func test_debugThree() { _ = impactLeaf() }
    public func test_debugFour() { _ = impactLeaf() }
    public func test_debugFive() { _ = impactLeaf() }
    public func ordinaryControl() -> Int { impactLeaf() }
}

public protocol Client { func send() -> Int }
public struct ChangedClient: Client {
    public init() {}
    public func send() -> Int { 1 }
}
public struct SiblingClient: Client {
    public init() {}
    public func send() -> Int { 2 }
}
public func invokeClient(_ client: any Client) -> Int { client.send() }
