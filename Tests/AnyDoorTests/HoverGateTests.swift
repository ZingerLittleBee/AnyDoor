import Clocks
import XCTest
@testable import AnyDoor

/// These tests drive `HoverGate` with a `TestClock`, so every deadline is
/// advanced explicitly and nothing waits on the wall clock. That is what makes
/// the timing claims exact rather than probabilistic: the old version slept past
/// each deadline and read a counter, which a loaded CI runner raced and failed.
@MainActor
final class HoverGateTests: XCTestCase {
    func testShowImmediatelyRefreshesContentWhenPopoverIsAlreadyShown() {
        let gate = HoverGate(clock: TestClock())
        var showCount = 0
        gate.onShow = { showCount += 1 }

        gate.showImmediately()
        gate.showImmediately()

        // showImmediately stays synchronous (click path wants an instant mount).
        XCTAssertEqual(showCount, 2)
    }

    func testTriggerHoverRefreshesContentWhenAlreadyShownButCoalesced() async {
        let clock = TestClock()
        let gate = HoverGate(clock: clock)
        var showCount = 0
        gate.onShow = { showCount += 1 }

        gate.showImmediately()        // synchronous first show
        XCTAssertEqual(showCount, 1)

        gate.triggerHover(true)       // already shown -> coalesced re-mount, deferred off the tick
        XCTAssertEqual(showCount, 1, "re-mount while shown must be deferred, not synchronous")

        await clock.advance(by: HoverGate.refreshDelay)
        XCTAssertEqual(showCount, 2)
    }

    func testRapidCrossingsWhileShownCoalesceIntoOneRemount() async throws {
        let clock = TestClock()
        let gate = HoverGate(clock: clock)
        var showCount = 0
        gate.onShow = { showCount += 1 }

        gate.showImmediately()        // count 1
        // Simulate a fast sweep across several already-shown hover rows in one burst.
        gate.triggerHover(true)
        gate.triggerHover(true)
        gate.triggerHover(true)

        await clock.advance(by: HoverGate.refreshDelay)
        // The three crossings collapse into a single re-mount (count 1 + 1), not
        // three: each crossing replaces the pending refresh task.
        XCTAssertEqual(showCount, 2)
        // And nothing is still armed — an assertion the sleeping version could
        // only approximate by waiting a while and looking again.
        try await clock.checkSuspension()
    }

    func testRapidRetriggerKeepsFirstShowDeadline() async {
        let clock = TestClock()
        let gate = HoverGate(clock: clock)
        var showCount = 0
        gate.onShow = { showCount += 1 }

        gate.triggerHover(true)                       // arm the show timer at t0
        await clock.advance(by: .milliseconds(200))    // t0 + 200ms
        gate.triggerHover(true)                       // re-trigger must NOT reset the deadline
        XCTAssertEqual(showCount, 0, "nothing may show before the first deadline")

        // Leading edge: the show fires at t0 + 400ms, not 400ms from the
        // re-trigger. A bug that restarted the countdown would need until
        // t0 + 600ms, so the exact boundary is the assertion.
        await clock.advance(by: .milliseconds(199))    // t0 + 399ms
        XCTAssertEqual(showCount, 0)
        await clock.advance(by: .milliseconds(1))      // t0 + 400ms
        XCTAssertEqual(showCount, 1)
    }

    func testUnhoveringHidesAfterTheGracePeriod() async {
        let clock = TestClock()
        let gate = HoverGate(clock: clock)
        var hideCount = 0
        gate.onHide = { hideCount += 1 }

        gate.showImmediately()
        gate.triggerHover(false)                      // cursor leaves the row

        await clock.advance(by: HoverGate.hideDelay - .milliseconds(1))
        XCTAssertEqual(hideCount, 0, "the grace period must not end early")
        XCTAssertTrue(gate.isShown)

        await clock.advance(by: .milliseconds(1))
        XCTAssertEqual(hideCount, 1)
        XCTAssertFalse(gate.isShown)
    }

    func testReenteringDuringTheGracePeriodCancelsTheHide() async throws {
        let clock = TestClock()
        let gate = HoverGate(clock: clock)
        var hideCount = 0
        gate.onHide = { hideCount += 1 }

        gate.showImmediately()
        gate.triggerHover(false)
        await clock.advance(by: .milliseconds(200))    // still inside the 300ms grace
        gate.triggerHover(true)                       // cursor comes back

        await clock.advance(by: .seconds(1))
        XCTAssertEqual(hideCount, 0, "re-entering must cancel the pending hide")
        XCTAssertTrue(gate.isShown)
        try await clock.checkSuspension()
    }
}
