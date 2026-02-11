import Cocoa
import SwiftData

final class AppDelegate: NSObject, NSApplicationDelegate {
    let modelContainer: ModelContainer

    override init() {
        do {
            modelContainer = try ModelContainer(for: KeyBinding.self)
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
