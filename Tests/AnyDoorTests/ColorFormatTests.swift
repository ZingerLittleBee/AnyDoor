import XCTest
@testable import AnyDoor

final class ColorFormatTests: XCTestCase {
    func testHexFormatNormalizesToUppercase() {
        XCTAssertEqual(ColorFormat.hex.format(hex: "#ff5733"), "#FF5733")
    }

    func testRGBFormat() {
        XCTAssertEqual(ColorFormat.rgb.format(hex: "#FF5733"), "rgb(255, 87, 51)")
    }

    func testCSSFormatIsLowercaseHex() {
        XCTAssertEqual(ColorFormat.css.format(hex: "#FF5733"), "#ff5733")
    }

    func testSwiftUIFormatUsesThreeDecimals() {
        XCTAssertEqual(
            ColorFormat.swiftUI.format(hex: "#FF5733"),
            "Color(red: 1.000, green: 0.341, blue: 0.200)"
        )
    }

    func testHSLPureRed() {
        XCTAssertEqual(ColorFormat.hsl.format(hex: "#FF0000"), "hsl(0, 100%, 50%)")
    }

    func testHSLGrayHasZeroSaturation() {
        XCTAssertEqual(ColorFormat.hsl.format(hex: "#808080"), "hsl(0, 0%, 50%)")
    }

    func testHSLOrange() {
        XCTAssertEqual(ColorFormat.hsl.format(hex: "#FF5733"), "hsl(11, 100%, 60%)")
    }

    func testInvalidHexReturnsNil() {
        XCTAssertNil(ColorFormat.hex.format(hex: "not-a-color"))
        XCTAssertNil(ColorFormat.rgb.format(hex: "#FFF"))
        XCTAssertNil(ColorFormat.hsl.format(hex: ""))
    }
}
