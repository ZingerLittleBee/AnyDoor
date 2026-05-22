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
}
