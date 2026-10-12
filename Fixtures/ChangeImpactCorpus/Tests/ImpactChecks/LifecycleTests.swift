import ImpactData
import XCTest

final class LifecycleSetupTests: XCTestCase {
    override func setUp() { XCTAssertEqual(lifecycleValue(), 42) }
    func testReady() { XCTAssertTrue(true) }
}

final class LifecycleDirectTests: XCTestCase {
    func testDirect() { XCTAssertEqual(lifecycleValue(), 42) }
}

final class LifecycleUnrelatedTests: XCTestCase {
    func unusedHelper() -> Int { lifecycleValue() }
    func testUnrelated() { XCTAssertEqual(1, 1) }
}
