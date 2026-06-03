import Foundation
import ServiceManagement
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "hosts.helper")

/// Manages the privileged LaunchDaemon lifecycle via SMAppService.
@MainActor
final class HelperManager {
    static let shared = HelperManager()

    static let plistName = "dev.bybee.AnyDoor.HostsHelper.plist"

    enum Readiness {
        case enabled
        case requiresApproval
        case unavailable   // ad-hoc/dev build, or registration failed
    }

    private var service: SMAppService { SMAppService.daemon(plistName: Self.plistName) }

    /// True only when the daemon is registered and enabled. Used to pick the
    /// production writer; false routes to the AppleScript fallback.
    func ensureRegistered() -> Bool {
        switch readiness() {
        case .enabled:
            return true
        case .requiresApproval:
            return false
        case .unavailable:
            do {
                try service.register()
                return service.status == .enabled
            } catch {
                logger.error("Helper register failed: \(error)")
                return false
            }
        }
    }

    func readiness() -> Readiness {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .unavailable
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
