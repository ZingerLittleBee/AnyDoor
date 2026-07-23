import Foundation

/// Approval state of the host's privileged helper daemon, mirrored for
/// plugin consumption.
public enum PrivilegedHelperReadiness: Sendable {
    /// Registered and approved: privileged calls go through the daemon.
    case enabled
    /// Registered but awaiting the user's approval in System Settings.
    case requiresApproval
    /// Not registered (ad-hoc/dev build, or registration failed).
    case unavailable
}

/// Error carried out of a failed privileged-helper call (the daemon replied
/// with a failure, the connection dropped, or the call timed out).
public struct PrivilegedHelperCallError: Error, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// Plugin-facing view of the host's shared privileged helper daemon.
///
/// The daemon is Core infrastructure (amended ADR-0005): Hosts writes
/// `/etc/hosts` through it and forced Scheduled Shutdown shuts down through
/// it, so its lifecycle — registration, approval, unregistration — stays with
/// the Core. Plugins consume its fixed verbs through this capability and may
/// ask for its release, but the Core decides whether another consumer still
/// needs the daemon.
@MainActor
public protocol PrivilegedHelperAccess: AnyObject {

    /// Current approval state; UI (writer selection, approval banners) keys
    /// on it per render so approval takes effect without a relaunch.
    func readiness() -> PrivilegedHelperReadiness

    /// Attempt registration once (cheap when already registered). Returns
    /// true only when the daemon ends up enabled.
    func ensureRegistered() -> Bool

    /// Opens System Settings → Login Items for the pending approval.
    func openApprovalSettings()

    /// Writes the full `/etc/hosts` content through the root daemon.
    /// Throws `PrivilegedHelperCallError` on failure. Implementations must
    /// run the XPC round-trip off the MainActor (awaiting a nonisolated
    /// call), never blocking it.
    func writeHostsFile(_ content: String) async throws

    /// Unregisters the daemon unless another Core consumer still needs it
    /// (forced Scheduled Shutdown today) — the shared-daemon rule from the
    /// amended ADR-0005. Throws when an attempted unregistration fails.
    func releaseIfUnneeded() throws
}
