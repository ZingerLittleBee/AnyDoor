import Cocoa
import SwiftData
import OSLog
import AskForPermission

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "persistence")

final class AppDelegate: NSObject, NSApplicationDelegate {
    let modelContainer: ModelContainer

    override init() {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let storeDir = appSupport.appendingPathComponent("dev.bybee.AnyDoor", isDirectory: true)
            try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            let storeURL = storeDir.appendingPathComponent("AnyDoor.store")
            let config = ModelConfiguration(url: storeURL)
            modelContainer = try ModelContainer(
                for: KeyBinding.self, BuiltinPreference.self,
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

        // Register providers
        let providers: [any BuiltinProvider] = [
            KeepAwakeProvider(),
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
            PickColorProvider(),
        ]
        PanelStore.shared.bootstrap(modelContainer: modelContainer, providers: providers)

        // Wire HotkeyService dispatcher
        HotkeyService.shared.setDispatcher { action in
            PanelStore.shared.dispatch(action)
        }

        if !HotkeyService.hasAccessibilityPermission {
            HotkeyService.requestAccessibilityPermission()
        }

        HotkeyService.shared.start()
        PanelStore.shared.rebuildHotkeySnapshots()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyService.shared.stop()
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
