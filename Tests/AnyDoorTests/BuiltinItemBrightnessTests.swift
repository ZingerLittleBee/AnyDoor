import XCTest
@testable import AnyDoor

final class BuiltinItemBrightnessTests: XCTestCase {
    func testNewCasesExist() {
        XCTAssertNotNil(BuiltinItem(rawValue: "brightness"))
        XCTAssertNotNil(BuiltinItem(rawValue: "brightnessUp"))
        XCTAssertNotNil(BuiltinItem(rawValue: "brightnessDown"))
    }

    func testBrightnessKindIsBrightnessControl() {
        XCTAssertEqual(BuiltinItem.brightness.kind, .brightnessControl)
    }

    func testBumpHotkeysAreHiddenKind() {
        XCTAssertEqual(BuiltinItem.brightnessUp.kind, .hiddenHotkey)
        XCTAssertEqual(BuiltinItem.brightnessDown.kind, .hiddenHotkey)
    }

    func testDefaultVisibilityFalseForHiddenHotkeys() {
        XCTAssertFalse(BuiltinItem.brightnessUp.defaultVisibility)
        XCTAssertFalse(BuiltinItem.brightnessDown.defaultVisibility)
    }

    func testDefaultVisibilityTrueForRegularItems() {
        XCTAssertTrue(BuiltinItem.brightness.defaultVisibility)
        XCTAssertTrue(BuiltinItem.keepAwake.defaultVisibility)
        XCTAssertTrue(BuiltinItem.appShortcuts.defaultVisibility)
        XCTAssertTrue(BuiltinItem.ocr.defaultVisibility)
    }

    func testBrightnessTitleAndSymbol() {
        XCTAssertEqual(BuiltinItem.brightness.titleKey, .builtinBrightness)
        XCTAssertEqual(BuiltinItem.brightness.symbol, "sun.max")
    }

    func testBumpRowsExcludedFromAllCasesIteration() {
        // Sanity: they are in allCases so .allCases iteration in seeder picks them up
        XCTAssertTrue(BuiltinItem.allCases.contains(.brightnessUp))
        XCTAssertTrue(BuiltinItem.allCases.contains(.brightnessDown))
    }
}
