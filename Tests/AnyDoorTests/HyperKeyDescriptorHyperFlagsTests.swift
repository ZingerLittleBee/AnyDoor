import XCTest
import Carbon.HIToolbox
import AppKit
@testable import AnyDoor

final class HyperKeyDescriptorHyperFlagsTests: XCTestCase {
    private var hyper4: Int {
        Int(NSEvent.ModifierFlags.control.rawValue
            | NSEvent.ModifierFlags.option.rawValue
            | NSEvent.ModifierFlags.shift.rawValue
            | NSEvent.ModifierFlags.command.rawValue)
    }

    private var hyper3: Int {
        Int(NSEvent.ModifierFlags.control.rawValue
            | NSEvent.ModifierFlags.option.rawValue
            | NSEvent.ModifierFlags.command.rawValue)
    }

    func testHyperFlagsZeroFallsBackToModifierGlyphs() {
        let d = HotkeyDescriptor(keyCode: kVK_ANSI_M, modifierFlags: hyper4)
        XCTAssertEqual(d.displayString(hyperFlags: 0), "⌃⌥⇧⌘M")
    }

    func testHyperFlagsMatchRendersStarKey() {
        let d = HotkeyDescriptor(keyCode: kVK_ANSI_M, modifierFlags: hyper4)
        XCTAssertEqual(d.displayString(hyperFlags: hyper4), "✦M")
    }

    func testHyperFlagsMismatchFallsBack() {
        let d = HotkeyDescriptor(keyCode: kVK_ANSI_M, modifierFlags: hyper4)
        XCTAssertEqual(d.displayString(hyperFlags: hyper3), "⌃⌥⇧⌘M")
    }

    func testIncludeShiftOffNewHyperShortcutRendersStar() {
        // When Include Shift = OFF, newly recorded Hyper+M is stored as
        // ⌃⌥⌘+M (3 modifiers); rendering with 3-mod hyperFlags should produce ✦M.
        let d = HotkeyDescriptor(keyCode: kVK_ANSI_M, modifierFlags: hyper3)
        XCTAssertEqual(d.displayString(hyperFlags: hyper3), "✦M")
    }
}
