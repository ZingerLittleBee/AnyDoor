import AppKit
import ApplicationServices
import Foundation

/// Reads the user's current text selection: the Accessibility
/// `kAXSelectedTextAttribute` of the focused element first, with a
/// pasteboard-preserving Cmd-C fallback when AX yields nothing.
enum SelectedTextReader {
    /// Best-effort selected text. Tries AX, then the clipboard fallback.
    @MainActor
    static func read() async -> String? {
        if let ax = readViaAccessibility() { return ax }
        // When invoked from a hotkey the user is likely still holding its
        // modifiers (e.g. ⌘⌥T). Those flags would merge into the synthesized
        // Cmd-C (becoming ⌘⌥C etc.) and silently fail to copy, so wait for the
        // keyboard to settle before falling back to the clipboard.
        await waitForModifiersToClear()
        return await readViaClipboard(
            pasteboard: .general,
            copy: { synthesizeCopy() },
            settle: { try? await Task.sleep(nanoseconds: 200_000_000) }
        )
    }

    /// Poll the live modifier state and return once Command/Control/Option/Shift
    /// are all released, or `timeout` elapses. Prevents a held hotkey modifier
    /// from corrupting the synthesized Cmd-C in the clipboard fallback.
    @MainActor
    private static func waitForModifiersToClear(timeout: TimeInterval = 0.5) async {
        let tracked: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let step: UInt64 = 20_000_000 // 20 ms
        let maxIterations = Int((timeout * 1_000_000_000) / Double(step))
        for _ in 0..<maxIterations {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(tracked).isEmpty { return }
            try? await Task.sleep(nanoseconds: step)
        }
    }

    /// The focused element's selected text via the Accessibility API. Returns
    /// nil when there is no focused element, the attribute is unavailable, or
    /// the selection is blank.
    @MainActor
    static func readViaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let element = focused else {
            return nil
        }
        // `focused` is an AXUIElement; force-cast through CFTypeRef is safe here.
        let axElement = element as! AXUIElement
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axElement, kAXSelectedTextAttribute as CFString, &selected
        ) == .success, let string = selected as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : string
    }

    /// Pasteboard fallback: snapshot the current string, trigger `copy`, wait
    /// for `settle`, then read the copied selection only if the pasteboard's
    /// `changeCount` advanced and the result is non-blank. The prior contents
    /// are always restored before returning.
    @MainActor
    static func readViaClipboard(
        pasteboard: NSPasteboard,
        copy: () -> Void,
        settle: () async -> Void
    ) async -> String? {
        let previous = pasteboard.string(forType: .string)
        let beforeCount = pasteboard.changeCount

        copy()
        await settle()

        var result: String?
        if pasteboard.changeCount != beforeCount {
            let copied = pasteboard.string(forType: .string)
            if let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = copied
            }
        }

        // Restore the caller's pasteboard regardless of outcome.
        pasteboard.clearContents()
        if let previous {
            pasteboard.setString(previous, forType: .string)
        }
        return result
    }

    /// Post a synthesized Cmd-C key-down/up pair to the focused app.
    @MainActor
    private static func synthesizeCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKeyCode: CGKeyCode = 8 // 'c'
        let down = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
        up?.flags = .maskCommand
        // Tag both events so the HotkeyService CGEvent tap passes our own
        // emissions through instead of swallowing them (e.g. when Cmd-C is a
        // bound hotkey or while keyboard-lock is active).
        down?.setIntegerValueField(.eventSourceUserData, value: kAnyDoorSynthesizedEventTag)
        up?.setIntegerValueField(.eventSourceUserData, value: kAnyDoorSynthesizedEventTag)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
