import Foundation
import PluginInterface

/// Thin `ToggleProvider` adapter over `ScheduledShutdownService` (the MainActor
/// brain, which owns all state and the on/off policy). The panel row and global
/// hotkey don't route through it: `PanelStore.toggle` special-cases this item
/// and calls `ScheduledShutdownService.setArmed` itself, keeping the read and
/// the write in one MainActor turn.
actor ScheduledShutdownProvider: ToggleProvider {
    let itemKey: BuiltinItem = .scheduledShutdown
    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        await MainActor.run { ScheduledShutdownService.shared.state.isArmed }
    }

    func setState(_ enabled: Bool) async throws {
        await MainActor.run { ScheduledShutdownService.shared.setArmed(enabled) }
    }
}
