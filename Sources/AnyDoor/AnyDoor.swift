import SwiftUI
import SwiftData

@main
struct AnyDoorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("AnyDoor", systemImage: "door.left.hand.open") {
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
