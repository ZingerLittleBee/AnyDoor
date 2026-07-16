import Foundation
import PluginInterface

/// Put the display(s) to sleep immediately via `/usr/bin/pmset displaysleepnow`.
///
/// Unlike `LockScreenProvider`, this does not lock the session — the screen
/// simply powers down and any keypress or mouse movement wakes it without
/// requiring authentication (unless the user has separately configured a
/// password-on-wake policy in System Settings).
actor DisplaySleepProvider: ActionProvider {
    let itemKey: BuiltinItem = .displaySleep
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        _ = try await ShellRunner.run(
            "/usr/bin/pmset",
            args: ["displaysleepnow"]
        )
    }
}
