import Foundation

enum HostsWriterError: Error, Equatable {
    case writeFailed(String)
    case authorizationCancelled
}

/// Abstraction over the privileged write to `/etc/hosts`. Implementations:
/// `PrivilegedHelperWriter` (production, XPC), `AppleScriptWriter` (dev fallback).
protocol HostsWriter: Sendable {
    func write(_ content: String) async throws
}

/// Dev / ad-hoc fallback. Writes to an unpredictable temp file then copies it
/// over `/etc/hosts` with an administrator-authorized shell command. Never
/// changes the permissions of `/etc/hosts`.
struct AppleScriptWriter: HostsWriter {
    func write(_ content: String) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydoor-hosts-\(UUID().uuidString)")
        try content.data(using: .utf8)?.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Quote both paths; embed via AppleScript "quoted form of".
        let script = """
        do shell script "/bin/cp " & quoted form of "\(tmp.path)" & " /etc/hosts" with administrator privileges
        """
        do {
            _ = try await AppleScriptRunner.run(script)
        } catch {
            throw HostsWriterError.writeFailed(String(describing: error))
        }
    }
}
