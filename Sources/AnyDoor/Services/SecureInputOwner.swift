import AppKit
import IOKit

/// Best-effort attribution only. The public Secure Input API remains authoritative
/// for whether input is blocked; IOConsoleUsers is undocumented and may be absent.
enum SecureInputOwner {
    @MainActor
    static func currentApplicationName() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let sessions = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]],
              let pid = processID(in: sessions, userID: getuid()),
              let name = NSRunningApplication(processIdentifier: pid)?.localizedName,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return name
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
