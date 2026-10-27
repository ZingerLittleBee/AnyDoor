import AppKit

/// The application behind a command-palette row, which the row's context menu
/// acts on. Classifying a row reads only its `PanelEntry.Source`, so view
/// bodies can decide which rows get a menu; the store lookup an app shortcut
/// needs waits until the menu opens.
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

enum CommandPaletteAppAction: Equatable {
    case open
    case revealInFinder
    case showPackageContents
    case copyPath
    case copyBundleID
    /// Record the app's hotkey in Settings, adding it as an app shortcut first
    /// when it is not one yet.
    case assignHotkey
    case hideFromPalette
    case quit
    case forceQuit
    case moveToTrash
}

struct CommandPaletteAppMenuItem: Equatable {
    let action: CommandPaletteAppAction
    var isEnabled = true
}

/// What an application row's menu needs to know about the app when the menu
/// opens.
struct CommandPaletteAppContext: Equatable {
    let row: CommandPaletteAppRow
    let displayName: String
    let bundleID: String
    let path: String
    let hasHotkey: Bool
    let isRunning: Bool
    /// Outside the system volume and other apps' bundles, in a folder the user
    /// can modify.
    let canMoveToTrash: Bool

    var url: URL { URL(fileURLWithPath: path) }

    @MainActor
    static func resolve(_ entry: PanelEntry, store: PanelStore = .shared) -> CommandPaletteAppContext? {
        guard let row = CommandPaletteAppRow(entry.source), let app = row.resolve(in: store) else {
            return nil
        }
        return CommandPaletteAppContext(
            row: row,
            displayName: entry.localizedTitle(),
            bundleID: app.bundleID,
            path: app.path,
            hasHotkey: entry.hotkey != nil,
            isRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty,
            canMoveToTrash: isTrashableLocation(app.path) && FileManager.default.isDeletableFile(atPath: app.path)
        )
    }

    /// System apps sit on the read-only system volume, and an app shipped
    /// inside another bundle (Xcode's Instruments) belongs to its host:
    /// trashing it would break the host's code signature.
    static func isTrashableLocation(_ path: String) -> Bool {
        !path.hasPrefix("/System/") && !path.contains(".app/Contents/")
    }

    /// The menu's items, in groups that separators divide.
    var menuGroups: [[CommandPaletteAppMenuItem]] {
        var groups: [[CommandPaletteAppMenuItem]] = [
            [.init(action: .open), .init(action: .revealInFinder), .init(action: .showPackageContents)],
            [.init(action: .copyPath), .init(action: .copyBundleID)],
        ]
        // Hiding applies to scanned apps only; a shortcut row is the user's own
        // entry, removed from Settings instead.
        if case .installedApp = row {
            groups.append([.init(action: .assignHotkey), .init(action: .hideFromPalette)])
        } else {
            groups.append([.init(action: .assignHotkey)])
        }
        if isRunning {
            groups.append([.init(action: .quit), .init(action: .forceQuit)])
        }
        if canMoveToTrash {
            // Finder refuses to trash an open app; the disabled item says why
            // it is unavailable right now instead of disappearing.
            groups.append([.init(action: .moveToTrash, isEnabled: !isRunning)])
        }
        return groups
    }
}

/// Builds the native menu shared by right-click and ⌘K.
enum CommandPaletteAppMenu {
    @MainActor
    static func make(
        for context: CommandPaletteAppContext,
        perform: @escaping @MainActor (CommandPaletteAppAction) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, group) in context.menuGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for item in group {
                let menuItem = ClosureMenuItem(
                    title: title(of: item.action, in: context),
                    systemImage: systemImage(of: item.action)
                ) {
                    perform(item.action)
                }
                menuItem.isEnabled = item.isEnabled
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    @MainActor
    private static func title(of action: CommandPaletteAppAction, in context: CommandPaletteAppContext) -> String {
        switch action {
        case .open: return L(.commandPaletteActionOpen)
        case .revealInFinder: return L(.clipboardActionRevealInFinder)
        case .showPackageContents: return L(.commandPaletteAppShowPackageContents)
        case .copyPath: return L(.commandPaletteAppCopyPath)
        case .copyBundleID: return L(.commandPaletteAppCopyBundleID)
        case .assignHotkey:
            return L(context.hasHotkey ? .commandPaletteAppChangeHotkey : .commandPaletteAppSetHotkey)
        case .hideFromPalette: return L(.commandPaletteAppHide)
        case .quit: return L(.commandPaletteAppQuit)
        case .forceQuit: return L(.commandPaletteAppForceQuit)
        case .moveToTrash: return L(.commandPaletteAppMoveToTrash)
        }
    }

    private static func systemImage(of action: CommandPaletteAppAction) -> String {
        switch action {
        case .open: return "arrow.up.forward.app"
        case .revealInFinder: return "folder"
        case .showPackageContents: return "shippingbox"
        case .copyPath: return "doc.on.doc"
        case .copyBundleID: return "number"
        case .assignHotkey: return "keyboard"
        case .hideFromPalette: return "eye.slash"
        case .quit: return "xmark.circle"
        case .forceQuit: return "xmark.octagon"
        case .moveToTrash: return "trash"
        }
    }
}
