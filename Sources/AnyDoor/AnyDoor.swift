import SwiftUI

@main
@MainActor
enum AnyDoorMain {
    static func main() {
        if #available(macOS 15, *) {
            AnyDoorApp.main()
        } else {
            LegacyAnyDoorApp.main()
        }
    }
}

@available(macOS 15, *)
private struct AnyDoorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        AnyDoorSettingsScene()
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
    }
}

// SceneBuilder cannot branch with an availability-check else clause. Keep the
// macOS 14 entry point separate because scene launch control requires macOS 15.
private struct LegacyAnyDoorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        AnyDoorSettingsScene()
    }
}

private struct AnyDoorSettingsScene: Scene {
    var body: some Scene {
        // SwiftUI requires a scene, but AppKit owns every real window and the
        // status item. An empty Settings scene can still be auto-presented by
        // SwiftUI, so the modern entry point opts out at the scene level.
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
