import XCTest
import CoreGraphics
@testable import AnyDoor

final class WindowEnumeratorTests: XCTestCase {
    func testTopmostWindowUnderPointWins() {
        // Listed front-to-back (index 0 == frontmost), matching CGWindowList order.
        let windows = [
            CapturableWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            CapturableWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 200, height: 200)),
        ]
        let hit = WindowEnumerator.window(under: CGPoint(x: 50, y: 50), in: windows)
        XCTAssertEqual(hit?.id, 1)
    }

    func testPointOutsideAllReturnsNil() {
        let windows = [CapturableWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10))]
        XCTAssertNil(WindowEnumerator.window(under: CGPoint(x: 99, y: 99), in: windows))
    }

    func testFallsThroughToLowerWindow() {
        let windows = [
            CapturableWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 50, height: 50)),
            CapturableWindow(id: 2, frame: CGRect(x: 100, y: 100, width: 50, height: 50)),
        ]
        let hit = WindowEnumerator.window(under: CGPoint(x: 120, y: 120), in: windows)
        XCTAssertEqual(hit?.id, 2)
    }
}
