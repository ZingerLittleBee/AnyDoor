import SwiftUI
import SwiftData

@main
struct AnyDoorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The menu bar item is owned by `MenuBarController` (see AppDelegate),
        // not a SwiftUI `MenuBarExtra`. Only the Settings scene lives here.
        //
        // State restoration for this window is disabled in `AppDelegate`
        // (`application(_:shouldRestoreApplicationState:)`) so macOS never
        // reopens Settings when the app auto-launches at login — it is a
        // menu-bar utility, the window should appear only on explicit request.
        Settings {
            SettingsView()
                .modelContainer(appDelegate.modelContainer)
                .environment(appDelegate.localizationManager)
                .environment(\.locale, appDelegate.localizationManager.effectiveLocale)
        }
    }
}
