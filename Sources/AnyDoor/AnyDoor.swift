import SwiftUI
import SwiftData

@main
struct AnyDoorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The menu bar item is owned by `MenuBarController` (see AppDelegate),
        // not a SwiftUI `MenuBarExtra`. The Settings window is owned by
        // `SettingsWindowController` (a manually managed NSWindow, the same
        // window type as the Image Conversion workspace), NOT this scene.
        //
        // This stub only exists because a SwiftUI `App` must declare at least
        // one scene, and every alternative misbehaves for a menu-bar utility:
        // `WindowGroup` opens a window at launch, and `MenuBarExtra` with
        // `isInserted: false` infinite-loops the scene graph on macOS 26. The
        // stub is unreachable — the standard "Settings…" menu item (the only
        // thing that could open it) is replaced below to route to the real
        // window controller.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L(.panelFooterSettings)) {
                    SettingsOpener.shared.tryOpen()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
