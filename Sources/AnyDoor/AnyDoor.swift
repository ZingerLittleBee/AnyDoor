import SwiftUI
import SwiftData

@main
struct AnyDoorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The menu bar item is owned by `MenuBarController` (see AppDelegate),
        // not a SwiftUI `MenuBarExtra`. Only the Settings scene lives here.
        Settings {
            SettingsView()
                .modelContainer(appDelegate.modelContainer)
        }
    }
}
