import Foundation
import PluginInterface

/// Identifies any active global-hotkey binding across AnyDoor's four hotkey
/// sources (app shortcuts, built-in commands, quicklinks, and the Command
/// Palette) for conflict detection and one-step replacement.
enum HotkeyConflictOwner: Equatable, Sendable {
    case appShortcut(id: UUID, appName: String)
    case builtin(BuiltinItem)
    case quicklink(id: UUID, title: String)
    case commandPalette

    /// Stable identity without display text, used to exclude the row being edited
    /// and to clear a displaced binding through its owning store.
    enum Target: Equatable, Sendable {
        case appShortcut(UUID)
        case builtin(BuiltinItem)
        case quicklink(UUID)
        case commandPalette
    }

    var target: Target {
        switch self {
        case .appShortcut(let id, _):
            return .appShortcut(id)
        case .builtin(let item):
            return .builtin(item)
        case .quicklink(let id, _):
            return .quicklink(id)
        case .commandPalette:
            return .commandPalette
        }
    }

    @MainActor
    var localizedTitle: String {
        switch self {
        case .appShortcut(_, let appName):
            return appName
        case .builtin(let item):
            return L(item.titleKey)
        case .quicklink(_, let title):
            return title
        case .commandPalette:
            return L(.settingsGeneralCommandPaletteSection)
        }
    }
}
