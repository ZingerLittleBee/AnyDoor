import AppKit

/// Small clipboard actions shared by providers and tests.
@MainActor
enum ClipboardActions {
    /// Clears the pasteboard and returns the resulting change count so callers
    /// can suppress AnyDoor's own watcher when appropriate.
    @discardableResult
    static func clear(_ pasteboard: NSPasteboard = .general) -> Int {
        pasteboard.clearContents()
        return pasteboard.changeCount
    }
}
