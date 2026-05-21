import XCTest
import Carbon.HIToolbox
@testable import AnyDoor

final class KeyCodeMapTests: XCTestCase {
    func testKnownKeyCodeRoundtrip() {
        XCTAssertEqual(KeyCodeMap.name(for: kVK_F1), "F1")
        XCTAssertEqual(KeyCodeMap.keyCode(for: "F1"), kVK_F1)
    }

    func testReturnSymbol() {
        XCTAssertEqual(KeyCodeMap.name(for: kVK_Return), "↩")
        XCTAssertEqual(KeyCodeMap.keyCode(for: "↩"), kVK_Return)
    }

    func testUnknownKeyCodeFormatsAsKeyN() {
        XCTAssertEqual(KeyCodeMap.name(for: 9999), "Key(9999)")
    }

    func testUnknownNameReturnsNil() {
        XCTAssertNil(KeyCodeMap.keyCode(for: "DefinitelyNotAKey"))
    }
}
