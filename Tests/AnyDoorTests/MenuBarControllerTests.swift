import AppKit
import XCTest
@testable import AnyDoor

final class MenuBarControllerTests: XCTestCase {
    @MainActor
    func testPanelOriginStartsDirectlyBelowStatusItemWhenThereIsRoomOnRight() {
        let statusItemFrame = NSRect(x: 1052, y: 900, width: 31, height: 24)
        let panelSize = NSSize(width: 260, height: 400)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1512, height: 944)

        let origin = MenuBarController.panelOrigin(
            forStatusItemFrame: statusItemFrame,
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(origin.x, statusItemFrame.minX)
        XCTAssertEqual(origin.y, statusItemFrame.minY - panelSize.height - 4)
    }

    func testClickMonitorPolicyKeepsPanelOpenForOwnedWindows() {
        let ownedWindows: Set<Int> = [30, 40]

        XCTAssertEqual(
            MenuBarEventMonitorPolicy.clickDecision(
                clickWindowNumber: 10,
                panelWindowNumber: 10,
                statusWindowNumber: 20,
                hoverPanelWindowNumbers: ownedWindows
            ),
            .keepOpen
        )
        XCTAssertEqual(
            MenuBarEventMonitorPolicy.clickDecision(
                clickWindowNumber: 20,
                panelWindowNumber: 10,
                statusWindowNumber: 20,
                hoverPanelWindowNumbers: ownedWindows
            ),
            .keepOpen
        )
        XCTAssertEqual(
            MenuBarEventMonitorPolicy.clickDecision(
                clickWindowNumber: 30,
                panelWindowNumber: 10,
                statusWindowNumber: 20,
                hoverPanelWindowNumbers: ownedWindows
            ),
            .keepOpen
        )
    }

    func testClickMonitorPolicyClosesForOutsideClicks() {
        XCTAssertEqual(
            MenuBarEventMonitorPolicy.clickDecision(
                clickWindowNumber: 99,
                panelWindowNumber: 10,
                statusWindowNumber: 20,
                hoverPanelWindowNumbers: [30]
            ),
            .close
        )
        XCTAssertEqual(
            MenuBarEventMonitorPolicy.clickDecision(
                clickWindowNumber: nil,
                panelWindowNumber: 10,
                statusWindowNumber: 20,
                hoverPanelWindowNumbers: [30]
            ),
            .close
        )
    }

    func testGlobalClickMonitorPolicyKeepsPanelOpenForOwnedFrames() {
        let panel = NSRect(x: 100, y: 100, width: 260, height: 400)
        let statusItem = NSRect(x: 180, y: 510, width: 31, height: 24)
        let hover = NSRect(x: 365, y: 100, width: 260, height: 300)

        XCTAssertEqual(
            MenuBarEventMonitorPolicy.globalClickDecision(
                mouseLocation: NSPoint(x: 120, y: 120),
                panelFrame: panel,
                statusItemFrame: statusItem,
                hoverPanelFrames: [hover]
            ),
            .keepOpen
        )
        XCTAssertEqual(
            MenuBarEventMonitorPolicy.globalClickDecision(
                mouseLocation: NSPoint(x: 190, y: 520),
                panelFrame: panel,
                statusItemFrame: statusItem,
                hoverPanelFrames: [hover]
            ),
            .keepOpen
        )
        XCTAssertEqual(
            MenuBarEventMonitorPolicy.globalClickDecision(
                mouseLocation: NSPoint(x: 400, y: 160),
                panelFrame: panel,
                statusItemFrame: statusItem,
                hoverPanelFrames: [hover]
            ),
            .keepOpen
        )
    }

    func testGlobalClickMonitorPolicyClosesForOutsideFrames() {
        XCTAssertEqual(
            MenuBarEventMonitorPolicy.globalClickDecision(
                mouseLocation: NSPoint(x: 20, y: 20),
                panelFrame: NSRect(x: 100, y: 100, width: 260, height: 400),
                statusItemFrame: NSRect(x: 180, y: 510, width: 31, height: 24),
                hoverPanelFrames: [NSRect(x: 365, y: 100, width: 260, height: 300)]
            ),
            .close
        )
    }

    func testEscapePolicyClosesAndConsumesOnlyEscape() {
        XCTAssertEqual(MenuBarEventMonitorPolicy.escapeDecision(keyCode: 53), .closeAndConsume)
        XCTAssertEqual(MenuBarEventMonitorPolicy.escapeDecision(keyCode: 36), .ignore)
    }
}
