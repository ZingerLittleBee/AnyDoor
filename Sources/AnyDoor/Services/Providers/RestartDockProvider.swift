import Foundation
import PluginInterface

/// Restart the Dock process; the system relaunches it automatically.
///
/// Useful when Dock icons go stale, Mission Control misbehaves, or hot corners stop responding.
actor RestartDockProvider: ActionProvider {
    let itemKey: BuiltinItem = .restartDock
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        _ = try await ShellRunner.run("/usr/bin/killall", args: ["Dock"])
    }
}
