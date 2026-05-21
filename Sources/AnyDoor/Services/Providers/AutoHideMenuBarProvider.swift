import Foundation

/// Toggles `_HIHideMenuBar` in NSGlobalDomain. When true, macOS automatically
/// hides the menu bar and reveals it on hover (the "Automatically hide and
/// show the menu bar" system preference).
///
/// Reads via `CFPreferencesCopyAppValue` against `kCFPreferencesAnyApplication`
/// (NSGlobalDomain). Writes via `/usr/bin/defaults` (CFPreferencesSetAppValue
/// cannot write across the cfprefsd domain boundary). After write,
/// `killall -HUP SystemUIServer` restarts the menu bar service to apply.
///
/// Note: on macOS Tahoe/26 the menu-bar appearance UI lives in Control Center /
/// System Settings, but the underlying `_HIHideMenuBar` default still drives
/// auto-hide behavior.
actor AutoHideMenuBarProvider: ToggleProvider {
    let itemKey: BuiltinItem = .autoHideMenuBar
    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        let raw = CFPreferencesCopyAppValue("_HIHideMenuBar" as CFString,
                                             kCFPreferencesAnyApplication)
        // Default false → menu bar always shown.
        return (raw as? Bool) ?? false
    }

    func setState(_ autoHide: Bool) async throws {
        _ = try await ShellRunner.run(
            "/usr/bin/defaults",
            args: ["write", "NSGlobalDomain", "_HIHideMenuBar", "-bool",
                   autoHide ? "true" : "false"]
        )
        _ = try? await ShellRunner.run("/usr/bin/killall", args: ["-HUP", "SystemUIServer"])
        // SystemUIServer restart failure is non-fatal: the default is already written.
    }
}
