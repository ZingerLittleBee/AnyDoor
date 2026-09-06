import AppKit
import ApplicationServices
import ClipboardHistory
import Foundation

/// Reads the user's current text selection: the Accessibility
/// `kAXSelectedTextAttribute` of the focused element first, with a
/// pasteboard-preserving Cmd-C fallback when AX yields nothing.
enum SelectedTextReader {
    /// Best-effort selected text. Tries AX, then the clipboard fallback.
    @MainActor
    static func read() async -> String? {
        // Invoked from the command palette, AnyDoor is still the active app for
        // a beat after the palette closes. Reading now would inspect AnyDoor's
        // own (empty) selection and send the synthesized Cmd-C to AnyDoor, so
        // wait for the user's app to come back to the front first.
        await waitForFrontmostAppToChange()
        if let ax = readViaAccessibility() { return ax }
        // When invoked from a hotkey the user is likely still holding its
        // modifiers (e.g. ⌘⌥T). Those flags would merge into the synthesized
        // Cmd-C (becoming ⌘⌥C etc.) and silently fail to copy, so wait for the
        // keyboard to settle before falling back to the clipboard.
        await waitForModifiersToClear()
        return await readViaClipboard(
            pasteboard: .general,
            copy: { synthesizeCopy() },
            settle: { try? await Task.sleep(nanoseconds: settleStepNanoseconds) }
        )
    }

    /// One poll step of the wait for the synthesized copy to land.
    static let settleStepNanoseconds: UInt64 = 20_000_000 // 20 ms

    /// How many steps that wait is allowed to take — 800 ms, enough for a slow
    /// app to service Cmd-C with a large selection.
    static let settleStepBudget = 40

    /// Return once AnyDoor is no longer the frontmost app, or `timeout`
    /// elapses. Returns immediately when it was never frontmost, which is the
    /// usual hotkey case for this accessory app.
    @MainActor
    private static func waitForFrontmostAppToChange(
        timeout: TimeInterval = 0.5
    ) async {
        let step: UInt64 = 20_000_000 // 20 ms
        let maxIterations = Int((timeout * 1_000_000_000) / Double(step))
        for _ in 0..<maxIterations {
            let front = NSWorkspace.shared.frontmostApplication
            guard
                front?.processIdentifier
                    == NSRunningApplication.current.processIdentifier
            else { return }
            try? await Task.sleep(nanoseconds: step)
        }
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

    /// Pasteboard fallback: snapshot current pasteboard contents, trigger
    /// `copy`, wait for the pasteboard to actually change, then read the copied
    /// selection only if the result is non-blank. The prior contents are always
    /// restored before returning.
    ///
    /// The wait polls `changeCount` rather than sleeping a fixed amount. A
    /// fixed wait was the bug: an app slow to service Cmd-C (a terminal with a
    /// large selection, say) writes the pasteboard *after* the wait, so nothing
    /// is read, the snapshot is never restored — the user's clipboard silently
    /// becomes their selection — and the late write lands outside the
    /// self-write window, where clipboard history captures it as if the user
    /// had copied it. Polling ends the moment the copy lands, which is also
    /// faster than the old fixed delay in the common case.
    @MainActor
    static func readViaClipboard(
        pasteboard: NSPasteboard,
        selfWrites: ClipboardHistoryPasteboardSelfWriteFunnel? =
            ClipboardSelfWrites.current,
        copy: () -> Void,
        settle: () async -> Void,
        settleStepBudget: Int = SelectedTextReader.settleStepBudget
    ) async -> String? {
        let previous = PasteboardSnapshot(pasteboard)
        let beforeCount = pasteboard.changeCount
        let selfWrite = selfWrites?.begin()
        defer { selfWrite?.finish(pasteboard: pasteboard) }

        copy()
        for _ in 0..<max(1, settleStepBudget) {
            await settle()
            if pasteboard.changeCount != beforeCount { break }
        }

        var result: String?
        if pasteboard.changeCount != beforeCount {
            let copied = pasteboard.string(forType: .string)
            if let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = copied
            }
        }

        // Restore the caller's pasteboard only when the synthetic copy actually
        // changed it. Preserve every pasteboard item/type, not just plain text.
        // The scoped self-write token finishes after this restore and records
        // the final generation while also suppressing intermediate writes.
        if pasteboard.changeCount != beforeCount {
            previous.restore(to: pasteboard)
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

    private struct PasteboardSnapshot {
        private struct Item {
            let values: [(NSPasteboard.PasteboardType, Data)]
        }

        private let items: [Item]

        init(_ pasteboard: NSPasteboard) {
            items = pasteboard.pasteboardItems?.map { item in
                Item(values: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            } ?? []
        }

        @MainActor
        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restoredItems = items.map { item in
                let restored = NSPasteboardItem()
                for (type, data) in item.values {
                    restored.setData(data, forType: type)
                }
                return restored
            }
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
    }
}
