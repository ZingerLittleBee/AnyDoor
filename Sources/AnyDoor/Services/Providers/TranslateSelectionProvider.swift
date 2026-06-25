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
        let text = await SelectedTextReader.read()
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let text, !trimmed.isEmpty else {
            // Don't fail silently — tell the user nothing could be read so it's
            // clear the action ran (vs. selecting text and getting no window).
            ToastPresenter.shared.show(.failure(L(.toastNoSelectedText)))
            return
        }
        TranslationWindowController.shared.showPrefilled(text)
    }
}
