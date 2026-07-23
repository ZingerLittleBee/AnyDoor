import Foundation
import PluginInterface

/// Toggles macOS "Automatically hide and show the menu bar".
///
/// Two defaults must be kept in sync:
/// - `_HIHideMenuBar` (NSGlobalDomain) drives the actual behavior — WindowServer
///   reads it to decide whether to auto-hide the menu bar on the desktop.
/// - `AutoHideMenuBarOption` (com.apple.controlcenter) is the persistent source
///   of truth behind the four-way picker in System Settings (0 = Always,
///   1 = On Desktop Only, 2 = In Full Screen Only (default), 3 = Never). When the
///   Dock restarts it re-derives `_HIHideMenuBar` from this value, so writing
///   `_HIHideMenuBar` alone gets silently reverted.
///
/// Writing the defaults never applies live on its own. WindowServer only
/// re-reads after the `AppleInterfaceMenuBarHidingChangedNotification`
/// distributed notification is posted — this is what System Settings posts, and
/// the only reliable trigger (restarting SystemUIServer / Dock does nothing).
actor AutoHideMenuBarProvider: ToggleProvider {
    let itemKey: BuiltinItem = .autoHideMenuBar
    var permission: PermissionStatus { .notRequired }

    // AutoHideMenuBarOption values for the toggle's on/off states.
    private static let optionAlways = 0          // auto-hide on desktop and full screen
    private static let optionFullScreenOnly = 2  // macOS default — visible on desktop

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
        _ = try await ShellRunner.run(
            "/usr/bin/defaults",
            args: ["write", "com.apple.controlcenter", "AutoHideMenuBarOption", "-int",
                   String(autoHide ? Self.optionAlways : Self.optionFullScreenOnly)]
        )
        // Live-apply trigger: WindowServer re-reads the prefs on this notification.
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("AppleInterfaceMenuBarHidingChangedNotification"),
            object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}
