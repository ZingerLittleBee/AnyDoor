import AppKit
import Carbon.HIToolbox
import XCTest
@testable import AnyDoor

@MainActor
final class ImageConversionWindowControllerTests: XCTestCase {
    func testPasteAndEscapeDeferToFocusedTextEditing() {
        let editor = NSTextView()

        XCTAssertTrue(ImageConversionWindowController.shouldDeferToFocusedControl(
            keyCode: kVK_ANSI_V,
            firstResponder: editor
        ))
        XCTAssertTrue(ImageConversionWindowController.shouldDeferToFocusedControl(
            keyCode: kVK_Escape,
            firstResponder: editor
        ))
    }

    func testWindowShortcutsRemainAvailableWithoutAControlFocus() {
        XCTAssertFalse(ImageConversionWindowController.shouldDeferToFocusedControl(
            keyCode: kVK_ANSI_V,
            firstResponder: nil
        ))
        XCTAssertFalse(ImageConversionWindowController.shouldDeferToFocusedControl(
            keyCode: kVK_ANSI_O,
            firstResponder: NSTextView()
        ))
    }
}
