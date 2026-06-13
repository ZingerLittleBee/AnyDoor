import Foundation

/// Toggles clipboard-history monitoring through the same UserDefaults key used
/// by Settings, so the panel row and settings switch stay in sync.
@MainActor
final class ClipboardMonitoringProvider: ToggleProvider {
    let itemKey: BuiltinItem = .clipboardMonitoring
    var permission: PermissionStatus { .notRequired }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func readState() async throws -> Bool {
        ClipboardPreferences.monitoringEnabled(from: defaults)
    }

    func setState(_ enabled: Bool) async throws {
        ClipboardPreferences.setMonitoringEnabled(enabled, in: defaults)
    }
}
