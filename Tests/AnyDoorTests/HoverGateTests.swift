import XCTest
@testable import AnyDoor

final class HoverGateTests: XCTestCase {
    @MainActor
    func testTriggerHoverRefreshesContentWhenPopoverIsAlreadyShown() {
        let gate = HoverGate()
        var showCount = 0
        gate.onShow = { showCount += 1 }

        gate.showImmediately()
        gate.triggerHover(true)

        XCTAssertEqual(showCount, 2)
    }

    @MainActor
    func testShowImmediatelyRefreshesContentWhenPopoverIsAlreadyShown() {
        let gate = HoverGate()
        var showCount = 0
        gate.onShow = { showCount += 1 }

        gate.showImmediately()
        gate.showImmediately()

        XCTAssertEqual(showCount, 2)
    }
}
