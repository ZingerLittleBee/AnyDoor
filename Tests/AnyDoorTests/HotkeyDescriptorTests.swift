import XCTest
import Carbon.HIToolbox
import AppKit
@testable import AnyDoor

final class HotkeyDescriptorTests: XCTestCase {
    func testDisplayStringWithModifiers() {
        let cmdCtrl: Int = Int(
            NSEvent.ModifierFlags.command.rawValue |
            NSEvent.ModifierFlags.control.rawValue
        )
        let d = HotkeyDescriptor(keyCode: kVK_F1, modifierFlags: cmdCtrl)
        XCTAssertEqual(d.displayString, "⌃⌘F1")
    }

    func testDisplayStringNoModifiers() {
        let d = HotkeyDescriptor(keyCode: kVK_Space, modifierFlags: 0)
        XCTAssertEqual(d.displayString, "Space")
    }

    func testEquality() {
        let a = HotkeyDescriptor(keyCode: kVK_F1, modifierFlags: 0)
        let b = HotkeyDescriptor(keyCode: kVK_F1, modifierFlags: 0)
        XCTAssertEqual(a, b)
    }
}
