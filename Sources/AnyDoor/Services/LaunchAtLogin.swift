import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the launch-at-login toggle.
///
/// Only meaningful when AnyDoor runs as an installed `.app` bundle. Under
/// `swift run` the process has no bundle, so `isSupported` is false and the
/// settings toggle stays disabled.
enum LaunchAtLogin {
    /// True only when the host process is a real `.app` bundle.
    static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
