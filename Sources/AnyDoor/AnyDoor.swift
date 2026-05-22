import SwiftUI
import SwiftData

@main
struct AnyDoorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @AppStorage(MenuBarIcon.visibilityKey) private var iconVisible = true
    @AppStorage(MenuBarIcon.nameKey) private var iconName = MenuBarIcon.defaultName

    var body: some Scene {
        MenuBarExtra("AnyDoor", systemImage: iconName, isInserted: $iconVisible) {
            MenuBarView()
                .modelContainer(appDelegate.modelContainer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .modelContainer(appDelegate.modelContainer)
        }
    }
}
