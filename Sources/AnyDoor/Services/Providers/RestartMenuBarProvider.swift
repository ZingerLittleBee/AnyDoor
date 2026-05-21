import Foundation

/// Restart SystemUIServer, which owns the menu bar status items; it relaunches automatically.
///
/// Useful when third-party menu bar items get stuck, duplicated, or fail to redraw.
actor RestartMenuBarProvider: ActionProvider {
    let itemKey: BuiltinItem = .restartMenuBar
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        _ = try await ShellRunner.run("/usr/bin/killall", args: ["SystemUIServer"])
    }
}
