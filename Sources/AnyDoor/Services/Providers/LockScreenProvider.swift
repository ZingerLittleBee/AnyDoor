import Foundation

/// Lock the screen via `CGSession -suspend`.
///
/// We deliberately avoid the private `SACLockScreenImmediate()` symbol: it would require
/// dlsym into login.framework which is a private framework, subject to App Store rejection
/// and version drift. The CGSession binary path is a stable public location.
actor LockScreenProvider: ActionProvider {
    let itemKey: BuiltinItem = .lockScreen
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        _ = try await ShellRunner.run(
            "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
            args: ["-suspend"]
        )
    }
}
