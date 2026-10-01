import AppKit
import IOKit

/// Who holds Secure Input, as far as the console session record tells.
enum SecureInputHolder: Equatable, Sendable {
    /// A running application, by its localized name.
    case application(String)
    /// The recorded process has exited, yet the system still reports Secure
    /// Input as enabled. Relaunching that app cannot release it.
    case exitedProcess
    /// No usable record, or a running process without an application name.
    case unknown
}

/// Best-effort attribution only. The public Secure Input API remains authoritative
/// for whether input is blocked; IOConsoleUsers is undocumented and may be absent.
enum SecureInputOwner {
    @MainActor
    static func currentHolder() -> SecureInputHolder {
        holder(
            pid: currentProcessID(),
            isRunning: isProcessRunning,
            applicationName: { NSRunningApplication(processIdentifier: $0)?.localizedName }
        )
    }

    static func holder(
        pid: pid_t?,
        isRunning: (pid_t) -> Bool,
        applicationName: (pid_t) -> String?
    ) -> SecureInputHolder {
        guard let pid else { return .unknown }
        guard isRunning(pid) else { return .exitedProcess }
        guard let name = applicationName(pid),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unknown
        }
        return .application(name)
    }

    private static func currentProcessID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let sessions = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }
        return processID(in: sessions, userID: getuid())
    }

    /// A process we may not signal still exists; only ESRCH proves it is gone.
    private static func isProcessRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    /// Ignore other login sessions instead of attributing their owner to this user.
    static func processID(in sessions: [[String: Any]], userID: uid_t) -> pid_t? {
        guard let session = sessions.first(where: {
            ($0["kCGSSessionOnConsoleKey"] as? Bool) == true
                && ($0["kCGSSessionUserIDKey"] as? Int) == Int(userID)
        }),
              let value = session["kCGSSessionSecureInputPID"] as? Int,
              let pid = pid_t(exactly: value),
              pid > 0 else { return nil }
        return pid
    }
}
