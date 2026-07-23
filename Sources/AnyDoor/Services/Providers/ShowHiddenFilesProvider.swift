import Foundation
import PluginInterface

/// Toggles `com.apple.finder.AppleShowAllFiles`. true = show hidden files.
///
/// Read: CFPreferencesCopyAppValue. Write: /usr/bin/defaults + killall Finder.
actor ShowHiddenFilesProvider: ToggleProvider {
    let itemKey: BuiltinItem = .showHiddenFiles
    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        let raw = CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString,
                                             "com.apple.finder" as CFString)
        return (raw as? Bool) ?? false
    }

    func setState(_ show: Bool) async throws {
        _ = try await ShellRunner.run(
            "/usr/bin/defaults",
            args: ["write", "com.apple.finder", "AppleShowAllFiles", "-bool",
                   show ? "true" : "false"]
        )
        _ = try? await ShellRunner.run("/usr/bin/killall", args: ["Finder"])
    }
}
