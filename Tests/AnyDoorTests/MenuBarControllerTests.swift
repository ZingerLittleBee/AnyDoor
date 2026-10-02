import AppKit
import ClipboardHistoryTestSupport
import SwiftData
import XCTest
@testable import AnyDoor
@testable import ClipboardHistory

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

    @MainActor
    func testPanelScrollViewHidesScrollers() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.verticalScroller?.scrollerStyle = .legacy

        MenuBarController.configurePanelScrollView(scrollView)

        XCTAssertFalse(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertTrue(scrollView.autohidesScrollers)
        XCTAssertFalse(scrollView.drawsBackground)
        XCTAssertFalse(scrollView.automaticallyAdjustsContentInsets)
        XCTAssertNil(scrollView.verticalScroller)
        XCTAssertNil(scrollView.horizontalScroller)
    }

    /// A history copy that finishes after its panel closed, or after the
    /// panel was opened again, must neither close nor paste from the newer
    /// showing.
    func testPanelSessionEndsWithItsShowing() {
        var sessions = MenuBarPanelSessions()
        let first = sessions.begin()
        XCTAssertTrue(sessions.isCurrent(first))

        sessions.end()
        XCTAssertFalse(sessions.isCurrent(first))

        let second = sessions.begin()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(sessions.isCurrent(first))
        XCTAssertTrue(sessions.isCurrent(second))

        let third = sessions.begin()
        XCTAssertFalse(sessions.isCurrent(second))
        XCTAssertTrue(sessions.isCurrent(third))
    }

    /// `closePanelIfCurrent` from a panel that Esc or a click elsewhere
    /// already closed returns false and leaves the newer panel open.
    func testAStalePanelSessionNeverClosesANewerPanel() {
        var sessions = MenuBarPanelSessions()
        let stale = sessions.begin()
        sessions.end()
        let newer = sessions.begin()

        XCTAssertFalse(sessions.endIfCurrent(stale))
        XCTAssertTrue(sessions.isCurrent(newer))

        XCTAssertTrue(sessions.endIfCurrent(newer))
        XCTAssertFalse(sessions.isCurrent(newer))
        XCTAssertFalse(sessions.endIfCurrent(newer))
    }

    /// The controller's wiring of the sessions: Esc or a click elsewhere
    /// ends the panel's session, so a commit from it neither closes the next
    /// panel nor counts as coming from an open one.
    @MainActor
    func testHidingThePanelEndsTheSessionThatAStaleCommitHolds() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let stale = controller.beginPanelSessionForTesting()
        XCTAssertTrue(controller.isPanelCurrent(stale))

        controller.hidePanelForTesting()
        XCTAssertFalse(controller.isPanelCurrent(stale))
        XCTAssertFalse(controller.closePanel(ifCurrent: stale))

        let newer = controller.beginPanelSessionForTesting()
        XCTAssertFalse(controller.closePanel(ifCurrent: stale))
        XCTAssertFalse(controller.isPanelCurrent(stale))
        XCTAssertTrue(controller.isPanelCurrent(newer))

        XCTAssertTrue(controller.closePanel(ifCurrent: newer))
        XCTAssertFalse(controller.isPanelCurrent(newer))
    }

    @MainActor
    private func makeController() throws -> MenuBarController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-MenuBarController-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        removeClipboardHistoryDirectoryAfterTest(directory)
        let module = try trackClipboardHistoryModule(
            ClipboardHistoryModule(
                testingDatabaseURL: directory
                    .appendingPathComponent("history.sqlite"),
                databaseKey: Data(repeating: 0x42, count: 32)
            )
        )
        let container = try ModelContainer(
            for: KeyBinding.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return MenuBarController(
            modelContainer: container,
            clipboardHistoryModule: module
        )
    }
}
