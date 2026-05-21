import Foundation

/// Toggles `com.apple.dock.autohide`. autohide=true hides the Dock (auto-hide mode).
///
/// Reads via `CFPreferencesCopyAppValue` (works without sandbox restrictions).
/// Writes via `/usr/bin/defaults` (CFPreferencesSetAppValue cannot write across the
/// cfprefsd domain boundary). After write, `killall Dock` to apply.
actor HideDockProvider: ToggleProvider {
    let itemKey: BuiltinItem = .hideDock
    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        let raw = CFPreferencesCopyAppValue("autohide" as CFString,
                                             "com.apple.dock" as CFString)
        // autohide default is false → Dock visible. Hidden = autohide true.
        let autohide = (raw as? Bool) ?? false
        return autohide
    }

    func setState(_ hidden: Bool) async throws {
        _ = try await ShellRunner.run(
            "/usr/bin/defaults",
            args: ["write", "com.apple.dock", "autohide", "-bool",
                   hidden ? "true" : "false"]
        )
        _ = try? await ShellRunner.run("/usr/bin/killall", args: ["Dock"])
        // killall failure is non-fatal: defaults already wrote, next Dock restart picks it up
    }
}
