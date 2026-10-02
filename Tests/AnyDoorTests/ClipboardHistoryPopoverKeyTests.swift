import AppKit
import Carbon.HIToolbox
import XCTest
@testable import AnyDoor

/// The keys a menu-bar history popover acts on, and how ⌥ changes Return.
final class ClipboardHistoryPopoverKeyTests: XCTestCase {
    func testReturnAndKeypadEnterCommitTheSelection() {
        XCTAssertEqual(key(kVK_Return), .commit(plain: false))
        XCTAssertEqual(key(kVK_ANSI_KeypadEnter), .commit(plain: false))
    }

    /// ⌥↵ pastes plain text in the popover too, as it does in the wall.
    func testOptionReturnCommitsAsPlainText() {
        XCTAssertEqual(key(kVK_Return, [.option]), .commit(plain: true))
        XCTAssertEqual(
            key(kVK_ANSI_KeypadEnter, [.option]),
            .commit(plain: true)
        )
        XCTAssertEqual(
            key(kVK_Return, [.option, .numericPad]),
            .commit(plain: true)
        )
    }

    func testOtherModifiersKeepAFullCommit() {
        XCTAssertEqual(key(kVK_Return, [.shift]), .commit(plain: false))
        XCTAssertEqual(
            key(kVK_ANSI_KeypadEnter, [.numericPad]),
            .commit(plain: false)
        )
    }

    func testNavigationPreviewAndEscapeKeepTheirKeys() {
        XCTAssertEqual(key(kVK_UpArrow), .moveUp)
        XCTAssertEqual(key(kVK_DownArrow), .moveDown)
        XCTAssertEqual(key(kVK_Space), .togglePreview)
        XCTAssertEqual(key(kVK_Escape), .escape)
    }

    /// Any other key goes on to the rest of the responder chain.
    func testOtherKeysAreLeftAlone() {
        XCTAssertNil(key(kVK_ANSI_A))
        XCTAssertNil(key(kVK_Tab))
        XCTAssertNil(key(kVK_Delete))
        XCTAssertNil(key(kVK_ANSI_V, [.command]))
    }

    private func key(
        _ keyCode: Int,
        _ modifierFlags: NSEvent.ModifierFlags = []
    ) -> ClipboardHistoryPopoverKey? {
        ClipboardHistoryPopoverKey(
            keyCode: keyCode,
            modifierFlags: modifierFlags
        )
    }
}
