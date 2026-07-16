import Foundation
import PluginInterface

enum HostsWriterError: Error, Equatable {
    case writeFailed(String)
}

/// Abstraction over the privileged write to `/etc/hosts`. Implementations:
/// `PrivilegedHostsWriter` (production, via the Core's helper daemon),
/// `AppleScriptWriter` (dev fallback).
protocol HostsWriter: Sendable {
    func write(_ content: String) async throws
}

/// Production writer: sends the composed hosts content to the Core's root
/// helper daemon through the host services (the XPC plumbing stays Core
/// infrastructure — amended ADR-0005).
struct PrivilegedHostsWriter: HostsWriter {
    func write(_ content: String) async throws {
        do {
            try await PluginHost.writeHostsFileViaHelper(content)
        } catch let error as PrivilegedHelperCallError {
            throw HostsWriterError.writeFailed(error.message)
        }
    }
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
            _ = try await PluginHost.runAppleScript(script)
        } catch {
            throw HostsWriterError.writeFailed(String(describing: error))
        }
    }
}
