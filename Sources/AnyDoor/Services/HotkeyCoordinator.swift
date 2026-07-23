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
/// hotkey setter all call `refresh()` after changing a source. `dispatch` is
/// the single routing point bound to `HotkeyService.setDispatcher` in
/// AppDelegate. PluginRegistry wires builtin toggle/run dispatch to the paired
/// PanelStore during bootstrap; every other action routes directly.
@MainActor
final class HotkeyCoordinator {
    static let shared = HotkeyCoordinator()

    private var modelContainer: ModelContainer?
    private var availableCommands: @MainActor () -> Set<BuiltinItem> = {
        Set(BuiltinItem.allCases)
    }
    private var toggleBuiltin: @MainActor (BuiltinItem) async -> Void = { _ in }
    private var runBuiltin: @MainActor (BuiltinItem) async -> Void = { _ in }
    private let quicklinkResolver: @MainActor (UUID) -> Quicklink?
    private let quicklinkOpener: @MainActor (Quicklink) -> Void
    private let quicklinkArgumentPresenter: @MainActor (UUID, String, String, String?) -> Void
    private let paletteHotkeyResolver: @MainActor () -> HotkeyDescriptor?
    private let snapshotUpdater: @MainActor ([HotkeySnapshot]) -> Void

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
        },
        paletteHotkeyResolver: @escaping @MainActor () -> HotkeyDescriptor? = {
            CommandPaletteService.shared.hotkey
        },
        snapshotUpdater: @escaping @MainActor ([HotkeySnapshot]) -> Void = {
            HotkeyService.shared.updateSnapshots($0)
        }
    ) {
        self.quicklinkResolver = quicklinkResolver
        self.quicklinkOpener = quicklinkOpener
        self.quicklinkArgumentPresenter = quicklinkArgumentPresenter
        self.paletteHotkeyResolver = paletteHotkeyResolver
        self.snapshotUpdater = snapshotUpdater
    }

    func bootstrap(
        modelContainer: ModelContainer,
        availableCommands: @escaping @MainActor () -> Set<BuiltinItem> = {
            PluginRegistry.shared.availableCommands
        },
        toggleBuiltin: @escaping @MainActor (BuiltinItem) async -> Void = { _ in },
        runBuiltin: @escaping @MainActor (BuiltinItem) async -> Void = { _ in }
    ) {
        self.modelContainer = modelContainer
        self.availableCommands = availableCommands
        self.toggleBuiltin = toggleBuiltin
        self.runBuiltin = runBuiltin
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
            paletteHotkey: paletteHotkeyResolver(),
            availableCommands: availableCommands()
        )
        snapshotUpdater(snapshots)
    }

    /// Drop retained plugin hotkeys claimed by another active source while
    /// the plugin was uninstalled. This runs immediately before install, when
    /// `activeCommands` excludes the returning plugin's claims.
    @discardableResult
    func resolveRetainedPluginHotkeyConflicts(
        for returningCommands: Set<BuiltinItem>,
        activeCommands: Set<BuiltinItem>
    ) -> Int {
        resolveRetainedPluginHotkeyConflicts(
            for: returningCommands,
            activeCommands: activeCommands,
            paletteHotkey: paletteHotkeyResolver()
        )
    }

    @discardableResult
    func resolveRetainedPluginHotkeyConflicts(
        for returningCommands: Set<BuiltinItem>,
        activeCommands: Set<BuiltinItem>,
        paletteHotkey: HotkeyDescriptor?
    ) -> Int {
        guard let container = modelContainer else { return 0 }
        let context = container.mainContext
        let bindings = (try? context.fetch(
            FetchDescriptor<KeyBinding>(predicate: #Predicate { $0.isEnabled })
        )) ?? []
        let prefs = (try? context.fetch(FetchDescriptor<BuiltinPreference>())) ?? []
        let quicklinks = (try? context.fetch(FetchDescriptor<Quicklink>())) ?? []

        let activeDescriptors = Set(Self.compile(
            bindings: bindings,
            prefs: prefs,
            quicklinks: quicklinks,
            paletteHotkey: paletteHotkey,
            availableCommands: activeCommands
        ).map {
            HotkeyDescriptor(keyCode: $0.keyCode, modifierFlags: $0.modifierFlags)
        })

        var cleared = 0
        for pref in prefs {
            guard let item = BuiltinItem(rawValue: pref.itemKey),
                  returningCommands.contains(item),
                  let keyCode = pref.keyCode,
                  let modifierFlags = pref.modifierFlags,
                  activeDescriptors.contains(HotkeyDescriptor(
                      keyCode: keyCode,
                      modifierFlags: modifierFlags
                  )) else { continue }
            pref.keyCode = nil
            pref.modifierFlags = nil
            cleared += 1
        }
        if cleared > 0 {
            try? context.save()
        }
        return cleared
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
            Task { await toggleBuiltin(item) }
        case .runBuiltin(let key):
            guard let item = BuiltinItem(rawValue: key) else { return }
            Task { await runBuiltin(item) }
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
