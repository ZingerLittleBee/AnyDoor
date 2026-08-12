import Foundation
import PluginInterface

/// Toggles clipboard-history monitoring through the same UserDefaults key used
/// by Settings, so the panel row and settings switch stay in sync.
@MainActor
final class ClipboardMonitoringProvider: ToggleProvider {
    let itemKey: BuiltinItem = .clipboardMonitoring
    var permission: PermissionStatus { .notRequired }

    private let defaults: UserDefaults
    private let lifecycle: ClipboardHistoryLifecycle?

    init(
        defaults: UserDefaults = .standard,
        lifecycle: ClipboardHistoryLifecycle? = nil
    ) {
        self.defaults = defaults
        self.lifecycle = lifecycle
    }

    func readState() async throws -> Bool {
        ClipboardPreferences.monitoringEnabled(from: defaults)
    }

    func setState(_ enabled: Bool) async throws {
        if let lifecycle {
            await lifecycle.setMonitoringEnabled(enabled)
        } else {
            ClipboardPreferences.setMonitoringEnabled(enabled, in: defaults)
        }
    }
}
