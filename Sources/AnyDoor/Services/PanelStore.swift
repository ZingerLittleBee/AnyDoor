import SwiftData
import SwiftUI
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "panel")

/// Single source of truth for the merged panel data.
///
/// Owns the provider registry, reads BuiltinPreference / KeyBinding from SwiftData,
/// and exposes two collections to the views:
/// - `topLevelEntries` — built-in items, sorted by BuiltinPreference.displayOrder
/// - `appShortcutChildren` — KeyBinding rows, sorted by KeyBinding.displayOrder
@Observable @MainActor
final class PanelStore {
    static let shared = PanelStore()

    private(set) var topLevelEntries: [PanelEntry] = []
    private(set) var appShortcutChildren: [PanelEntry] = []

    private var providers: [BuiltinItem: any BuiltinProvider] = [:]
    private var modelContainer: ModelContainer?

    /// Cached toggle states by item key. Refreshed on `refreshAll()`.
    private var toggleStates: [BuiltinItem: Bool] = [:]

    /// Cached permission states by item key.
    private var permissionStates: [BuiltinItem: PermissionStatus] = [:]

    private init() {}

    func bootstrap(
        modelContainer: ModelContainer,
        providers: [any BuiltinProvider]
    ) {
        self.modelContainer = modelContainer
        for provider in providers {
            self.providers[provider.itemKey] = provider
        }
        rebuild()
    }

    /// Recompute `topLevelEntries` and `appShortcutChildren` from SwiftData + cached states.
    func rebuild() {
        guard let container = modelContainer else { return }
        let context = container.mainContext

        // Built-in preferences → topLevelEntries
        var topLevel: [PanelEntry] = []
        if let prefs = try? context.fetch(
            FetchDescriptor<BuiltinPreference>(sortBy: [SortDescriptor(\.displayOrder)])
        ) {
            for pref in prefs {
                guard let item = BuiltinItem(rawValue: pref.itemKey) else { continue }
                let hotkey = pref.keyCode.flatMap { code in
                    pref.modifierFlags.map { mods in
                        HotkeyDescriptor(keyCode: code, modifierFlags: mods)
                    }
                }
                let entry = PanelEntry(
                    id: PanelEntry.id(for: .builtin(item)),
                    source: .builtin(item),
                    displayOrder: pref.displayOrder,
                    isVisible: pref.isVisible,
                    hotkey: hotkey,
                    title: item.title,
                    subtitle: subtitle(for: item),
                    symbol: item.symbol,
                    kind: item.kind,
                    toggleState: item.kind == .toggle ? toggleStates[item] : nil,
                    permission: permissionStates[item] ?? (item.requiresAutomation ? .undetermined : .notRequired)
                )
                topLevel.append(entry)
            }
        }

        // KeyBinding rows → appShortcutChildren
        var children: [PanelEntry] = []
        if let bindings = try? context.fetch(
            FetchDescriptor<KeyBinding>(sortBy: [SortDescriptor(\.displayOrder)])
        ) {
            for binding in bindings {
                let entry = PanelEntry(
                    id: PanelEntry.id(for: .appShortcut(binding.id)),
                    source: .appShortcut(binding.id),
                    displayOrder: binding.displayOrder,
                    isVisible: binding.isVisible,
                    hotkey: HotkeyDescriptor(keyCode: binding.keyCode,
                                              modifierFlags: binding.modifierFlags),
                    title: binding.appName,
                    subtitle: nil,
                    symbol: "app.fill",
                    kind: .submenu, // children render like rows but inside the popover
                    toggleState: nil,
                    permission: .notRequired
                )
                children.append(entry)
            }
        }

        self.topLevelEntries = topLevel
        self.appShortcutChildren = children
    }

    private func subtitle(for item: BuiltinItem) -> String? {
        switch item {
        case .appShortcuts:
            let visible = appShortcutChildren.filter(\.isVisible).count
            return "\(visible) 个绑定"
        case .keepAwake:
            return (toggleStates[.keepAwake] ?? false) ? "无限期保持唤醒" : nil
        default:
            return nil
        }
    }

    /// Refresh every toggle provider's state. Called from MenuBarView.onAppear.
    func refreshAll() async {
        for (item, provider) in providers {
            if let toggle = provider as? any ToggleProvider {
                if let state = try? await toggle.readState() {
                    toggleStates[item] = state
                }
            }
            permissionStates[item] = await provider.permission
        }
        rebuild()
    }

    /// Toggle a built-in. Reads current state and flips it.
    func toggle(_ item: BuiltinItem) async {
        guard let provider = providers[item] as? any ToggleProvider else { return }
        do {
            let current = try await provider.readState()
            try await provider.setState(!current)
            toggleStates[item] = !current
            rebuild()
        } catch {
            logger.error("Toggle \(item.rawValue) failed: \(error)")
        }
    }

    /// Run a one-shot action.
    func run(_ item: BuiltinItem) async {
        guard let provider = providers[item] as? any ActionProvider else { return }
        do {
            try await provider.run()
        } catch {
            logger.error("Run \(item.rawValue) failed: \(error)")
        }
    }

    // MARK: - Hotkey dispatch + snapshot rebuild

    /// Handle a matched hotkey. Called on the main thread by HotkeyService.
    func dispatch(_ action: HotkeyAction) {
        switch action {
        case .launchApp(let bundleID, let path):
            AppSwitcher.toggle(bundleID: bundleID, appPath: path)
        case .toggleBuiltin(let key):
            guard let item = BuiltinItem(rawValue: key) else { return }
            Task { await self.toggle(item) }
        case .runBuiltin(let key):
            guard let item = BuiltinItem(rawValue: key) else { return }
            Task { await self.run(item) }
        }
    }

    /// Build a snapshot list for HotkeyService from current SwiftData state.
    /// Called whenever bindings or preferences change.
    func rebuildHotkeySnapshots() {
        guard let container = modelContainer else { return }
        let context = container.mainContext

        var out: [HotkeySnapshot] = []

        if let bindings = try? context.fetch(
            FetchDescriptor<KeyBinding>(predicate: #Predicate { $0.isEnabled })
        ) {
            for binding in bindings {
                out.append(HotkeySnapshot(
                    keyCode: binding.keyCode,
                    modifierFlags: binding.modifierFlags,
                    action: .launchApp(bundleID: binding.appBundleID, path: binding.appPath)
                ))
            }
        }

        if let prefs = try? context.fetch(FetchDescriptor<BuiltinPreference>()) {
            for pref in prefs {
                guard let item = BuiltinItem(rawValue: pref.itemKey),
                      let code = pref.keyCode,
                      let mods = pref.modifierFlags,
                      item.kind != .submenu else { continue }
                let action: HotkeyAction = item.kind == .toggle
                    ? .toggleBuiltin(itemKey: item.rawValue)
                    : .runBuiltin(itemKey: item.rawValue)
                out.append(HotkeySnapshot(
                    keyCode: code,
                    modifierFlags: mods,
                    action: action
                ))
            }
        }

        HotkeyService.shared.updateSnapshots(out)
    }

    /// Look up a KeyBinding by id from the SwiftData store.
    func binding(id: UUID) -> KeyBinding? {
        guard let container = modelContainer else { return nil }
        let context = container.mainContext
        let descriptor = FetchDescriptor<KeyBinding>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    // MARK: - Mutations

    /// Update visibility for a built-in.
    func setBuiltinVisibility(_ item: BuiltinItem, isVisible: Bool) {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        let key = item.rawValue
        if let pref = try? context.fetch(
            FetchDescriptor<BuiltinPreference>(predicate: #Predicate { $0.itemKey == key })
        ).first {
            pref.isVisible = isVisible
            try? context.save()
            rebuild()
            rebuildHotkeySnapshots()
        }
    }

    /// Update hotkey for a built-in. Pass nil to clear.
    func setBuiltinHotkey(_ item: BuiltinItem, hotkey: HotkeyDescriptor?) {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        let key = item.rawValue
        if let pref = try? context.fetch(
            FetchDescriptor<BuiltinPreference>(predicate: #Predicate { $0.itemKey == key })
        ).first {
            pref.keyCode = hotkey?.keyCode
            pref.modifierFlags = hotkey?.modifierFlags
            try? context.save()
            rebuild()
            rebuildHotkeySnapshots()
        }
    }

    /// Update KeyBinding fields (visibility / hotkey).
    ///
    /// Setting a non-nil hotkey also flips `isEnabled = true` so newly-added rows
    /// (created via the settings UI with the sentinel `isEnabled: false`) become
    /// active as soon as the user records a hotkey.
    func updateAppShortcut(id: UUID, isVisible: Bool? = nil, hotkey: HotkeyDescriptor? = nil) {
        guard let binding = binding(id: id), let container = modelContainer else { return }
        if let v = isVisible { binding.isVisible = v }
        if let hk = hotkey {
            binding.keyCode = hk.keyCode
            binding.modifierFlags = hk.modifierFlags
            binding.isEnabled = true
        }
        try? container.mainContext.save()
        rebuild()
        rebuildHotkeySnapshots()
    }

    /// Reorder top-level entries by new keys array (ordered).
    func reorderTopLevel(by newOrder: [BuiltinItem]) {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        guard let prefs = try? context.fetch(FetchDescriptor<BuiltinPreference>()) else { return }
        let prefsByKey = Dictionary(uniqueKeysWithValues: prefs.map { ($0.itemKey, $0) })
        var order: Double = 100
        for item in newOrder {
            if let pref = prefsByKey[item.rawValue] {
                pref.displayOrder = order
                order += 100
            }
        }
        try? context.save()
        rebuild()
        rebuildHotkeySnapshots()
    }

    /// Reorder app shortcuts by new id array (ordered).
    func reorderAppShortcuts(by newOrder: [UUID]) {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        var order: Double = 100
        for id in newOrder {
            if let binding = binding(id: id) {
                binding.displayOrder = order
                order += 100
            }
        }
        try? context.save()
        rebuild()
    }

    /// Find which entry currently owns a given hotkey (used for conflict detection).
    func entryUsingHotkey(_ hotkey: HotkeyDescriptor, excluding: PanelEntry.Source? = nil) -> PanelEntry? {
        for entry in topLevelEntries + appShortcutChildren {
            if entry.source == excluding { continue }
            if entry.hotkey == hotkey { return entry }
        }
        return nil
    }
}
