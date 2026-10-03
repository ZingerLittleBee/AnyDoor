import CoreGraphics
import XCTest
@testable import AnyDoor

/// These tests build keystroke sequences and CGEvents but never post them:
/// a posted event would type into the developer's frontmost app.
final class SyntheticKeyChordTests: XCTestCase {
    private typealias Keystroke = SyntheticKeyChord.Keystroke

    private let modifiers: CGEventFlags = [
        .maskAlphaShift, .maskShift, .maskControl, .maskAlternate, .maskCommand,
    ]

    func testPasteWrapsTheKeyInCommandDownAndUp() {
        let keystrokes = SyntheticKeyChord.commandShortcut(
            key: SyntheticKeyChord.vKeyCode,
            ambient: []
        )

        XCTAssertEqual(keystrokes, [
            Keystroke(keyCode: 55, isDown: true, flags: .maskCommand),
            Keystroke(keyCode: 9, isDown: true, flags: .maskCommand),
            Keystroke(keyCode: 9, isDown: false, flags: .maskCommand),
            Keystroke(keyCode: 55, isDown: false, flags: []),
        ])
    }

    func testPostedSequenceEndsWithCommandReleasedAndEveryEventTagged() throws {
        let events = try XCTUnwrap(SyntheticKeyChord.makeEvents(
            SyntheticKeyChord.commandShortcut(
                key: SyntheticKeyChord.vKeyCode,
                ambient: []
            ),
            source: nil
        ))

        XCTAssertEqual(
            events.map(\.type),
            [.flagsChanged, .keyDown, .keyUp, .flagsChanged]
        )
        XCTAssertEqual(
            events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
            [55, 9, 9, 55]
        )
        XCTAssertEqual(
            events.map { $0.flags.intersection(modifiers) },
            [.maskCommand, .maskCommand, .maskCommand, []]
        )
        for event in events {
            XCTAssertEqual(
                event.getIntegerValueField(.eventSourceUserData),
                kAnyDoorSynthesizedEventTag
            )
        }
    }

    func testPhysicallyHeldCommandIsLeftToTheUser() {
        let keystrokes = SyntheticKeyChord.commandShortcut(
            key: SyntheticKeyChord.cKeyCode,
            ambient: .maskCommand
        )

        XCTAssertEqual(keystrokes, [
            Keystroke(keyCode: 8, isDown: true, flags: .maskCommand),
            Keystroke(keyCode: 8, isDown: false, flags: .maskCommand),
        ])
    }

    func testCommandReleaseRestoresHeldModifiersAndCapsLock() throws {
        let ambient: CGEventFlags = [.maskShift, .maskAlphaShift]
        let keystrokes = SyntheticKeyChord.commandShortcut(
            key: SyntheticKeyChord.vKeyCode,
            ambient: ambient
        )

        // The chord stays exactly Command plus the key; held Shift must not
        // turn ⌘V into ⌘⇧V, but Caps Lock is a lock state, not a chord key.
        let chord: CGEventFlags = [.maskCommand, .maskAlphaShift]
        XCTAssertEqual(keystrokes.dropLast().map(\.flags), [chord, chord, chord])
        XCTAssertEqual(
            keystrokes.last,
            Keystroke(keyCode: 55, isDown: false, flags: ambient)
        )

        let events = try XCTUnwrap(
            SyntheticKeyChord.makeEvents(keystrokes, source: nil)
        )
        XCTAssertEqual(events.last?.flags.intersection(modifiers), ambient)
    }
}
