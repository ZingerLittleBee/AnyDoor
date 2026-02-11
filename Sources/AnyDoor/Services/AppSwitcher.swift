import AppKit

@MainActor
enum AppSwitcher {
    static func toggle(bundleID: String, appPath: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            if app.isActive {
                app.hide()
            } else {
                app.activate()
            }
        } else {
            let url = URL(fileURLWithPath: appPath)
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in }
        }
    }
}
