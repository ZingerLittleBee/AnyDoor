import Foundation
import PluginInterface

/// Restart Finder by killing the process; launchd / the system relaunches it automatically.
///
/// Useful when Finder hangs, fails to refresh, or after toggling hidden-file visibility.
actor RestartFinderProvider: ActionProvider {
    let itemKey: BuiltinItem = .restartFinder
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        _ = try await ShellRunner.run("/usr/bin/killall", args: ["Finder"])
    }
}
