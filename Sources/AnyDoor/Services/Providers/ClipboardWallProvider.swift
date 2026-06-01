import AppKit

/// Bridges the clipboard wall into the panel's `ActionProvider` surface so it
/// gets a panel row, settings visibility/order, and a bindable hotkey via the
/// existing `runBuiltin` dispatch. `@MainActor` because it drives an NSPanel.
@MainActor
final class ClipboardWallProvider: ActionProvider {
    let itemKey: BuiltinItem = .clipboardWall
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        ClipboardWallWindowController.shared.toggle()
    }
}
