import Cocoa
import SwiftData

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
}
