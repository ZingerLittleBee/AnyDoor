import AppKit
import Carbon.HIToolbox
import XCTest
import PluginInterface
import PluginSupport
@testable import AnyDoor
@testable import ImageConversionPlugin

@MainActor
final class FocusedControlKeyPolicyTests: XCTestCase {
    func testPasteAndEscapeDeferToFocusedTextEditing() {
        let editor = NSTextView()

        XCTAssertTrue(FocusedControlKeyPolicy.shouldDefer(
            keyCode: kVK_ANSI_V,
            firstResponder: editor
        ))
        XCTAssertTrue(FocusedControlKeyPolicy.shouldDefer(
            keyCode: kVK_Escape,
            firstResponder: editor
        ))
    }

    func testWindowShortcutsRemainAvailableWithoutAControlFocus() {
        XCTAssertFalse(FocusedControlKeyPolicy.shouldDefer(
            keyCode: kVK_ANSI_V,
            firstResponder: nil
        ))
        XCTAssertFalse(FocusedControlKeyPolicy.shouldDefer(
            keyCode: kVK_ANSI_O,
            firstResponder: NSTextView()
        ))
    }
}
