import Cocoa
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
    private var settingsCaptureWindow: NSWindow?
    private var clipboardWatcher: ClipboardWatcher?

    override init() {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let storeDir = appSupport.appendingPathComponent("dev.bybee.AnyDoor", isDirectory: true)
            try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            let storeURL = storeDir.appendingPathComponent("AnyDoor.store")
            let config = ModelConfiguration(url: storeURL)
            modelContainer = try ModelContainer(
                for: KeyBinding.self, BuiltinPreference.self, ClipboardHistoryItem.self,
                configurations: config
            )

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

        // Run migrations / seeding on the main context
        let context = modelContainer.mainContext
        KeyBindingOrderBackfill.runIfNeeded(in: context)
        BuiltinPreferenceSeeder.seedIfNeeded(in: context)

        // Bootstrap clipboard history store so providers can record entries.
        ClipboardHistoryStore.shared.bootstrap(modelContainer: modelContainer)
        ClipboardHistoryStore.shared.setMaxAge(ClipboardPreferences.retention.maxAge)
        Task { await ClipboardHistoryStore.shared.pruneExpiredAndOverflow(force: true) }

        // Start the clipboard watcher and hand it to the wall controller so the
        // controller can suppress its own write-backs from being re-recorded.
        let watcher = ClipboardWatcher(store: ClipboardHistoryStore.shared)
        watcher.start()
        clipboardWatcher = watcher
        ClipboardWatcher.shared = watcher
        ClipboardWallWindowController.shared.watcher = watcher

        // Register providers
        let providers: [any BuiltinProvider] = [
            KeepAwakeProvider(onChange: { state in
                PanelStore.shared.onKeepAwakeStateChange(state)
            }),
            HideDesktopIconsProvider(),
            ShowHiddenFilesProvider(),
            MuteAudioProvider(),
            DarkModeProvider(),
            LockScreenProvider(),
            EmptyTrashProvider(),
            ScreenshotProvider(),
            DisplaySleepProvider(),
            SystemSleepProvider(),
            HideDockProvider(),
            AutoHideMenuBarProvider(),
            RestartFinderProvider(),
            RestartDockProvider(),
            RestartMenuBarProvider(),
            FlushDNSProvider(),
            KeyboardLockProvider(),
            OCRProvider(),
            QRCodeProvider(),
            PickColorProvider(),
            WindowLayoutProvider(item: .windowLeftHalf, action: .leftHalf),
            WindowLayoutProvider(item: .windowRightHalf, action: .rightHalf),
            WindowLayoutProvider(item: .windowMaximize, action: .maximize),
            WindowLayoutProvider(item: .windowCenter, action: .center),
            ClipboardWallProvider(),
        ]
        PanelStore.shared.bootstrap(modelContainer: modelContainer, providers: providers)

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

        // Wire HotkeyService dispatcher
        HotkeyService.shared.setDispatcher { action in
            PanelStore.shared.dispatch(action)
        }

        HotkeyService.shared.setQuickPressDispatcher { @MainActor action in
            QuickPressEmitter.emit(action, trigger: HyperKeyService.shared.trigger)
        }

        if !HotkeyService.hasAccessibilityPermission {
            HotkeyService.requestAccessibilityPermission()
        }

        HotkeyService.shared.start()
        PanelStore.shared.rebuildHotkeySnapshots()

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
            MainActor.assumeIsolated { menuBar?.syncFromPreferences() }
        }
        bootstrapUpdater()
        installSettingsOpenerCapture()
    }

    /// Mount an off-screen SwiftUI view that resolves `\.openSettings` and
    /// stores the action closure into `SettingsOpener.shared`, so AppKit code
    /// (status item right-click menu) can open the Settings window through the
    /// same path SwiftUI uses internally.
    @MainActor
    private func installSettingsOpenerCapture() {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: SettingsOpenerCaptureView())
        window.orderFrontRegardless()
        settingsCaptureWindow = window
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
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        return true
    }

    /// Hot-reload entry point used by views after data changes.
    @MainActor
    func refreshBindings() {
        PanelStore.shared.rebuild()
        PanelStore.shared.rebuildHotkeySnapshots()
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
