import XCTest
@testable import AnyDoor

final class HoverGateTests: XCTestCase {
    @MainActor
    func testShowImmediatelyRefreshesContentWhenPopoverIsAlreadyShown() {
        let gate = HoverGate()
        var showCount = 0
        gate.onShow = { showCount += 1 }

        gate.showImmediately()
        gate.showImmediately()

        // showImmediately stays synchronous (click path wants an instant mount).
        XCTAssertEqual(showCount, 2)
    }

    @MainActor
    func testTriggerHoverRefreshesContentWhenAlreadyShownButCoalesced() async {
        let gate = HoverGate()
        var showCount = 0
        gate.onShow = { showCount += 1 }

        gate.showImmediately()        // synchronous first show
        XCTAssertEqual(showCount, 1)

        gate.triggerHover(true)       // already shown -> coalesced re-mount, deferred off the tick
        XCTAssertEqual(showCount, 1, "re-mount while shown must be deferred, not synchronous")

        // The coalesced refresh fires on a later runloop turn.
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(showCount, 2)
    }

    @MainActor
    func testRapidCrossingsWhileShownCoalesceIntoOneRemount() async {
        let gate = HoverGate()
        var showCount = 0
        gate.onShow = { showCount += 1 }

        gate.showImmediately()        // count 1
        // Simulate a fast sweep across several already-shown hover rows in one burst.
        gate.triggerHover(true)
        gate.triggerHover(true)
        gate.triggerHover(true)

        try? await Task.sleep(nanoseconds: 80_000_000)
        // The three crossings collapse into a single re-mount (count 1 + 1), not three.
        XCTAssertEqual(showCount, 2)
    }

    @MainActor
    func testRapidRetriggerKeepsFirstShowDeadline() async {
        let gate = HoverGate()
        var showCount = 0
        let shown = expectation(description: "popover shown once")
        gate.onShow = {
            showCount += 1
            if showCount == 1 { shown.fulfill() }
        }

        gate.triggerHover(true)                          // arm the show timer at t0
        try? await Task.sleep(nanoseconds: 200_000_000)  // t0 + 200ms
        gate.triggerHover(true)                          // re-trigger must NOT reset the deadline

        // With the leading-edge timer the show fires ~200ms from now (t0 + 400ms).
        // A bug that restarts the 400ms countdown would fire ~400ms from now
        // (t0 + 600ms) and miss this window.
        await fulfillment(of: [shown], timeout: 0.30)
        XCTAssertEqual(showCount, 1)
    }
}
