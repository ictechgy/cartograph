import App
import XCTest

// 실제 XCTest 소유자와 메서드가 다른 파일에 있는 컴파일러 확장 관계를 확인한다.
extension ActualTests {
    func testExtensionActual() { XCTAssertEqual(impactLeaf(), 42) }
}
