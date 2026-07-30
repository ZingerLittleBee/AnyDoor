import AppKit
import ClipboardHistory

/// The single host entry point for AnyDoor-owned pasteboard writes.
///
/// `AppDelegate` owns the Clipboard History module instance. Looking it up
/// through the application delegate keeps old static UI/provider entry points
/// usable during the v2 cutover without retaining a mutable global watcher or
/// a second module singleton.
@MainActor
enum ClipboardSelfWrites {
    @discardableResult
    static func perform<T>(
        to pasteboard: NSPasteboard = .general,
        _ body: (NSPasteboard) throws -> T
    ) rethrows -> T {
        guard let funnel = funnel else {
            return try body(pasteboard)
        }
        return try funnel.perform(to: pasteboard, body)
    }

    static func write(
        string: String,
        to pasteboard: NSPasteboard = .general
    ) {
        guard let funnel else {
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
            return
        }
        funnel.write(string: string, to: pasteboard)
    }

    static var current: ClipboardHistoryPasteboardSelfWriteFunnel? {
        (NSApplication.shared.delegate as? AppDelegate)?
            .clipboardHistoryModule
            .pasteboardSelfWrites
    }

    private static var funnel: ClipboardHistoryPasteboardSelfWriteFunnel? {
        current
    }
}
