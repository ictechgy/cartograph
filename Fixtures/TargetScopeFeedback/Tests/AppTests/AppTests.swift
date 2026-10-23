import XCTest
@testable import App

final class AppTests: XCTestCase {
    func testChangedValue() { XCTAssertEqual(changedValue(), 42) }
}
