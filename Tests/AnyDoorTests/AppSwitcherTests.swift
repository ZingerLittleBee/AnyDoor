import XCTest
@testable import AnyDoor

@MainActor
final class AppSwitcherTests: XCTestCase {

    func testToggleActivatesWhenNoMatchingProcessIsRunning() {
        var activateCount = 0
        var fallbackPIDs: [pid_t] = []

        let task = AppSwitcher.toggle(
            runningTargets: [],
            hideFallbackDelay: .milliseconds(10),
            activate: { activateCount += 1 },
            fallbackHide: { fallbackPIDs.append($0) }
        )

        XCTAssertNil(task)
        XCTAssertEqual(activateCount, 1)
        XCTAssertTrue(fallbackPIDs.isEmpty)
    }

    func testToggleActivatesWhenRunningProcessIsInactive() {
        var activateCount = 0
        var hideRequests = 0
        let target = AppSwitcher.Target(
            processIdentifier: 1001,
            isActive: { false },
            isHidden: { false },
            isTerminated: { false },
            requestHide: { hideRequests += 1 }
        )

        let task = AppSwitcher.toggle(
            runningTargets: [target],
            hideFallbackDelay: .milliseconds(10),
            activate: { activateCount += 1 },
            fallbackHide: { _ in XCTFail("unexpected fallback") }
        )

        XCTAssertNil(task)
        XCTAssertEqual(activateCount, 1)
        XCTAssertEqual(hideRequests, 0)
    }

    func testToggleSkipsAccessibilityFallbackWhenAppHidesNormally() async {
        var active = true
        var hidden = false
        var hideRequests = 0
        var fallbackPIDs: [pid_t] = []

        let target = AppSwitcher.Target(
            processIdentifier: 2002,
            isActive: { active },
            isHidden: { hidden },
            isTerminated: { false },
            requestHide: {
                hideRequests += 1
                active = false
                hidden = true
            }
        )

        let task = AppSwitcher.toggle(
            runningTargets: [target],
            hideFallbackDelay: .milliseconds(10),
            activate: { XCTFail("should hide rather than activate") },
            fallbackHide: { fallbackPIDs.append($0) }
        )
        await task?.value

        XCTAssertEqual(hideRequests, 1)
        XCTAssertTrue(fallbackPIDs.isEmpty)
    }

    func testToggleFallsBackToAccessibilityHideWhenAppRemainsActiveAndUnhidden() async {
        var hideRequests = 0
        var fallbackPIDs: [pid_t] = []

        let target = AppSwitcher.Target(
            processIdentifier: 11660,
            isActive: { true },
            isHidden: { false },
            isTerminated: { false },
            requestHide: { hideRequests += 1 }
        )

        let task = AppSwitcher.toggle(
            runningTargets: [target],
            hideFallbackDelay: .milliseconds(10),
            activate: { XCTFail("should hide rather than activate") },
            fallbackHide: { fallbackPIDs.append($0) }
        )
        await task?.value

        XCTAssertEqual(hideRequests, 1)
        XCTAssertEqual(fallbackPIDs, [11660])
    }

    func testToggleHidesActiveInstanceWhenInactiveHelperSharesBundleID() async {
        var helperHideRequests = 0
        var mainHideRequests = 0
        var fallbackPIDs: [pid_t] = []

        let helper = AppSwitcher.Target(
            processIdentifier: 3001,
            isActive: { false },
            isHidden: { false },
            isTerminated: { false },
            requestHide: { helperHideRequests += 1 }
        )
        let mainApp = AppSwitcher.Target(
            processIdentifier: 3002,
            isActive: { true },
            isHidden: { false },
            isTerminated: { false },
            requestHide: { mainHideRequests += 1 }
        )

        let task = AppSwitcher.toggle(
            runningTargets: [helper, mainApp],
            hideFallbackDelay: .milliseconds(10),
            activate: { XCTFail("should hide active instance") },
            fallbackHide: { fallbackPIDs.append($0) }
        )
        await task?.value

        XCTAssertEqual(helperHideRequests, 0)
        XCTAssertEqual(mainHideRequests, 1)
        XCTAssertEqual(fallbackPIDs, [3002])
    }

    func testToggleSkipsFallbackWhenAppTerminatesBeforeGracePeriodExpires() async {
        var terminated = false
        var fallbackPIDs: [pid_t] = []

        let target = AppSwitcher.Target(
            processIdentifier: 4004,
            isActive: { true },
            isHidden: { false },
            isTerminated: { terminated },
            requestHide: {}
        )

        let task = AppSwitcher.toggle(
            runningTargets: [target],
            hideFallbackDelay: .milliseconds(30),
            activate: { XCTFail("should hide") },
            fallbackHide: { fallbackPIDs.append($0) }
        )
        terminated = true
        await task?.value

        XCTAssertTrue(fallbackPIDs.isEmpty)
    }

    func testSubsequentToggleCancelsPendingHideFallback() async {
        var fallbackPIDs: [pid_t] = []
        var activateCount = 0

        let stuckActive = AppSwitcher.Target(
            processIdentifier: 5005,
            isActive: { true },
            isHidden: { false },
            isTerminated: { false },
            requestHide: {}
        )

        let firstTask = AppSwitcher.toggle(
            runningTargets: [stuckActive],
            hideFallbackDelay: .milliseconds(50),
            activate: { XCTFail("first toggle should hide") },
            fallbackHide: { fallbackPIDs.append($0) }
        )

        AppSwitcher.toggle(
            runningTargets: [],
            hideFallbackDelay: .milliseconds(50),
            activate: { activateCount += 1 },
            fallbackHide: { fallbackPIDs.append($0) }
        )

        await firstTask?.value

        XCTAssertEqual(activateCount, 1)
        XCTAssertTrue(fallbackPIDs.isEmpty)
    }
}
