import XCTest
@testable import AnyDoor

final class CaptureToolbarPolicyTests: XCTestCase {
    func testToolsAreTheFiveCaptureTypesInOrder() {
        XCTAssertEqual(CaptureToolbarPolicy.tools,
                       [.region, .window, .fullscreen, .scrolling, .recording])
    }

    @MainActor
    func testEveryToolHasASymbolAndLabelKey() {
        for tool in CaptureToolbarPolicy.tools {
            XCTAssertFalse(CaptureToolbarPolicy.symbol(for: tool).isEmpty)
            XCTAssertFalse(L(CaptureToolbarPolicy.labelKey(for: tool)).isEmpty)
        }
    }
}
