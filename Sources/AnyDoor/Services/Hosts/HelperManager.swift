import AppIdentity
import Foundation
import ServiceManagement
import OSLog
import PluginInterface

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

    private let recovery: PrivilegedHelperRecovery

    private init() {
        recovery = PrivilegedHelperRecovery(
            validateVersion: { try await PrivilegedHelperCall.validateVersion() },
            unregister: {
                let service = SMAppService.daemon(plistName: HelperManager.plistName)
                guard service.status == .enabled else {
                    throw PrivilegedHelperCallError(message: "helper_outdated")
                }
                try await service.unregister()
            },
            register: {
                let service = SMAppService.daemon(plistName: HelperManager.plistName)
                guard service.status != .requiresApproval else {
                    throw PrivilegedHelperCallError(message: "helper_approval_required")
                }
                do {
                    try service.register()
                } catch {
                    let serviceError = error as NSError
                    if serviceError.domain == "SMAppServiceErrorDomain",
                       serviceError.code == kSMErrorAlreadyRegistered, service.status == .enabled {
                        return
                    }
                    if service.status == .requiresApproval {
                        throw PrivilegedHelperCallError(message: "helper_approval_required")
                    }
                    throw error
                }
                guard service.status == .enabled else {
                    throw PrivilegedHelperCallError(message: "helper_approval_required")
                }
            }
        )
    }

    func recoverOutdatedHelper() async throws {
        guard AppIdentity.current == .production else {
            throw PrivilegedHelperCallError(message: "the production helper is unavailable to AnyDoor Dev")
        }
        do {
            try await recovery.recover()
        } catch {
            logger.error("Helper recovery failed: \(error)")
            throw error
        }
    }

    func waitForRecovery() async throws {
        try await recovery.waitForRecovery()
    }

    /// Keeps writes on the helper path when enabled or being replaced.
    /// False routes to the AppleScript fallback.
    func ensureRegistered() -> Bool {
        guard AppIdentity.current == .production else { return false }
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
        guard AppIdentity.current == .production else { return .unavailable }
        // Keep new writes on the helper path while its registration is briefly
        // absent. They must join recovery, not start an AppleScript fallback.
        if recovery.isRecovering { return .enabled }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound:
            // A failed replacement is still owned by the helper path, so the
            // next write repairs registration rather than silently falling back.
            return recovery.needsRegistration ? .enabled : .unavailable
        @unknown default: return .unavailable
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Unregister the daemon (Hosts uninstall, once no other consumer needs
    /// it — see `PrivilegedHelperRelease`). No-op when it isn't registered.
    func unregister() throws {
        guard AppIdentity.current == .production else { return }
        guard !recovery.isRecovering else {
            throw PrivilegedHelperCallError(message: "helper update in progress")
        }
        switch service.status {
        case .notRegistered, .notFound:
            break
        default:
            try service.unregister()
        }
        recovery.registrationWasRemoved()
    }
}

/// Decides whether the shared privileged helper daemon may be unregistered
/// (amended ADR-0005): the daemon serves both Hosts and forced Scheduled
/// Shutdown, so releasing it is allowed only while no other consumer needs
/// it. Closure-injected so the policy tests without SMAppService.
@MainActor
struct PrivilegedHelperRelease {
    /// True while a Core consumer other than the caller still needs the
    /// daemon (forced Scheduled Shutdown today).
    var otherConsumersActive: () -> Bool
    var unregister: () throws -> Void

    func releaseIfUnneeded() throws {
        guard !otherConsumersActive() else { return }
        try unregister()
    }
}
