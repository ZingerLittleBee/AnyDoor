import XCTest
import AppKit
@testable import AnyDoor

final class ColorHexTests: XCTestCase {

    func testBlackProducesAllZeroes() {
        XCTAssertEqual(NSColor.black.sRGBHexString, "#000000")
    }

    func testWhiteProducesAllFs() {
        XCTAssertEqual(NSColor.white.sRGBHexString, "#FFFFFF")
    }

    func testMidToneColorRoundsEachChannel() {
        // 0.5*255=127.5→128 (0x80), 0.25*255=63.75→64 (0x40), 0.75*255=191.25→191 (0xBF)
        let color = NSColor(srgbRed: 0.5, green: 0.25, blue: 0.75, alpha: 1)
        XCTAssertEqual(color.sRGBHexString, "#8040BF")
    }

    func testComponentsOutsideUnitRangeAreClamped() {
        // Wide-gamut conversions can yield components slightly outside 0...1.
        // red 1.4 clamps to 1→FF, green -0.2 clamps to 0→00, blue 1.0→FF.
        let color = NSColor(srgbRed: 1.4, green: -0.2, blue: 1.0, alpha: 1)
        XCTAssertEqual(color.sRGBHexString, "#FF00FF")
    }
}
