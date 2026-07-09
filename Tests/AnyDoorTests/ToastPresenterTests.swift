import AppKit
import SwiftUI
import XCTest
@testable import AnyDoor

final class ToastPresenterTests: XCTestCase {
    func testInfoToastUsesNonFailureDuration() {
        XCTAssertEqual(ToastStyle.info("Fallback").message, "Fallback")
        XCTAssertEqual(ToastStyle.info("Fallback").displayDuration, ToastStyle.success("Fallback").displayDuration)
    }

    @MainActor
    func testToastDoesNotLetHostingViewResizeItsWindow() throws {
        let presenter = ToastPresenter.shared

        let panel = try XCTUnwrap(
            Mirror(reflecting: presenter).children.first { $0.label == "panel" }?.value as? NSPanel
        )
        XCTAssertNil(panel.contentViewController)

        let contentView = try XCTUnwrap(panel.contentView)
        let hostingView = try XCTUnwrap(contentView.subviews.first as? NSHostingView<ToastView>)
        XCTAssertTrue(hostingView.sizingOptions.isEmpty)
    }
}
