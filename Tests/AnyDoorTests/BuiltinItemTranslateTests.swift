import XCTest
@testable import AnyDoor

final class BuiltinItemTranslateTests: XCTestCase {
    func testNewCasesExist() {
        XCTAssertNotNil(BuiltinItem(rawValue: "translate"))
        XCTAssertNotNil(BuiltinItem(rawValue: "screenshotTranslate"))
        XCTAssertNotNil(BuiltinItem(rawValue: "translateSelection"))
    }

    func testTranslateKindsAreAction() {
        XCTAssertEqual(BuiltinItem.translate.kind, .action)
        XCTAssertEqual(BuiltinItem.screenshotTranslate.kind, .action)
        XCTAssertEqual(BuiltinItem.translateSelection.kind, .action)
    }

    func testTranslateTitleKeys() {
        XCTAssertEqual(BuiltinItem.translate.titleKey, .builtinTranslate)
        XCTAssertEqual(BuiltinItem.screenshotTranslate.titleKey, .builtinScreenshotTranslate)
        XCTAssertEqual(BuiltinItem.translateSelection.titleKey, .builtinTranslateSelection)
    }

    func testTranslateSymbols() {
        XCTAssertEqual(BuiltinItem.translate.symbol, "character.bubble")
        XCTAssertEqual(BuiltinItem.screenshotTranslate.symbol, "text.viewfinder")
        XCTAssertEqual(BuiltinItem.translateSelection.symbol, "text.cursor")
    }

    func testTranslateDefaultOrders() {
        XCTAssertEqual(BuiltinItem.translate.defaultOrder, 980)
        XCTAssertEqual(BuiltinItem.screenshotTranslate.defaultOrder, 982)
        XCTAssertEqual(BuiltinItem.translateSelection.defaultOrder, 984)
    }

    func testTranslateDoesNotRequireAutomation() {
        XCTAssertFalse(BuiltinItem.translate.requiresAutomation)
        XCTAssertFalse(BuiltinItem.screenshotTranslate.requiresAutomation)
        XCTAssertFalse(BuiltinItem.translateSelection.requiresAutomation)
    }

    func testTranslateDefaultVisibilityTrue() {
        XCTAssertTrue(BuiltinItem.translate.defaultVisibility)
        XCTAssertTrue(BuiltinItem.screenshotTranslate.defaultVisibility)
        XCTAssertTrue(BuiltinItem.translateSelection.defaultVisibility)
    }

    func testTranslateInAllCases() {
        XCTAssertTrue(BuiltinItem.allCases.contains(.translate))
        XCTAssertTrue(BuiltinItem.allCases.contains(.screenshotTranslate))
        XCTAssertTrue(BuiltinItem.allCases.contains(.translateSelection))
    }
}
