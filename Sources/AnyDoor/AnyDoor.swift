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
        // System Settings-style chrome: no title-bar strip — the sidebar's
        // glass card spans the window's full height and the traffic lights sit
        // on top of it. Setting the AppKit flags directly on the NSWindow does
        // NOT achieve this: SwiftUI still reserves the title-bar safe area and
        // lays the split view out below it. Only the scene-level window style
        // makes SwiftUI extend the layout into the title-bar region.
        .windowStyle(.hiddenTitleBar)
    }
}
