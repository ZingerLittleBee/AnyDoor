import Foundation
import PluginInterface

/// Restart the menu bar by killing both SystemUIServer and ControlCenter; launchd relaunches them.
///
/// SystemUIServer owns legacy status items (third-party menu extras).
/// ControlCenter owns the modern right-side cluster (Wi-Fi, Bluetooth, Sound,
/// Focus, Battery, Clock) and on recent macOS most of the visible menu bar
/// lives there — killing only SystemUIServer has almost no visible effect.
/// Both fail-soft via try? so a missing target doesn't abort the other.
actor RestartMenuBarProvider: ActionProvider {
    let itemKey: BuiltinItem = .restartMenuBar
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        _ = try? await ShellRunner.run("/usr/bin/killall", args: ["SystemUIServer"])
        _ = try? await ShellRunner.run("/usr/bin/killall", args: ["ControlCenter"])
    }
}
