import XCTest
@testable import AnyDoor

final class CaptureModeBarPolicyTests: XCTestCase {
    func testDigitKeysMapToModes() {
        XCTAssertEqual(CaptureModeBarPolicy.mode(forDigit: 1), .region)
        XCTAssertEqual(CaptureModeBarPolicy.mode(forDigit: 2), .window)
        XCTAssertEqual(CaptureModeBarPolicy.mode(forDigit: 3), .fullscreen)
        XCTAssertNil(CaptureModeBarPolicy.mode(forDigit: 9))
    }

    func testTimerDigitMapsToTimer() {
        XCTAssertTrue(CaptureModeBarPolicy.isTimerDigit(4))
        XCTAssertFalse(CaptureModeBarPolicy.isTimerDigit(1))
    }

    func testOrderedModesForRendering() {
        XCTAssertEqual(CaptureModeBarPolicy.orderedModes, [.region, .window, .fullscreen])
    }
}
