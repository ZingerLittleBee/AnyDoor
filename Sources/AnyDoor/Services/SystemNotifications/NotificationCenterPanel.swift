import ApplicationServices
import CoreGraphics
import Foundation

/// Notification Center's panel, which lists the notifications that have left
/// the screen. Nothing public opens it or reports whether it is open.
protocol NotificationCenterPanel: Sendable {
    /// Whether the panel is open; nil when that cannot be read.
    func isOpen() async -> Bool?
    /// Shows the panel when it is hidden and hides it when it is shown.
    func toggle() async
}

/// How a run got Notification Center's panel open.
enum NotificationCenterPanelOpening: Sendable, Equatable {
    /// The user had it open; it stays open.
    case alreadyOpen
    /// Opened for this run.
    case opened
    /// Toggled, but not seen open in time.
    case timedOut
    /// Whether it was open could not be read, so it was left alone.
    case unreadable

    /// Whether the panel is known to be open for the run.
    var isOpen: Bool { self == .alreadyOpen || self == .opened }
}

/// Opens the panel for a run and closes it afterwards, leaving a panel the
/// user opened alone. Generic over its clock so tests can drive time without
/// sleeping.
struct NotificationCenterPanelPresenter<C: Clock<Duration>>: Sendable {
    let panel: any NotificationCenterPanel
    let clock: C
    /// How long the panel may take to report itself open.
    var openTimeout: Duration = .seconds(1)
    var pollInterval: Duration = .milliseconds(50)

    func open() async -> NotificationCenterPanelOpening {
        switch await panel.isOpen() {
        case true?: return .alreadyOpen
        case nil: return .unreadable
        case false?: break
        }
        await panel.toggle()
        let deadline = clock.now.advanced(by: openTimeout)
        while clock.now < deadline {
            try? await clock.sleep(for: pollInterval)
            if await panel.isOpen() == true { return .opened }
        }
        return .timedOut
    }

    /// Closes the panel `open` toggled, including one that opened only after
    /// `open` stopped waiting. Toggles only a panel read as open, so a panel
    /// that is already gone is not reopened.
    func close(after opening: NotificationCenterPanelOpening) async {
        guard opening == .opened || opening == .timedOut,
              await panel.isOpen() == true
        else { return }
        await panel.toggle()
    }
}

extension NotificationCenterPanelPresenter where C == ContinuousClock {
    init(panel: any NotificationCenterPanel) {
        self.init(panel: panel, clock: ContinuousClock())
    }
}

/// The live panel. Reads its state from the `AXExpanded` attribute of
/// Notification Center's application element, which turns true only once the
/// panel's list is in the tree, and toggles it with the system's Globe+N
/// shortcut.
struct AccessibilityNotificationCenterPanel: NotificationCenterPanel {
    private static let queue = DispatchQueue(
        label: "dev.bybee.AnyDoor.notification-center-panel",
        qos: .userInitiated
    )
    private static let readTimeout: Float = 0.25
    private static let functionKeyCode: CGKeyCode = 63 // kVK_Function
    private static let nKeyCode: CGKeyCode = 45 // kVK_ANSI_N

    let pid: pid_t

    func isOpen() async -> Bool? {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, Self.readTimeout)
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(
                    application, kAXExpandedAttribute as CFString, &value
                )
                continuation.resume(returning: error == .success ? value as? Bool : nil)
            }
        }
    }

    /// Posts Globe+N as the whole keystroke, Globe released last. Like
    /// `SyntheticKeyChord`, it must not end on an event that still carries the
    /// modifier, or the window server keeps Globe down for later keys. Every
    /// event is tagged so the HotkeyService tap passes it through.
    func toggle() async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let wasGlobeDown = CGEventSource.keyState(.hidSystemState, key: Self.functionKeyCode)
        let ambient = CGEventSource.flagsState(.combinedSessionState).subtracting(.maskSecondaryFn)
        let chord = ambient.union(.maskSecondaryFn)
        let keystrokes: [(keyCode: CGKeyCode, isDown: Bool, flags: CGEventFlags)] = [
            (Self.functionKeyCode, true, chord),
            (Self.nKeyCode, true, chord),
            (Self.nKeyCode, false, chord),
            (Self.functionKeyCode, false, ambient),
        ]
        guard let events = Self.makeEvents(keystrokes, source: source) else {
            // Posting part of the sequence could leave Globe down.
            return
        }
        for event in events {
            event.post(tap: .cghidEventTap)
        }
        // Rarely the window server still reports Globe down after the
        // release; the key table cannot tell that from a held key, so only
        // a Globe that was up before the chord is released again.
        guard !wasGlobeDown else { return }
        try? await Task.sleep(for: .milliseconds(50))
        guard CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn),
              let release = Self.makeEvents([(Self.functionKeyCode, false, ambient)], source: source)
        else { return }
        for event in release {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Tagged events for `keystrokes`, Globe's as `flagsChanged`; nil when
    /// any cannot be created.
    private static func makeEvents(
        _ keystrokes: [(keyCode: CGKeyCode, isDown: Bool, flags: CGEventFlags)],
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
            if keystroke.keyCode == functionKeyCode {
                event.type = .flagsChanged
            }
            event.flags = keystroke.flags
            event.setIntegerValueField(.eventSourceUserData, value: kAnyDoorSynthesizedEventTag)
            events.append(event)
        }
        return events
    }
}
