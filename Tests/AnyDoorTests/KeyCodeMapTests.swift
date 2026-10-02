import XCTest
import Carbon.HIToolbox
@testable import AnyDoor

final class KeyCodeMapTests: XCTestCase {
    func testKnownKeyCodeName() {
        XCTAssertEqual(KeyCodeMap.name(for: kVK_F1), "F1")
    }

    func testReturnSymbol() {
        XCTAssertEqual(KeyCodeMap.name(for: kVK_Return), "↩")
    }

    func testUnknownKeyCodeFormatsAsKeyN() {
        XCTAssertEqual(KeyCodeMap.name(for: 9999), "Key(9999)")
    }
}
