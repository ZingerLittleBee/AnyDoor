import AppKit
import ClipboardHistory

/// The single host entry point for AnyDoor-owned pasteboard writes.
///
/// `AppDelegate` owns the Clipboard History module instance and installs that
/// module's funnel before any production feature can write to the pasteboard.
@MainActor
enum ClipboardSelfWrites {
    private static var funnel = ClipboardHistoryPasteboardSelfWriteFunnel()

    static func configure(
        _ funnel: ClipboardHistoryPasteboardSelfWriteFunnel
    ) {
        self.funnel = funnel
    }

    @discardableResult
    static func perform<T>(
        to pasteboard: NSPasteboard = .general,
        _ body: (NSPasteboard) throws -> T
    ) rethrows -> T {
        return try funnel.perform(to: pasteboard, body)
    }

    static func write(
        string: String,
        to pasteboard: NSPasteboard = .general
    ) {
        funnel.write(string: string, to: pasteboard)
    }

    static var current: ClipboardHistoryPasteboardSelfWriteFunnel {
        funnel
    }
}
