import Foundation
import PluginInterface

/// Thin `ToggleProvider` adapter over `ScheduledShutdownService` (the MainActor
/// brain, which owns all state and the on/off policy). No production path calls
/// its `readState` or `setState`: `PanelStore` reads the service's state and
/// calls `ScheduledShutdownService.setArmed` itself, keeping the read and the
/// write in one MainActor turn. It stays registered so every toggle item has a
/// `ToggleProvider` (`BuiltinCatalogInvariantTests`).
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
