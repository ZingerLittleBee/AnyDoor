import AppKit
import Foundation

/// Reads the user's currently selected text (Accessibility first, clipboard
/// copy fallback) and opens the translation window prefilled with it.
///
/// An empty or unreadable selection is silent. `@MainActor` because it reads
/// the focused AX element and drives an NSPanel.
@MainActor
final class TranslateSelectionProvider: ActionProvider {
    let itemKey: BuiltinItem = .translateSelection
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        guard let text = await SelectedTextReader.read() else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        TranslationWindowController.shared.showPrefilled(text)
    }
}
