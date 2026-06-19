import AppKit
import SwiftUI
import XCTest
@testable import AnyDoor

final class HoverPopoverTests: XCTestCase {
    @MainActor
    func testPopoverDoesNotLetHostingViewResizeItsWindow() throws {
        let popover = HoverPopover {
            Text("Popover")
        }

        let panel = try XCTUnwrap(
            Mirror(reflecting: popover).children.first { $0.label == "panel" }?.value as? KeyableHoverPanel
        )
        XCTAssertNil(panel.contentViewController)

        let contentView = try XCTUnwrap(panel.contentView)
        let hostingView = try XCTUnwrap(contentView.subviews.first as? NSHostingView<AnyView>)
        XCTAssertTrue(hostingView.sizingOptions.isEmpty)
    }

    // MARK: - Anchor geometry

    private let screen = NSRect(x: 0, y: 0, width: 1920, height: 1050)

    @MainActor
    func testAnchorAlignsPopoverTopWithRowTopWhenItFits() {
        // Row mid-screen; a 420-tall popover fits below the row top.
        let row = NSRect(x: 100, y: 600, width: 244, height: 36) // top (maxY) = 636
        let origin = HoverPopover.anchorOrigin(
            referenceFrame: row, size: NSSize(width: 320, height: 420), screenFrame: screen
        )
        // To the right of the row.
        XCTAssertEqual(origin.x, row.maxX + 4)
        // Popover top edge equals the row's top edge.
        XCTAssertEqual(origin.y + 420, row.maxY, accuracy: 0.5)
    }

    @MainActor
    func testAnchorClampsUpWhenPopoverWouldOverflowBottom() {
        // Row near the bottom of the screen; a tall popover can't fit below it,
        // so it shifts up and pins to the screen bottom.
        let row = NSRect(x: 100, y: 100, width: 244, height: 36) // top = 136
        let origin = HoverPopover.anchorOrigin(
            referenceFrame: row, size: NSSize(width: 320, height: 420), screenFrame: screen
        )
        XCTAssertEqual(origin.y, screen.minY, accuracy: 0.5)
    }

    @MainActor
    func testAnchorFlipsToLeftWhenNoRoomOnRight() {
        // Row hugging the right edge: not enough room on the right, flip left.
        let row = NSRect(x: 1456, y: 600, width: 244, height: 36) // maxX = 1700
        let size = NSSize(width: 320, height: 420)
        let origin = HoverPopover.anchorOrigin(referenceFrame: row, size: size, screenFrame: screen)
        XCTAssertEqual(origin.x, row.minX - 4 - size.width)
    }
}
