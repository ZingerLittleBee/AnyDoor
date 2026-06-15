import XCTest
@testable import AnyDoor

final class CaptureToolbarPolicyTests: XCTestCase {
    func testPhase2ModesAreRegionWindowFullscreenInOrder() {
        XCTAssertEqual(CaptureToolbarPolicy.modes, [.region, .window, .fullscreen])
    }

    @MainActor
    func testEveryModeHasASymbolAndLabelKey() {
        for mode in CaptureToolbarPolicy.modes {
            XCTAssertFalse(CaptureToolbarPolicy.symbol(for: mode).isEmpty)
            // label key resolves to a non-empty localized string
            XCTAssertFalse(L(CaptureToolbarPolicy.labelKey(for: mode)).isEmpty)
        }
    }
}
