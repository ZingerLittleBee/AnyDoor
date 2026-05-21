import Foundation

/// Toggles `com.apple.finder.CreateDesktop`. CreateDesktop=false hides desktop icons.
///
/// Reads via `CFPreferencesCopyAppValue` (works without sandbox restrictions).
/// Writes via `/usr/bin/defaults` (CFPreferencesSetAppValue cannot write across the
/// cfprefsd domain boundary). After write, `killall Finder` to apply.
actor HideDesktopIconsProvider: ToggleProvider {
    let itemKey: BuiltinItem = .hideDesktopIcons
    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        let raw = CFPreferencesCopyAppValue("CreateDesktop" as CFString,
                                             "com.apple.finder" as CFString)
        // CreateDesktop default is true → desktop icons SHOWN. Hidden = CreateDesktop false.
        let createDesktop = (raw as? Bool) ?? true
        return !createDesktop
    }

    func setState(_ hidden: Bool) async throws {
        let createDesktop = !hidden
        _ = try await ShellRunner.run(
            "/usr/bin/defaults",
            args: ["write", "com.apple.finder", "CreateDesktop", "-bool",
                   createDesktop ? "true" : "false"]
        )
        _ = try? await ShellRunner.run("/usr/bin/killall", args: ["Finder"])
        // killall failure is non-fatal: defaults already wrote, next Finder restart picks it up
    }
}
