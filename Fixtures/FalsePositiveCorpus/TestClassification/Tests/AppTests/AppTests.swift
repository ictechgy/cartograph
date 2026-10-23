import App
import XCTest
import Testing

final class ActualTests: XCTestCase {
    func testActual() { XCTAssertEqual(impactLeaf(), 42) }
}

@Test func modernActual() { #expect(impactLeaf() == 42) }

// 정적 그래프에는 invokeClient의 실제 수신자별 특수화가 없다.
// 이 후보를 없애기 위해 다른 테스트의 실제 다형 호출까지 지우면 안 된다.
@Test func siblingOne() { #expect(invokeClient(SiblingClient()) == 2) }
@Test func siblingTwo() { #expect(invokeClient(SiblingClient()) == 2) }
@Test func siblingThree() { #expect(invokeClient(SiblingClient()) == 2) }
@Test func siblingFour() { #expect(invokeClient(SiblingClient()) == 2) }
@Test func siblingFive() { #expect(invokeClient(SiblingClient()) == 2) }
@Test func siblingSix() { #expect(invokeClient(SiblingClient()) == 2) }
@Test func siblingSeven() { #expect(invokeClient(SiblingClient()) == 2) }
@Test func changedReceiverControl() { #expect(invokeClient(ChangedClient()) == 1) }
@Test func directSiblingControl() { #expect(SiblingClient().send() == 2) }
