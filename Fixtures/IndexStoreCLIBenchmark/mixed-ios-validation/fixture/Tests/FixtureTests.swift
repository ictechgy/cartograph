import XCTest
import AppFlow

final class QuoteTests: XCTestCase {
    override func setUpWithError() throws {
        _ = checkout(1)
    }

    func testUnrelatedBody() {
        XCTAssertEqual(unrelated(1), 501)
    }

    func testDirectBody() {
        XCTAssertGreaterThan(directC(1), 0)
    }
}

final class OtherTests: XCTestCase {
    func testUnrelated() {
        XCTAssertEqual(unrelated(2), 502)
    }
}
