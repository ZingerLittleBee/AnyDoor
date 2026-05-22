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
}
