import Foundation

/// The application behind a command-palette row, which the row's context menu
/// acts on. Classifying a row reads only its `PanelEntry.Source`, so view
/// bodies can decide which rows get a menu; the store lookup an app shortcut
/// needs waits until an action runs.
enum CommandPaletteAppRow: Equatable {
    case installedApp(bundleID: String, path: String)
    case appShortcut(id: UUID)

    /// Nil for every row that is not an application. Exhaustive, so a new
    /// Source case must decide whether it stands for an app.
    init?(_ source: PanelEntry.Source) {
        switch source {
        case .installedApp(let bundleID, let path):
            self = .installedApp(bundleID: bundleID, path: path)
        case .appShortcut(let id):
            self = .appShortcut(id: id)
        case .builtin, .portRecord, .calcResult, .devTool, .devToolScopeSuggestion, .conversion,
             .paletteOption, .pluginRow, .quicklink, .quicklinkTemplate, .quicklinkArgument:
            return nil
        }
    }

    /// The app's bundle identifier and bundle path now. An app shortcut reads
    /// its binding, which the palette re-points when the app moved; nil when
    /// the binding no longer exists.
    @MainActor
    func resolve(in store: PanelStore = .shared) -> (bundleID: String, path: String)? {
        switch self {
        case .installedApp(let bundleID, let path):
            return (bundleID, path)
        case .appShortcut(let id):
            guard let binding = store.binding(id: id) else { return nil }
            return (binding.appBundleID, binding.appPath)
        }
    }
}

/// Context-menu actions on an application row beyond opening it, which the
/// menu routes through the row's ordinary commit.
enum CommandPaletteAppAction {
    case revealInFinder
    case copyPath
    case copyBundleID
}
