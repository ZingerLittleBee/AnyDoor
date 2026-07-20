import SwiftData
import SwiftUI
import OSLog
import PluginInterface

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "panel")

/// Single source of truth for the merged panel data.
///
/// Owns the provider registry, reads BuiltinPreference / KeyBinding from SwiftData,
/// and exposes three collections to the views:
/// - `topLevelEntries` — built-in items, sorted by (group order index, displayOrder)
/// - `appShortcutChildren` — KeyBinding rows, sorted by KeyBinding.displayOrder
/// - `windowLayoutChildren` — the four window-layout action children, sorted by displayOrder
@Observable @MainActor
final class PanelStore {
    static let shared = PanelStore()

    private(set) var topLevelEntries: [PanelEntry] = []
    private(set) var appShortcutChildren: [PanelEntry] = []
    private(set) var windowLayoutChildren: [PanelEntry] = []

    /// On-disk app path for each app-shortcut binding id, captured in `rebuild()`.
    /// Settings rows read the Finder icon by path through this map instead of a
    /// per-render `binding(id:)` SwiftData fetch, which — combined with a
    /// synchronous `NSWorkspace.icon(forFile:)` read in the row body — dropped
    /// scroll frames as the List recycled app rows.
    private(set) var appShortcutPaths: [UUID: String] = [:]

    /// The window-layout child items that are partitioned out of topLevelEntries
    /// and exposed separately via `windowLayoutChildren`.
    static let windowLayoutChildKeys: Set<BuiltinItem> = [
        .windowLeftHalf, .windowRightHalf, .windowMaximize, .windowCenter,
        .windowTopHalf, .windowBottomHalf,
        .windowTopLeftQuarter, .windowTopRightQuarter,
        .windowBottomLeftQuarter, .windowBottomRightQuarter,
        .windowLeftThird, .windowCenterThird, .windowRightThird,
        .windowLeftTwoThirds, .windowRightTwoThirds,
        .windowMoveNextDisplay, .windowMovePreviousDisplay,
    ]

    private var providers: [BuiltinItem: any BuiltinProvider] = [:]
    private var modelContainer: ModelContainer?

    /// Whether a built-in command currently exists for the user. Wired to
    /// `PluginRegistry.isAvailable` in the app: commands claimed by an
    /// uninstalled Native Plugin are dropped from every rebuilt collection,
    /// so no panel row, palette entry, or settings row surfaces them.
    private var commandAvailability: @MainActor (BuiltinItem) -> Bool = { _ in true }

    /// Cached toggle states by item key. Refreshed on `refreshAll()`.
    private var toggleStates: [BuiltinItem: Bool] = [:]

    /// Cached permission states by item key.
    private var permissionStates: [BuiltinItem: PermissionStatus] = [:]

    /// Current Keep Awake state. Owns the `.timed(endDate:)` value used by the
    /// subtitle so views don't have to poll the provider on every rebuild.
    /// Pushed in via `onKeepAwakeStateChange` from the provider's expiration
    /// callback and from explicit mutations through `setKeepAwakeDuration`.
    private(set) var keepAwakeState: KeepAwakeState = .off

    /// Current Scheduled Shutdown state. Owns the `.armed(fireDate:)` value used
    /// by the subtitle. Pushed in via `onScheduledShutdownStateChange` from the
    /// service and from explicit mutations through `setScheduledShutdownDuration`.
    private(set) var scheduledShutdownState: ScheduledShutdownState = .off

    /// Per-item in-flight guard preventing overlapping toggles from desynchronizing state.
    private var togglesInFlight: Set<BuiltinItem> = []

    /// Per-item in-flight guard preventing overlapping action runs from racing.
    private var actionsInFlight: Set<BuiltinItem> = []

    /// Handle for the language-change observation loop. Stored so re-bootstrap
    /// (used by tests) cancels the previous loop instead of stacking another.
    private var languageObservationTask: Task<Void, Never>?

    init() {}

    func bootstrap(
        modelContainer: ModelContainer,
        providers: [any BuiltinProvider],
        commandAvailability: @escaping @MainActor (BuiltinItem) -> Bool = { _ in true }
    ) {
        self.modelContainer = modelContainer
        self.commandAvailability = commandAvailability
        self.providers = [:]
        for provider in providers {
            self.providers[provider.itemKey] = provider
        }
        rebuild()
        observeLanguageChanges()
    }

    /// Register an installed plugin's providers (PluginRegistry install hook).
    /// The caller triggers the rebuild via the refresh hook.
    func registerProviders(_ newProviders: [any BuiltinProvider]) {
        for provider in newProviders {
            providers[provider.itemKey] = provider
        }
    }

    /// Drop the providers of an uninstalled plugin's claimed commands
    /// (PluginRegistry uninstall hook).
    func unregisterProviders(for items: Set<BuiltinItem>) {
        for item in items {
            providers[item] = nil
            toggleStates[item] = nil
            permissionStates[item] = nil
        }
    }

    /// Recompute `topLevelEntries`, `appShortcutChildren`, and `windowLayoutChildren`
    /// from SwiftData + cached states.
    func rebuild() {
        guard let container = modelContainer else { return }
        let context = container.mainContext

        // Built-in preferences → topLevelEntries (and windowLayoutChildren)
        var topLevel: [PanelEntry] = []
        var windowChildren: [PanelEntry] = []
        if let prefs = try? context.fetch(
            FetchDescriptor<BuiltinPreference>(sortBy: [SortDescriptor(\.displayOrder)])
        ) {
            for pref in prefs {
                guard let item = BuiltinItem(rawValue: pref.itemKey) else { continue }
                if item.kind == .hiddenHotkey { continue }
                // Uninstalled-plugin commands are invisible everywhere; their
                // preference row is retained so a reinstall restores it.
                guard commandAvailability(item) else { continue }
                let hotkey = pref.keyCode.flatMap { code in
                    pref.modifierFlags.map { mods in
                        HotkeyDescriptor(keyCode: code, modifierFlags: mods)
                    }
                }
                let isWindowChild = Self.windowLayoutChildKeys.contains(item)
                let entry = PanelEntry(
                    id: PanelEntry.id(for: .builtin(item)),
                    source: .builtin(item),
                    displayOrder: pref.displayOrder,
                    isVisible: isWindowChild ? true : pref.isVisible,
                    hotkey: hotkey,
                    title: "",
                    subtitle: subtitle(for: item),
                    symbol: item.symbol,
                    kind: item.kind,
                    toggleState: item.kind == .toggle ? toggleStates[item] : nil,
                    permission: permissionStates[item] ?? (item.requiresAutomation ? .undetermined : .notRequired)
                )
                if isWindowChild {
                    windowChildren.append(entry)
                } else {
                    topLevel.append(entry)
                }
            }
        }

        // KeyBinding rows → appShortcutChildren
        var children: [PanelEntry] = []
        var pathMap: [UUID: String] = [:]
        if let bindings = try? context.fetch(
            FetchDescriptor<KeyBinding>(sortBy: [SortDescriptor(\.displayOrder)])
        ) {
            for binding in bindings {
                pathMap[binding.id] = binding.appPath
                // keyCode == -1 is the "unbound" sentinel used for newly-added
                // app shortcuts. Project it as a nil hotkey so the recorder
                // renders its placeholder instead of "Key(-1)".
                let descriptor: HotkeyDescriptor? = binding.keyCode >= 0
                    ? HotkeyDescriptor(keyCode: binding.keyCode,
                                       modifierFlags: binding.modifierFlags)
                    : nil
                let entry = PanelEntry(
                    id: PanelEntry.id(for: .appShortcut(binding.id)),
                    source: .appShortcut(binding.id),
                    displayOrder: binding.displayOrder,
                    isVisible: binding.isVisible,
                    hotkey: descriptor,
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

        // Flat order by displayOrder — the Panel settings page is an ungrouped
        // list and the menu-bar panel mirrors it. displayOrder is the canonical
        // hand-tuned order (see BuiltinItem.defaultOrder), normalized for
        // pre-existing stores by the one-shot flatten backfill in
        // BuiltinPreferenceSeeder.
        self.topLevelEntries = topLevel.sorted { $0.displayOrder < $1.displayOrder }
        self.appShortcutChildren = children
        self.appShortcutPaths = pathMap
        self.windowLayoutChildren = windowChildren.sorted { $0.displayOrder < $1.displayOrder }
    }

    private func subtitle(for item: BuiltinItem) -> String? {
        switch item {
        case .appShortcuts:
            let visible = appShortcutChildren.filter(\.isVisible).count
            return L(.portBindCount, visible)
        case .keepAwake:
            switch keepAwakeState {
            case .off:
                return nil
            case .indefinite:
                return L(.panelSubtitleKeepAwakeIndefinite)
            case .timed(let endDate):
                return L(.panelSubtitleKeepAwakeUntil, keepAwakeEndTimeString(endDate))
            }
        case .scheduledShutdown:
            switch scheduledShutdownState {
            case .off:
                return nil
            case .armed(let fireDate):
                return L(.panelSubtitleShutdownAt, shutdownTimeString(fireDate))
            }
        default:
            return nil
        }
    }

    /// Renders an end-time using the app's currently selected language.
    /// Built per call rather than cached statically because a `DateFormatter`'s
    /// locale is frozen at construction — switching language at runtime would
    /// otherwise leave the time stuck in the boot-time locale even though the
    /// surrounding strings update via `observeLanguageChanges`.
    private func keepAwakeEndTimeString(_ endDate: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = LocalizationManager.shared.effectiveLocale
        return formatter.string(from: endDate)
    }

    /// Renders the shutdown target time using the app's current language. Built
    /// per call because a `DateFormatter`'s locale is frozen at construction.
    private func shutdownTimeString(_ fireDate: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = LocalizationManager.shared.effectiveLocale
        return formatter.string(from: fireDate)
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
        // Pull the full Keep Awake state (incl. the timed end-date) so the
        // subtitle reflects what the provider actually holds — `readState`
        // above only restores the boolean.
        if let provider = providers[.keepAwake] as? KeepAwakeProvider {
            keepAwakeState = await provider.currentState
        }
        scheduledShutdownState = ScheduledShutdownService.shared.state
        toggleStates[.scheduledShutdown] = scheduledShutdownState.isArmed
        rebuild()
    }

    /// Toggle a built-in. Reads current state and flips it.
    ///
    /// Guarded against overlapping calls: a second invocation while the first is mid-flight
    /// is dropped, preventing two reads from observing the same stale state and double-flipping.
    func toggle(_ item: BuiltinItem) async {
        // Keep Awake routes through its duration-aware path so the cached
        // `keepAwakeState` (incl. the timed end-date) stays in sync without
        // waiting for the provider's async onChange hop. The on/off decision
        // is taken from the provider directly rather than from the MainActor
        // cache so a hotkey press at the moment of timer expiration cannot
        // read a stale `.timed` value and invert the user's intent.
        if item == .keepAwake {
            guard let provider = providers[.keepAwake] as? KeepAwakeProvider else { return }
            guard !togglesInFlight.contains(item) else { return }
            togglesInFlight.insert(item)
            defer { togglesInFlight.remove(item) }
            let current = await provider.currentState
            await setKeepAwakeDuration(current.isOn ? nil : .indefinite)
            return
        }

        if item == .scheduledShutdown {
            guard !togglesInFlight.contains(item) else { return }
            togglesInFlight.insert(item)
            defer { togglesInFlight.remove(item) }
            let armed = ScheduledShutdownService.shared.state.isArmed
            await setScheduledShutdownDuration(
                armed ? nil : .minutes(ScheduledShutdownService.shared.defaultMinutes)
            )
            return
        }

        guard let provider = providers[item] as? any ToggleProvider else { return }
        guard !togglesInFlight.contains(item) else { return }
        togglesInFlight.insert(item)
        defer { togglesInFlight.remove(item) }
        do {
            let current = try await provider.readState()
            try await provider.setState(!current)
            toggleStates[item] = !current
            rebuild()
        } catch {
            logger.error("Toggle \(item.rawValue) failed: \(error)")
        }
    }

    /// Apply a Keep Awake duration (or `nil` to turn it off). The provider's
    /// expiration callback will subsequently push the `.off` transition back
    /// through `onKeepAwakeStateChange`, but we also cache eagerly here so
    /// the panel doesn't render a stale frame between this call and the hop
    /// back to MainActor.
    func setKeepAwakeDuration(_ duration: KeepAwakeDuration?) async {
        guard let provider = providers[.keepAwake] as? KeepAwakeProvider else { return }
        do {
            try await provider.apply(duration)
        } catch {
            logger.error("Keep Awake apply failed: \(error)")
            // Fall through — the same resync block runs on success and
            // failure, so the cached row state always reflects whatever the
            // provider actually holds rather than what we optimistically
            // hoped to set.
        }
        let state = await provider.currentState
        keepAwakeState = state
        toggleStates[.keepAwake] = state.isOn
        rebuild()
    }

    /// Callback target wired into `KeepAwakeProvider.onChange`. Invoked on the
    /// MainActor when the provider's state transitions for any reason —
    /// explicit mutation, hotkey, or timed expiration.
    func onKeepAwakeStateChange(_ state: KeepAwakeState) {
        keepAwakeState = state
        toggleStates[.keepAwake] = state.isOn
        rebuild()
    }

    /// Apply a Scheduled Shutdown duration (or `nil` to cancel). Caches state
    /// eagerly so the panel doesn't render a stale frame.
    func setScheduledShutdownDuration(_ duration: ScheduledShutdownDuration?) async {
        if let duration {
            ScheduledShutdownService.shared.arm(duration)
        } else {
            ScheduledShutdownService.shared.cancel()
        }
        scheduledShutdownState = ScheduledShutdownService.shared.state
        toggleStates[.scheduledShutdown] = scheduledShutdownState.isArmed
        rebuild()
    }

    /// Callback target wired into `ScheduledShutdownService.onChange`.
    func onScheduledShutdownStateChange(_ state: ScheduledShutdownState) {
        scheduledShutdownState = state
        toggleStates[.scheduledShutdown] = state.isArmed
        rebuild()
    }

    /// Run a one-shot action.
    ///
    /// Guarded against overlapping calls: a second invocation for the same item while the
    /// first is mid-flight is dropped. Actor isolation alone does not serialize runs — an
    /// `actor` provider yields its executor at every `await`.
    func run(_ item: BuiltinItem) async {
        guard let provider = providers[item] as? any ActionProvider else { return }
        guard !actionsInFlight.contains(item) else { return }
        actionsInFlight.insert(item)
        defer { actionsInFlight.remove(item) }
        do {
            try await provider.run()
        } catch {
            logger.error("Run \(item.rawValue) failed: \(error)")
        }
    }

    /// Watches `LocalizationManager.preference` so cached, localized fields
    /// (e.g. `PanelEntry.subtitle`) refresh the moment the user switches
    /// language. `withObservationTracking` fires once per change; the loop
    /// re-registers after each rebuild so subsequent changes are also caught.
    ///
    /// Cancels any prior observation task so repeated `bootstrap()` calls
    /// (test harnesses) don't stack concurrent loops.
    private func observeLanguageChanges() {
        languageObservationTask?.cancel()
        languageObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = LocalizationManager.shared.preference
                    } onChange: {
                        cont.resume()
                    }
                }
                guard !Task.isCancelled, let self else { return }
                self.rebuild()
            }
        }
    }

    /// Look up a KeyBinding by id from the SwiftData store.
    func binding(id: UUID) -> KeyBinding? {
        guard let container = modelContainer else { return nil }
        let context = container.mainContext
        let descriptor = FetchDescriptor<KeyBinding>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    /// Look up the current hotkey assigned to a built-in item, if any.
    /// Reads from SwiftData rather than `topLevelEntries` so it works for
    /// hidden-hotkey items (e.g., brightness ±).
    func hotkeyForBuiltin(_ item: BuiltinItem) -> HotkeyDescriptor? {
        guard let container = modelContainer else { return nil }
        let key = item.rawValue
        guard let pref = try? container.mainContext.fetch(
            FetchDescriptor<BuiltinPreference>(predicate: #Predicate { $0.itemKey == key })
        ).first,
        let code = pref.keyCode, let mods = pref.modifierFlags else { return nil }
        return HotkeyDescriptor(keyCode: code, modifierFlags: mods)
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
            HotkeyCoordinator.shared.refresh()
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
            HotkeyCoordinator.shared.refresh()
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
        HotkeyCoordinator.shared.refresh()
    }

    /// Reorder the top-level entries as one flat list. Reassigns a global
    /// `displayOrder` (stride 100) across the passed order; window-layout
    /// children (partitioned into `windowLayoutChildren`, never present in
    /// `newOrder`) keep their own order untouched.
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
        HotkeyCoordinator.shared.refresh()
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

    /// Reorder the four window-layout children by new keys array (ordered).
    ///
    /// Rewrites `BuiltinPreference.displayOrder` for each window child in
    /// 100-step increments so the popover reflects the user's drag order
    /// from the Settings panel. Non-window keys in `newOrder` are ignored.
    func reorderWindowChildren(by newOrder: [BuiltinItem]) {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        guard let prefs = try? context.fetch(FetchDescriptor<BuiltinPreference>()) else { return }
        let prefsByKey = Dictionary(uniqueKeysWithValues: prefs.map { ($0.itemKey, $0) })
        var order: Double = 100
        for item in newOrder {
            guard Self.windowLayoutChildKeys.contains(item) else { continue }
            if let pref = prefsByKey[item.rawValue] {
                pref.displayOrder = order
                order += 100
            }
        }
        try? context.save()
        rebuild()
        HotkeyCoordinator.shared.refresh()
    }

    /// Find which entry currently owns a given hotkey (used for conflict detection).
    ///
    /// Scans visible top-level rows + visible app shortcut children + hidden-hotkey
    /// built-ins (e.g., brightness ±) so all hotkey bindings participate in conflict
    /// detection regardless of whether they render as a panel row.
    func entryUsingHotkey(_ hotkey: HotkeyDescriptor, excluding: PanelEntry.Source? = nil) -> PanelEntry? {
        var pool = topLevelEntries + appShortcutChildren + windowLayoutChildren

        if let container = modelContainer {
            let context = container.mainContext
            if let prefs = try? context.fetch(FetchDescriptor<BuiltinPreference>()) {
                for pref in prefs {
                    guard let item = BuiltinItem(rawValue: pref.itemKey),
                          item.kind == .hiddenHotkey,
                          let code = pref.keyCode,
                          let mods = pref.modifierFlags else { continue }
                    let entry = PanelEntry(
                        id: PanelEntry.id(for: .builtin(item)),
                        source: .builtin(item),
                        displayOrder: pref.displayOrder,
                        isVisible: false,
                        hotkey: HotkeyDescriptor(keyCode: code, modifierFlags: mods),
                        title: L(item.titleKey),
                        subtitle: nil,
                        symbol: item.symbol,
                        kind: .hiddenHotkey,
                        toggleState: nil,
                        permission: .notRequired
                    )
                    pool.append(entry)
                }
            }
        }

        for entry in pool {
            if entry.source == excluding { continue }
            if entry.hotkey == hotkey { return entry }
        }
        return nil
    }

    /// Create a new app shortcut row from an NSOpenPanel selection.
    ///
    /// The new row is inserted with `isEnabled: false` and `keyCode: -1` as a sentinel,
    /// meaning it appears in the submenu but doesn't fire until the user records a hotkey
    /// via `updateAppShortcut(id:hotkey:)` (which flips `isEnabled = true`).
    func addAppShortcut(appBundleID: String, appName: String, appPath: String) {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        let nextOrder = (appShortcutChildren.map(\.displayOrder).max() ?? 0) + 100
        let new = KeyBinding(
            keyCode: -1,
            modifierFlags: 0,
            appBundleID: appBundleID,
            appName: appName,
            appPath: appPath,
            isEnabled: false,
            isVisible: true,
            displayOrder: nextOrder
        )
        context.insert(new)
        try? context.save()
        rebuild()
        HotkeyCoordinator.shared.refresh()
    }

    /// Delete an app shortcut by id.
    func deleteAppShortcut(id: UUID) {
        guard let binding = binding(id: id), let container = modelContainer else { return }
        container.mainContext.delete(binding)
        try? container.mainContext.save()
        rebuild()
        HotkeyCoordinator.shared.refresh()
    }
}
