// test 접두사와 extension 위치만으로 앱 메서드를 XCTest로 확정하면 안 된다.
extension DebugPanel {
    public func test_extensionDebug() { _ = impactLeaf() }
}
