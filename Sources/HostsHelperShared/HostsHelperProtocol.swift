import Foundation

/// Shared identifiers and the XPC contract between the AnyDoor app and the
/// privileged helper. Kept free of hosts-file parsing logic on purpose.
public enum HostsHelperConstants {
    /// Mach service name vended by the LaunchDaemon and connected to by the app.
    public static let machServiceName = "dev.bybee.AnyDoor.HostsHelper"
    /// Upper bound on a single write payload (bytes) to bound helper memory.
    public static let maxPayloadBytes = 1_048_576  // 1 MiB
}

/// XPC interface implemented by the root helper.
@objc public protocol HostsHelperProtocol {
    /// Replace `/etc/hosts` with `content`. Replies with nil on success or an
    /// error message describing the failure.
    func writeHosts(_ content: String, withReply reply: @escaping (String?) -> Void)
    /// Returns the helper's bundle/build version for diagnostics + upgrade checks.
    func helperVersion(withReply reply: @escaping (String) -> Void)
}
