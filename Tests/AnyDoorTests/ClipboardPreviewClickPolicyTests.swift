import AppKit
import XCTest
@testable import AnyDoor

final class ClipboardPreviewClickPolicyTests: XCTestCase {
    private let previewFrame = NSRect(x: 400, y: 300, width: 600, height: 400)

    func testWindowlessClickInsidePreviewDoesNotDismiss() {
        // Model an event without a host-process NSWindow, such as a global
        // mouse event. This pins classification, not the renderer's routing.
        XCTAssertTrue(contains(window: nil, point: NSPoint(x: 700, y: 320)))
    }

    func testWindowlessClickOutsidePreviewDismisses() {
        XCTAssertFalse(contains(window: nil, point: NSPoint(x: 700, y: 200)))
    }

    func testLocalPreviewClickStaysInside() {
        XCTAssertTrue(contains(window: 42, point: NSPoint(x: 700, y: 500)))
    }

    func testClickOnWallRemainsOutsidePreview() {
        XCTAssertFalse(contains(window: 43, point: NSPoint(x: 700, y: 100)))
    }

    func testKnownOverlappingWindowDoesNotBecomeAPreviewClick() {
        XCTAssertFalse(contains(window: 43, point: NSPoint(x: 700, y: 500)))
    }

    func testWindowlessClickUsesTheCurrentFrameAfterMovingPreview() {
        let moved = previewFrame.offsetBy(dx: -1200, dy: -500)
        XCTAssertTrue(contains(window: nil, point: NSPoint(x: -700, y: -100), frame: moved))
        XCTAssertFalse(contains(window: nil, point: NSPoint(x: 700, y: 500), frame: moved))
    }

    func testWindowlessClickBeyondFrameEdgesRemainsOutside() {
        for point in [
            NSPoint(x: 399, y: 500), NSPoint(x: 1001, y: 500),
            NSPoint(x: 700, y: 299), NSPoint(x: 700, y: 701),
        ] {
            XCTAssertFalse(contains(window: nil, point: point))
        }
    }

    private func contains(window: Int?, point: NSPoint, frame: NSRect? = nil) -> Bool {
        ClipboardPreviewClickPolicy.isInsidePreview(
            eventWindowNumber: window,
            previewWindowNumber: 42,
            previewFrame: frame ?? previewFrame,
            screenLocation: point
        )
    }
}
