import CoreGraphics

/// Synthesizes a Command shortcut (⌘V, ⌘C) as the complete keystroke that a
/// real keyboard produces: Command down, key down, key up, Command up.
///
/// Posting only the letter with `.maskCommand` in its flags leaves Command
/// latched system-wide. The window server takes modifier state from the flags
/// of events posted at the HID tap, and a key-up that still carries Command,
/// with no Command release after it, tells it Command stays down. Later clicks
/// then arrive as ⌘-clicks until some event clears the flags. The
/// `CGEventCreateKeyboardEvent` contract asks for exactly this sequence: every
/// keystroke needed for the character, modifier keys included, must be
/// entered and released.
///
/// Every event carries `kAnyDoorSynthesizedEventTag`, so the HotkeyService tap
/// passes the Command events through like the letter instead of treating them
/// as user input for Hyper Key matching or keyboard lock.
enum SyntheticKeyChord {
    struct Keystroke: Equatable, Sendable {
        let keyCode: CGKeyCode
        let isDown: Bool
        let flags: CGEventFlags
    }

    static let commandKeyCode: CGKeyCode = 55 // kVK_Command
    static let cKeyCode: CGKeyCode = 8 // kVK_ANSI_C
    static let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

    /// Modifier flags tied to physical keys, with their left and right
    /// virtual key codes.
    private static let modifierKeys: [(flag: CGEventFlags, keyCodes: [CGKeyCode])] = [
        (.maskCommand, [55, 54]),
        (.maskShift, [56, 60]),
        (.maskAlternate, [58, 61]),
        (.maskControl, [59, 62]),
    ]

    /// The flag bits this type decides on each event. Everything else the
    /// event was created with (device and synthetic-origin bits) is kept.
    private static let managedFlags: CGEventFlags = [
        .maskAlphaShift, .maskShift, .maskControl, .maskAlternate, .maskCommand,
    ]

    /// The keystrokes for Command plus `key`.
    ///
    /// `ambient` holds the modifiers physically down right now and the Caps
    /// Lock state. The chord itself is exactly ⌘ plus `key` (Caps Lock kept),
    /// as before. When Command is already physically held, its key events are
    /// left to the user's own release. Otherwise the sequence ends with a
    /// Command release that restores `ambient`, so no synthesized modifier
    /// outlives the chord.
    static func commandShortcut(
        key: CGKeyCode,
        ambient: CGEventFlags
    ) -> [Keystroke] {
        let chord = ambient.intersection(.maskAlphaShift).union(.maskCommand)
        let keyPress = [
            Keystroke(keyCode: key, isDown: true, flags: chord),
            Keystroke(keyCode: key, isDown: false, flags: chord),
        ]
        guard !ambient.contains(.maskCommand) else { return keyPress }
        return [Keystroke(keyCode: commandKeyCode, isDown: true, flags: chord)]
            + keyPress
            + [Keystroke(keyCode: commandKeyCode, isDown: false, flags: ambient)]
    }

    /// Tagged events for `keystrokes`, or nil when any of them cannot be
    /// created. Posting part of a sequence could leave Command down, so it is
    /// all or nothing. Creating events posts nothing.
    static func makeEvents(
        _ keystrokes: [Keystroke],
        source: CGEventSource?
    ) -> [CGEvent]? {
        var events: [CGEvent] = []
        for keystroke in keystrokes {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: keystroke.keyCode,
                keyDown: keystroke.isDown
            ) else {
                return nil
            }
            event.flags = event.flags
                .subtracting(managedFlags)
                .union(keystroke.flags.intersection(managedFlags))
            event.setIntegerValueField(
                .eventSourceUserData,
                value: kAnyDoorSynthesizedEventTag
            )
            events.append(event)
        }
        return events
    }

    /// Posts Command plus `key` to the frontmost app.
    ///
    /// The source uses the combined session state, which Apple's
    /// `CGEventSource` documentation names for programs posting from within a
    /// login session (the HID system state is for daemons and drivers
    /// interpreting hardware). The events still enter at the HID tap, the path
    /// hardware keystrokes take to the frontmost app.
    static func postCommandShortcut(key: CGKeyCode) {
        let keystrokes = commandShortcut(key: key, ambient: currentAmbientFlags())
        guard let events = makeEvents(
            keystrokes,
            source: CGEventSource(stateID: .combinedSessionState)
        ) else {
            return
        }
        for event in events {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Modifiers whose keys are down in the HID system table, plus Caps Lock.
    /// Held modifiers are read per key rather than from the flags state,
    /// because the flags are exactly what an earlier flags-only synthesized
    /// event can latch; a latched Command therefore does not count as held,
    /// and this chord's Command release clears it.
    private static func currentAmbientFlags() -> CGEventFlags {
        var flags = CGEventSource.flagsState(.combinedSessionState)
            .intersection(.maskAlphaShift)
        for (flag, keyCodes) in modifierKeys
        where keyCodes.contains(where: {
            CGEventSource.keyState(.hidSystemState, key: $0)
        }) {
            flags.insert(flag)
        }
        return flags
    }
}
