import AppKit
import PluginInterface

/// Bridges the translation window into the panel's `ActionProvider` surface so
/// it gets a panel row, settings visibility/order, and a bindable hotkey via
/// the existing dispatch path. `@MainActor` because it drives an NSPanel.
@MainActor
final class TranslateProvider: ActionProvider {
    let itemKey: BuiltinItem = .translate
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        TranslationWindowController.shared.toggle()
    }
}
