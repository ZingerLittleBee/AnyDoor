import AppKit
import XCTest
@testable import AnyDoor

final class ClipboardPreviewMenuHitTestingTests: XCTestCase {
    private let submenu = ClipboardPreviewMenuHitTesting.Window(
        frame: CGRect(x: 1100, y: 500, width: 160, height: 260),
        level: NSWindow.Level.popUpMenu.rawValue
    )
    private let speedItem = CGPoint(x: 1180, y: 590)

    func testSpeedSubmenuOutsidePreviewIsAnInsideInteraction() {
        // The submenu lies entirely beyond the old preview-only hit region.
        let preview = CGRect(x: 400, y: 200, width: 600, height: 400)
        XCTAssertFalse(preview.contains(speedItem))
        XCTAssertTrue(ClipboardPreviewMenuHitTesting.containsMenu(at: speedItem, in: [submenu]))
    }

    func testClickOutsideAllMenusRemainsOutside() {
        XCTAssertFalse(ClipboardPreviewMenuHitTesting.containsMenu(
            at: CGPoint(x: 1000, y: 590), in: [submenu]
        ))
    }

    func testMenuDoesNotProtectItsOldRegionAfterClosing() {
        XCTAssertFalse(ClipboardPreviewMenuHitTesting.containsMenu(at: speedItem, in: []))
    }

    func testCoveringNonMenuWindowWinsOverMenuBehindIt() {
        let covering = ClipboardPreviewMenuHitTesting.Window(
            frame: submenu.frame, level: NSWindow.Level.screenSaver.rawValue
        )
        XCTAssertFalse(ClipboardPreviewMenuHitTesting.containsMenu(
            at: speedItem, in: [covering, submenu]
        ))
    }

    func testTransparentAndClickThroughOverlaysDoNotBlockMenu() {
        var transparent = submenu
        transparent.alpha = 0
        var tooltip = submenu
        tooltip.ignoresMouseEvents = true
        XCTAssertTrue(ClipboardPreviewMenuHitTesting.containsMenu(
            at: speedItem, in: [transparent, tooltip, submenu]
        ))
        XCTAssertFalse(ClipboardPreviewMenuHitTesting.containsMenu(
            at: speedItem, in: [transparent, tooltip]
        ))
    }

    func testOrdinaryFloatingWindowIsNotAMenu() {
        // The legacy submenu/torn-off level aliases the ordinary floating
        // level; it cannot identify a transient popup menu.
        let floating = ClipboardPreviewMenuHitTesting.Window(
            frame: submenu.frame, level: NSWindow.Level.floating.rawValue
        )
        XCTAssertFalse(ClipboardPreviewMenuHitTesting.containsMenu(at: speedItem, in: [floating]))
    }

    func testSubmenuOnNegativeCoordinateDisplay() {
        let otherDisplayMenu = ClipboardPreviewMenuHitTesting.Window(
            frame: submenu.frame.offsetBy(dx: -1920, dy: -1080), level: submenu.level
        )
        XCTAssertTrue(ClipboardPreviewMenuHitTesting.containsMenu(
            at: CGPoint(x: speedItem.x - 1920, y: speedItem.y - 1080),
            in: [otherDisplayMenu]
        ))
    }

    func testEventReceiverWinsOverRemotePointerOverlay() {
        var target = submenu
        target.number = 42
        let overlay = ClipboardPreviewMenuHitTesting.Window(
            frame: submenu.frame, level: NSWindow.Level.popUpMenu.rawValue + 1, number: 43
        )
        XCTAssertTrue(ClipboardPreviewMenuHitTesting.containsMenu(
            at: speedItem, in: [overlay, target], targetWindowNumber: 42
        ))
        XCTAssertFalse(ClipboardPreviewMenuHitTesting.containsMenu(
            at: speedItem, in: [overlay, target], targetWindowNumber: 43
        ))
    }

    func testMissingEventReceiverDoesNotFallBackToAnotherMenu() {
        XCTAssertFalse(ClipboardPreviewMenuHitTesting.containsMenu(
            at: speedItem, in: [submenu], targetWindowNumber: 42
        ))
    }

    @MainActor
    func testWindowlessEventAdapterUsesQuartzLocationAndReceivingWindow() async throws {
        var target = submenu
        target.number = 42
        let overlay = ClipboardPreviewMenuHitTesting.Window(
            frame: submenu.frame, level: NSWindow.Level.popUpMenu.rawValue + 1, number: 43
        )
        let cgEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: speedItem, mouseButton: .left
        ))
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: 42)
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        XCTAssertNil(event.window)
        XCTAssertTrue(ClipboardPreviewMenuHitTesting.contains(event, loadWindows: { [overlay, target] }))
    }

    @MainActor
    func testWindowlessEventAdapterWithoutReceiverUsesVisibleWindowOrder() async throws {
        let cgEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: speedItem, mouseButton: .left
        ))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        XCTAssertNil(event.window)
        XCTAssertTrue(ClipboardPreviewMenuHitTesting.contains(event, loadWindows: { [submenu] }))
        XCTAssertFalse(ClipboardPreviewMenuHitTesting.contains(event, loadWindows: { [] }))
    }
}
