import Foundation
import PluginInterface

/// Thin adapter so the panel row + global hotkey route through the standard
/// PanelStore toggle machinery. All real state lives in
/// `ScheduledShutdownService` (the MainActor brain); this provider just bridges.
actor ScheduledShutdownProvider: ToggleProvider {
    let itemKey: BuiltinItem = .scheduledShutdown
    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        await MainActor.run { ScheduledShutdownService.shared.state.isArmed }
    }

    func setState(_ enabled: Bool) async throws {
        await MainActor.run {
            if enabled {
                ScheduledShutdownService.shared.arm(
                    .minutes(ScheduledShutdownService.shared.defaultMinutes)
                )
            } else {
                ScheduledShutdownService.shared.cancel()
            }
        }
    }
}
