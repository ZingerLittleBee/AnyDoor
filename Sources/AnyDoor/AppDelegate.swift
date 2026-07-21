import Cocoa
import PluginInterface
import SwiftData
import SwiftUI
import OSLog
import AskForPermission
import Sparkle

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "persistence")

final class AppDelegate: NSObject, NSApplicationDelegate {
    let modelContainer: ModelContainer
    @MainActor var localizationManager: LocalizationManager { LocalizationManager.shared }
    private var menuBarController: MenuBarController?
    private var defaultsObserver: NSObjectProtocol?
    private var updaterController: SPUStandardUpdaterController?
    private var updaterBridge: SparkleUpdaterBridge?
    private var clipboardWatcher: ClipboardWatcher?

    /// Monotonic process-launch reference (seconds since boot). Captured at
    /// instantiation — the earliest reliable point, since the delegate exists
    /// before any callback and a login-launch reopen can precede
    /// `applicationDidFinishLaunching`. See `shouldOpenSettingsForReopen`.
    private let launchUptime = ProcessInfo.processInfo.systemUptime

    /// How long after launch a no-window reopen is still attributed to the
    /// system's login auto-launch rather than a user relaunch.
    static let reopenSettingsLaunchGrace: TimeInterval = 3

    override init() {
        // Force overlay (floating, auto-hiding) scrollers app-wide, regardless
        // of the system "Show scroll bars: Always" setting. Writing it to the
        // app's own defaults domain (higher priority than NSGlobalDomain, where
        // the system value lives) overrides it for this process, so every
        // NSScrollView — SwiftUI ScrollView/Form/List, popovers, the menu panel
        // — is *born* with overlay scrollers. That avoids the legacy thick
        // scrollbar entirely, and the one-frame flash that any after-the-fact
        // restyling causes on a Settings tab switch. See OverlayScrollers.swift.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let storeDir = appSupport.appendingPathComponent("dev.bybee.AnyDoor", isDirectory: true)
            try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            let storeURL = storeDir.appendingPathComponent("AnyDoor.store")
            let config = ModelConfiguration(url: storeURL)
            // Core-owned model types plus every plugin's (ADR-0005: plugin
            // schema is registered unconditionally, so user data survives
            // Uninstall and a later Install restores it).
            let schema = Schema(
                [
                    KeyBinding.self, BuiltinPreference.self, ClipboardHistoryItem.self,
                    TranslationRecord.self, Quicklink.self,
                ]
                + NativePluginCatalog.modelSchemaTypes
            )
            modelContainer = try ModelContainer(for: schema, configurations: config)

            let legacyURL = appSupport.appendingPathComponent("default.store")
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                Self.migrateLegacyStore(from: legacyURL, into: modelContainer)
            }
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        super.init()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        AskForPermission.configure(appName: "AnyDoor")
        SettingsWindowController.bootstrap(modelContainer: modelContainer)

        // Run migrations / seeding on the main context
        let context = modelContainer.mainContext
        KeyBindingOrderBackfill.runIfNeeded(in: context)
        BuiltinPreferenceSeeder.seedIfNeeded(in: context)
        QuicklinkSeeder.seedIfNeeded(in: context)

        // Bootstrap clipboard history store so providers can record entries.
        ClipboardHistoryStore.shared.bootstrap(modelContainer: modelContainer)
        ClipboardHistoryStore.shared.setMaxAge(ClipboardPreferences.retention.maxAge)
        // First drop tag ids whose definition no longer exists (crash between
        // a registry delete and the item sweep), then run the forced prune so
        // rows that were exempt only by a ghost tag are reclaimed — including
        // their on-disk payloads — right at launch.
        Task {
            await ClipboardHistoryStore.shared.cleanUpUnknownTags(
                validIDs: Set(ClipboardTagStore.shared.tags.map(\.id))
            )
            await ClipboardHistoryStore.shared.pruneExpiredAndOverflow(force: true)
        }

        // Start the clipboard watcher. Internal pasteboard writes suppress
        // their own capture through `ClipboardWatcher.selfWrite`.
        let watcher = ClipboardWatcher(store: ClipboardHistoryStore.shared)
        watcher.start()
        clipboardWatcher = watcher
        ClipboardWatcher.shared = watcher
        ClipboardWallWindowController.shared.modelContainer = modelContainer

        // Native Plugins: the registry loads the installed set, activates the
        // installed plugins, and owns surface composition for launch and
        // later lifecycle changes. Core control flow names no plugin beyond
        // this list (ADR-0007).
        let pluginHost = CorePluginHost(modelContainer: modelContainer)
        let plugins = NativePluginCatalog.makePlugins(host: pluginHost)
        // One-time usage-trace migration writes the install state directly and
        // must precede the bootstrap, which activates the migrated-installed
        // plugins through the normal launch path.
        PluginUsageMigration.runIfNeeded(plugins: plugins, in: context)
        let coreProviders = BuiltinProviderRegistry.makeAll(onKeepAwakeChange: { state in
            PanelStore.shared.onKeepAwakeStateChange(state)
        })
        PluginRegistry.shared.bootstrap(
            plugins: plugins,
            modelContainer: modelContainer,
            coreProviders: coreProviders
        )
        // Script Plugins: the second plugin kind. Discover Sideloaded packages
        // in storage, activate the installed ones, and register their palette
        // row sources. Independent of the Native registry — its own lifecycle
        // core and install-state key (machine-local, out of config backup).
        ScriptPluginRegistry.shared.bootstrap()
        QuicklinkStore.shared.bootstrap(modelContainer: modelContainer)

        // Translation history: give the store the shared container, then point
        // the coordinator at it so successful translations get recorded.
        TranslationHistoryStore.shared.configure(modelContainer: modelContainer)
        TranslationCoordinator.shared.history = TranslationHistoryStore.shared

        // Scheduled Shutdown: push state to the panel and re-arm any persisted
        // schedule (or cancel a deadline missed while the app was quit).
        ScheduledShutdownService.shared.onChange = { state in
            PanelStore.shared.onScheduledShutdownStateChange(state)
        }
        ScheduledShutdownService.shared.bootstrapOnLaunch()

        // Brightness control (external DDC/CI displays). Arch-selected backend.
        #if arch(arm64)
        let ddcBackend: any DDCBackend = Arm64DDCBackend()
        #else
        let ddcBackend: any DDCBackend = IntelDDCBackend()
        #endif
        let brightnessController = BrightnessController(backend: ddcBackend)
        DisplayBrightnessService.shared.bootstrap(controller: brightnessController)

        // Pre-warm the brightness service so the first hover finds data cached.
        Task.detached(priority: .utility) {
            await DisplayBrightnessService.shared.refresh()
        }

        // Warm the currency rate table (at most one network call per day) so the
        // command palette's inline currency conversion has data on first use.
        Task { await CurrencyRatesService.shared.refreshIfStale() }

        // Wire HotkeyService dispatcher
        HotkeyService.shared.setDispatcher { action in
            HotkeyCoordinator.shared.dispatch(action)
        }

        HotkeyService.shared.setQuickPressDispatcher { @MainActor action in
            QuickPressEmitter.emit(action, trigger: HyperKeyService.shared.trigger)
        }

        if !HotkeyService.hasAccessibilityPermission {
            HotkeyService.requestAccessibilityPermission()
        }

        HotkeyService.shared.start()
        HotkeyCoordinator.shared.refresh()

        // Hyper Key Phase 1: unconditional reconcile of last-known mapping.
        // Phase 2: tap-gated apply, handled inside HyperKeyService.bootstrapAfterTap.
        Task {
            try? await HyperKeyController.shared.reconcile()
            await HyperKeyService.shared.bootstrapAfterTap()
        }

        // Hyper Key cleanup on system shutdown.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { try? await HyperKeyController.shared.clear() }
        }

        // Menu bar status item. Replaces SwiftUI `MenuBarExtra`, whose
        // `isInserted: false` state infinite-loops the scene graph on macOS 26.
        let menuBar = MenuBarController(modelContainer: modelContainer)
        menuBar.install()
        menuBarController = menuBar
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak menuBar] _ in
            // Run synchronously on the main thread via MainThreadIsolation rather
            // than MainActor.assumeIsolated, whose swift_task_isCurrentExecutor
            // check can fault on the main thread after a ScreenCaptureKit capture
            // (see ClipboardWatcher / MainThreadIsolation).
            MainThreadIsolation.run { menuBar?.syncFromPreferences() }
        }
        bootstrapUpdater()

        // First-run onboarding. Shows once on a clean install; afterwards it is
        // only reachable from Settings (the window opts out of state restoration
        // and reverts the app to `.accessory` when closed).
        if !OnboardingState.hasCompleted() {
            OnboardingWindowController.shared.show()
        }

        // Dev-only probe: auto-open a window at launch so UI work can be
        // verified headlessly (screenshot loops) without clicking the status
        // item. No effect unless the env var is set.
        if ProcessInfo.processInfo.environment["ANYDOOR_OPEN_SETTINGS"] == "1" {
            SettingsOpener.shared.tryOpen()
        }
    }

    @MainActor
    private func bootstrapUpdater() {
        guard shouldStartUpdater() else {
            // `swift run` and unit tests reach here: no SUFeedURL/SUPublicEDKey, no
            // installed bundle id. Sparkle would log noisy errors and could crash.
            return
        }

        let bridge = SparkleUpdaterBridge(service: UpdateService.shared)
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: bridge,
            userDriverDelegate: nil
        )
        UpdateService.shared.rebind(to: SparkleUpdaterAdapter(updater: controller.updater))
        updaterController = controller
        updaterBridge = bridge

        // Sparkle's `startingUpdater` only schedules interval-gated checks; it does
        // not check on every launch. Force a silent check now so a relaunch surfaces
        // a newer version immediately instead of waiting out the 24h cadence. Per
        // Sparkle's API contract this is only safe right after starting the updater,
        // and only when automatic checks are enabled — results flow through the
        // delegate into `UpdateService.availableVersion` (no extra Sparkle UI).
        if UpdateService.shared.automaticChecksEnabled {
            UpdateService.shared.checkForUpdatesInBackground()
        }
    }

    private func shouldStartUpdater() -> Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let hasFeed = !((info["SUFeedURL"] as? String) ?? "").isEmpty
        let hasKey = !((info["SUPublicEDKey"] as? String) ?? "").isEmpty
        let isInstalled = Bundle.main.bundleIdentifier == "dev.bybee.AnyDoor"
        let placeholderKey = (info["SUPublicEDKey"] as? String) == "PLACEHOLDER_REPLACE_WITH_GENERATE_KEYS_OUTPUT"
        return hasFeed && hasKey && isInstalled && !placeholderKey
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyService.shared.stop()
        clipboardWatcher?.stop()
    }

    // MARK: - State restoration

    // AnyDoor is a menu-bar utility: no window should appear unless the user
    // explicitly opens it. Opting out of application state restoration stops
    // macOS from reopening the Settings window when the app auto-launches at
    // login (or via "reopen windows when logging back in"). The user can still
    // open Settings from the menu-bar item at any time.
    func application(_ app: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ app: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard HyperKeyController.shared.hasPersistedSignatures else {
            return .terminateNow
        }
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    try? await HyperKeyController.shared.clear()
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                await group.next()
                group.cancelAll()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// When the icon is hidden the menu bar item disappears and the app keeps
    /// the `.accessory` policy (no Dock icon). Re-launching AnyDoor from
    /// Finder/Spotlight lands here; with no visible window, re-open Settings so
    /// the user can turn the icon back on.
    ///
    /// macOS starts a login item by sending a reopen Apple Event, which also
    /// lands here with `flag == false` on a fresh menu-bar launch — we must NOT
    /// pop Settings open on every login. `shouldOpenSettingsForReopen` keys on
    /// the menu-bar icon (a visible icon means the user can always reach
    /// Settings, so a reopen never needs to open it) so a delayed login reopen
    /// no longer surfaces Settings on startup.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        let elapsed = ProcessInfo.processInfo.systemUptime - launchUptime
        let decision = Self.reopenHandlingDecision(
            hasVisibleWindows: flag,
            menuBarIconVisible: MenuBarIcon.isVisible,
            secondsSinceLaunch: elapsed
        )
        if decision.shouldOpenSettings {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        return decision.allowDefaultHandling
    }

    struct ReopenHandlingDecision: Equatable {
        let shouldOpenSettings: Bool
        let allowDefaultHandling: Bool
    }

    static func reopenHandlingDecision(hasVisibleWindows: Bool,
                                       menuBarIconVisible: Bool,
                                       secondsSinceLaunch: TimeInterval) -> ReopenHandlingDecision {
        ReopenHandlingDecision(
            shouldOpenSettings: shouldOpenSettingsForReopen(
                hasVisibleWindows: hasVisibleWindows,
                menuBarIconVisible: menuBarIconVisible,
                secondsSinceLaunch: secondsSinceLaunch
            ),
            // AnyDoor owns every intentional Settings-opening path. Returning true
            // lets AppKit/SwiftUI apply default reopen behavior, which can surface
            // Settings during login even when the delegate suppressed its explicit
            // open request.
            allowDefaultHandling: false
        )
    }

    /// Decides whether a reopen event should surface Settings.
    ///
    /// The only reason to auto-open Settings on a reopen is recovery: the
    /// menu-bar icon is hidden, so the user has no other entry point and
    /// relaunched (e.g. from Finder) to get back in. When the icon is visible —
    /// the normal case, including every login auto-launch for most users — the
    /// user can always open Settings from the icon, so a reopen must never pop
    /// Settings. This is what keeps Settings closed on login auto-launch
    /// regardless of how late a busy login session delivers the reopen Apple
    /// Event (a fixed launch-age window alone was unreliable: under load the
    /// reopen can arrive seconds after launch and read as a user relaunch).
    ///
    /// In the hidden-icon recovery case, `reopenSettingsLaunchGrace` still gates
    /// out the login auto-launch's own reopen (arriving within the grace) from a
    /// genuine later relaunch.
    static func shouldOpenSettingsForReopen(hasVisibleWindows: Bool,
                                            menuBarIconVisible: Bool,
                                            secondsSinceLaunch: TimeInterval) -> Bool {
        guard !hasVisibleWindows else { return false }
        // Icon visible -> reachable from the menu bar; never auto-pop Settings.
        guard !menuBarIconVisible else { return false }
        // Icon hidden: only a genuine post-launch relaunch surfaces Settings.
        return secondsSinceLaunch >= reopenSettingsLaunchGrace
    }

    /// Hot-reload entry point used by views after data changes.
    @MainActor
    func refreshBindings() {
        PanelStore.shared.rebuild()
        HotkeyCoordinator.shared.refresh()
    }

    // MARK: - Legacy store migration (unchanged behavior, just preserved)

    private static func migrateLegacyStore(from legacyURL: URL, into container: ModelContainer) {
        do {
            let legacyConfig = ModelConfiguration(url: legacyURL)
            let legacyContainer = try ModelContainer(for: KeyBinding.self, configurations: legacyConfig)
            let legacyContext = ModelContext(legacyContainer)

            let legacyBindings = try legacyContext.fetch(FetchDescriptor<KeyBinding>())
            guard !legacyBindings.isEmpty else {
                removeLegacyFiles(at: legacyURL)
                return
            }

            let targetContext = ModelContext(container)
            let existingBindings = try targetContext.fetch(FetchDescriptor<KeyBinding>())
            let existingIDs = Set(existingBindings.map(\.appBundleID))

            var migrated = 0
            for binding in legacyBindings {
                guard !existingIDs.contains(binding.appBundleID) else { continue }
                let copy = KeyBinding(
                    keyCode: binding.keyCode,
                    modifierFlags: binding.modifierFlags,
                    appBundleID: binding.appBundleID,
                    appName: binding.appName,
                    appPath: binding.appPath,
                    isEnabled: binding.isEnabled
                )
                targetContext.insert(copy)
                migrated += 1
            }
            if migrated > 0 { try targetContext.save() }
            logger.info("Migrated \(migrated) binding(s) from legacy store")

            removeLegacyFiles(at: legacyURL)
        } catch {
            logger.error("Legacy store migration failed: \(error)")
        }
    }

    private static func removeLegacyFiles(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            try? fm.removeItem(atPath: url.path + suffix)
        }
    }
}
