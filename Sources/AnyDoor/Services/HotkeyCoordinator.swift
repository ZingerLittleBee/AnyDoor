import SwiftData
import Foundation
import PluginInterface

/// Owns the hotkey side of the panel subsystem: compiles `HotkeySnapshot`s from
/// every hotkey source and routes matched `HotkeyAction`s to their targets.
///
/// Sources merged by `refresh()`:
/// - `KeyBinding` rows (app shortcuts) from SwiftData
/// - `BuiltinPreference` rows (builtin hotkeys, incl. hidden brightness ±)
/// - `Quicklink` rows with recorded hotkeys
/// - the Command Palette hotkey (`CommandPaletteService.shared.hotkey`)
///
/// PanelStore mutations, config import (`BackupService`), and the palette
/// hotkey setter all call `refresh()` after changing a source; hotkey sources
/// never reach into PanelStore. `dispatch` is the single routing point bound
/// to `HotkeyService.setDispatcher` in AppDelegate — only the builtin
/// toggle/run cases touch PanelStore, everything else routes directly.
@MainActor
final class HotkeyCoordinator {
    static let shared = HotkeyCoordinator()

    private var modelContainer: ModelContainer?
    private let quicklinkResolver: @MainActor (UUID) -> Quicklink?
    private let quicklinkOpener: @MainActor (Quicklink) -> Void
    private let quicklinkArgumentPresenter: @MainActor (UUID, String, String, String?) -> Void

    init(
        quicklinkResolver: @escaping @MainActor (UUID) -> Quicklink? = { QuicklinkStore.shared.quicklink(id: $0) },
        quicklinkOpener: @escaping @MainActor (Quicklink) -> Void = { QuicklinkOpener.shared.open($0) },
        quicklinkArgumentPresenter: @escaping @MainActor (UUID, String, String, String?) -> Void = {
            CommandPaletteWindowController.shared.showArgumentInput(
                quicklinkID: $0,
                title: $1,
                link: $2,
                openWithBundleID: $3
            )
        }
    ) {
        self.quicklinkResolver = quicklinkResolver
        self.quicklinkOpener = quicklinkOpener
        self.quicklinkArgumentPresenter = quicklinkArgumentPresenter
    }

    func bootstrap(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Recompile the snapshot list from all sources and push it to
    /// HotkeyService. Called whenever bindings, builtin preferences, or the
    /// Command Palette hotkey change.
    func refresh() {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        let bindings = (try? context.fetch(
            FetchDescriptor<KeyBinding>(predicate: #Predicate { $0.isEnabled })
        )) ?? []
        let prefs = (try? context.fetch(FetchDescriptor<BuiltinPreference>())) ?? []
        let quicklinks = (try? context.fetch(FetchDescriptor<Quicklink>())) ?? []
        let snapshots = Self.compile(
            bindings: bindings,
            prefs: prefs,
            quicklinks: quicklinks,
            paletteHotkey: CommandPaletteService.shared.hotkey,
            availableCommands: PluginRegistry.shared.availableCommands
        )
        HotkeyService.shared.updateSnapshots(snapshots)
    }

    /// Pure snapshot compiler over already-fetched state, so it unit-tests
    /// without singletons or a live store.
    ///
    /// `availableCommands` is the installed set's view of the catalog
    /// (`PluginRegistry.availableCommands`): a binding recorded for an
    /// uninstalled plugin's command never compiles, so its hotkey neither
    /// fires nor blocks the shortcut for other bindings.
    static func compile(
        bindings: [KeyBinding],
        prefs: [BuiltinPreference],
        quicklinks: [Quicklink],
        paletteHotkey: HotkeyDescriptor?,
        availableCommands: Set<BuiltinItem> = Set(BuiltinItem.allCases)
    ) -> [HotkeySnapshot] {
        var out: [HotkeySnapshot] = []

        for binding in bindings {
            out.append(HotkeySnapshot(
                keyCode: binding.keyCode,
                modifierFlags: binding.modifierFlags,
                action: .launchApp(bundleID: binding.appBundleID, path: binding.appPath)
            ))
        }

        for pref in prefs {
            guard let item = BuiltinItem(rawValue: pref.itemKey),
                  availableCommands.contains(item),
                  let code = pref.keyCode,
                  let mods = pref.modifierFlags else { continue }
            let action: HotkeyAction
            switch item.kind {
            case .toggle:
                action = .toggleBuiltin(itemKey: item.rawValue)
            case .action:
                action = .runBuiltin(itemKey: item.rawValue)
            case .submenu, .brightnessControl:
                continue   // hover-opened items don't bind a top-level hotkey
            case .hiddenHotkey:
                switch item {
                case .brightnessUp:   action = .brightnessUp
                case .brightnessDown: action = .brightnessDown
                default: continue
                }
            }
            out.append(HotkeySnapshot(
                keyCode: code,
                modifierFlags: mods,
                action: action
            ))
        }

        for quicklink in quicklinks {
            guard let descriptor = quicklink.hotkeyDescriptor else { continue }
            out.append(HotkeySnapshot(
                keyCode: descriptor.keyCode,
                modifierFlags: descriptor.modifierFlags,
                action: .openQuicklink(id: quicklink.id)
            ))
        }

        if let descriptor = paletteHotkey {
            out.append(HotkeySnapshot(
                keyCode: descriptor.keyCode,
                modifierFlags: descriptor.modifierFlags,
                action: .showCommandPalette
            ))
        }

        return out
    }

    /// Handle a matched hotkey. Called on the main thread by HotkeyService.
    func dispatch(_ action: HotkeyAction) {
        switch action {
        case .launchApp(let bundleID, let path):
            AppSwitcher.toggle(bundleID: bundleID, appPath: path)
        case .toggleBuiltin(let key):
            guard let item = BuiltinItem(rawValue: key) else { return }
            Task { await PanelStore.shared.toggle(item) }
        case .runBuiltin(let key):
            guard let item = BuiltinItem(rawValue: key) else { return }
            Task { await PanelStore.shared.run(item) }
        case .brightnessUp:
            DisplayBrightnessService.shared.bump(+1.0 / 16.0, target: .displayUnderMouse)
        case .brightnessDown:
            DisplayBrightnessService.shared.bump(-1.0 / 16.0, target: .displayUnderMouse)
        case .showCommandPalette:
            CommandPaletteWindowController.shared.toggle()
        case .openQuicklink(let id):
            guard let quicklink = quicklinkResolver(id) else { return }
            if QuicklinkDestination.isSearchTemplate(link: quicklink.link) {
                quicklinkArgumentPresenter(
                    quicklink.id,
                    quicklink.displayName,
                    quicklink.link,
                    quicklink.openWithBundleID
                )
            } else {
                quicklinkOpener(quicklink)
            }
        }
    }
}
