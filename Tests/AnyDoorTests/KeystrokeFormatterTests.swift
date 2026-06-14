import XCTest
import Carbon.HIToolbox
@testable import AnyDoor

final class KeystrokeFormatterTests: XCTestCase {
    func testPlainLetter() {
        XCTAssertEqual(
            KeystrokeFormatter.display(keyCode: kVK_ANSI_A, control: false, option: false, shift: false, command: false),
            "A"
        )
    }

    func testCommandShiftCanonicalOrder() {
        XCTAssertEqual(
            KeystrokeFormatter.display(keyCode: kVK_ANSI_A, control: false, option: false, shift: true, command: true),
            "⇧⌘A"
        )
    }

    func testAllModifiersOrder() {
        XCTAssertEqual(
            KeystrokeFormatter.display(keyCode: kVK_Space, control: true, option: true, shift: true, command: true),
            "⌃⌥⇧⌘Space"
        )
    }

    func testSpecialKeySymbol() {
        XCTAssertEqual(
            KeystrokeFormatter.display(keyCode: kVK_Return, control: false, option: false, shift: false, command: true),
            "⌘↩"
        )
    }
}
