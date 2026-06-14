import XCTest
import CoreGraphics
@testable import AnyDoor

final class OverlayPlacementTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 200, height: 80)

    func testPlacesBelowRegionByDefault() {
        // Region high on screen -> overlay sits just below it (lower y in AppKit).
        let region = CGRect(x: 400, y: 500, width: 200, height: 150)
        let frame = OverlayPlacement.frame(forRegion: region, overlaySize: size, onScreen: screen, gap: 12)
        XCTAssertEqual(frame.maxY, region.minY - 12, accuracy: 0.001)
        XCTAssertTrue(screen.contains(frame))
    }

    func testFlipsAboveWhenNoRoomBelow() {
        // Region near the bottom -> no room below, overlay goes above it.
        let region = CGRect(x: 400, y: 0, width: 200, height: 60)
        let frame = OverlayPlacement.frame(forRegion: region, overlaySize: size, onScreen: screen, gap: 12)
        XCTAssertEqual(frame.minY, region.maxY + 12, accuracy: 0.001)
        XCTAssertTrue(screen.contains(frame))
    }

    func testFallbackBottomRightWhenNoRegion() {
        let frame = OverlayPlacement.fallbackFrame(overlaySize: size, onScreen: screen, margin: 16)
        XCTAssertEqual(frame.maxX, screen.maxX - 16, accuracy: 0.001)
        XCTAssertEqual(frame.minY, screen.minY + 16, accuracy: 0.001)
    }

    func testClampsHorizontallyIntoScreen() {
        let region = CGRect(x: 950, y: 400, width: 40, height: 40)
        let frame = OverlayPlacement.frame(forRegion: region, overlaySize: size, onScreen: screen, gap: 12)
        XCTAssertTrue(screen.contains(frame))
    }
}
