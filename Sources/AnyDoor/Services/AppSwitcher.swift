import AppKit

@MainActor
enum AppSwitcher {
    static func toggle(bundleID: String, appPath: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            if app.isActive {
                app.hide()
            } else {
                // Route activation through Launch Services rather than
                // NSRunningApplication.activate(). The latter is silently
                // ignored on macOS 14+ when called from an .accessory app
                // while another regular app holds keyboard focus (observed
                // with Warp, also reported for Ghostty / iTerm). openApplication
                // is itself a privileged Launch Services call and is allowed
                // to steal focus on behalf of the user.
                activate(at: launchURL(bundleID: bundleID, recordedPath: appPath))
            }
        } else {
            activate(at: launchURL(bundleID: bundleID, recordedPath: appPath))
        }
    }

    /// The recorded bundle, or Launch Services' copy of the app when the
    /// recorded path is gone (the app was reinstalled under a new name, or the
    /// binding was imported before the app existed on this Mac).
    private static func launchURL(bundleID: String, recordedPath: String) -> URL {
        if !recordedPath.isEmpty, FileManager.default.fileExists(atPath: recordedPath) {
            return URL(fileURLWithPath: recordedPath)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            ?? URL(fileURLWithPath: recordedPath)
    }

    private static func activate(at url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }
}
