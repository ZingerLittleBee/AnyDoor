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
                activate(at: URL(fileURLWithPath: appPath))
            }
        } else {
            activate(at: URL(fileURLWithPath: appPath))
        }
    }

    private static func activate(at url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }
}
