import Cocoa
import SwiftData
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "persistence")

final class AppDelegate: NSObject, NSApplicationDelegate {
    let modelContainer: ModelContainer

    override init() {
        do {
            // Use a fixed storage path so data persists regardless of how the app is launched
            // (swift run vs .app bundle). Without this, the default ModelConfiguration
            // picks a path based on the process bundle ID, which differs between run modes.
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let storeDir = appSupport.appendingPathComponent("dev.bybee.AnyDoor", isDirectory: true)
            try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            let storeURL = storeDir.appendingPathComponent("AnyDoor.store")
            let config = ModelConfiguration(url: storeURL)
            modelContainer = try ModelContainer(for: KeyBinding.self, configurations: config)

            // Migrate bindings from the legacy default store (used before the fixed-path fix)
            // into the canonical store so previously saved data is not lost.
            let legacyURL = appSupport.appendingPathComponent("default.store")
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                Self.migrateLegacyStore(from: legacyURL, into: modelContainer)
            }
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        if !HotkeyService.hasAccessibilityPermission {
            HotkeyService.requestAccessibilityPermission()
        }

        HotkeyService.shared.start()
        refreshBindings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyService.shared.stop()
    }

    @MainActor
    func refreshBindings() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<KeyBinding>()
        if let bindings = try? context.fetch(descriptor) {
            HotkeyService.shared.updateBindings(bindings)
        }
    }

    // MARK: - Legacy Store Migration

    /// One-time migration: copy bindings from the old default.store into the fixed-path store,
    /// then delete the legacy files so migration won't run again.
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
                // Skip duplicates (same target app already exists)
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

            if migrated > 0 {
                try targetContext.save()
            }
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
