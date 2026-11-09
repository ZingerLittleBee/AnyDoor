import Foundation
import PluginInterface

enum HostsWriterError: Error, Equatable {
    case writeFailed(String)
    case liveChanged
    case helperOutdated
    case helperApprovalRequired
}

/// Abstraction over the privileged write to `/etc/hosts`. Implementations:
/// `PrivilegedHostsWriter` (production, via the Core's helper daemon),
/// `AppleScriptWriter` (dev fallback).
protocol HostsWriter: Sendable {
    /// Check the baseline at the privileged boundary, after any authorization.
    func write(_ content: String, replacing expectedContent: String) async throws
}

/// Production writer: sends the composed hosts content to the Core's root
/// helper daemon through the host services (the XPC plumbing stays Core
/// infrastructure — amended ADR-0005).
struct PrivilegedHostsWriter: HostsWriter {
    let host: PluginHostContext

    func write(_ content: String, replacing expectedContent: String) async throws {
        do {
            try await host.writeHostsFileViaHelper(content, replacing: expectedContent)
        } catch let error as PrivilegedHelperCallError {
            if error.message == "hosts_changed" { throw HostsWriterError.liveChanged }
            if error.message == "helper_outdated" { throw HostsWriterError.helperOutdated }
            if error.message == "helper_approval_required" { throw HostsWriterError.helperApprovalRequired }
            throw HostsWriterError.writeFailed(error.message)
        }
    }
}

/// Dev / ad-hoc fallback. Writes to an unpredictable temp file then copies it
/// over `/etc/hosts` with an administrator-authorized shell command. Never
/// changes the permissions of `/etc/hosts`.
struct AppleScriptWriter: HostsWriter {
    let host: PluginHostContext

    func write(_ content: String, replacing expectedContent: String) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydoor-hosts-\(UUID().uuidString)")
        let baseline = tmp.appendingPathExtension("baseline")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: baseline)
        }
        try Data(content.utf8).write(to: tmp)
        try Data(expectedContent.utf8).write(to: baseline)
        // This comparison runs AFTER the authorization dialog, not before it.
        // A changed or unreadable file fails closed without copying anything.
        let script = """
        do shell script "if /usr/bin/cmp -s " & quoted form of "\(baseline.path)" & " /etc/hosts; then /bin/cp " & quoted form of "\(tmp.path)" & " /etc/hosts; else /bin/echo hosts_changed; fi" with administrator privileges
        """
        do {
            let result = try await host.runAppleScript(script)
            if result.trimmingCharacters(in: .whitespacesAndNewlines) == "hosts_changed" {
                throw HostsWriterError.liveChanged
            }
        } catch let error as HostsWriterError {
            throw error
        } catch {
            throw HostsWriterError.writeFailed(String(describing: error))
        }
    }
}
