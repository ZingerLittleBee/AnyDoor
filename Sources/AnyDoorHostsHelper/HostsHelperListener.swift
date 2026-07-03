import Foundation
import HostsHelperShared
import Security
import XPCAuditToken

/// XPC listener delegate running as root. Validates each caller's code
/// signature before exposing the interface, serializes writes, and replaces
/// /etc/hosts atomically.
final class HostsHelperListener: NSObject, NSXPCListenerDelegate, PrivilegedHelperProtocol, @unchecked Sendable {
    private let writeQueue = DispatchQueue(label: "dev.bybee.AnyDoor.HostsHelper.write")

    // anchor apple generic + our Team ID + our app identifier.
    // OU is the Developer ID Application Team ID (verified via
    // `codesign --verify -R` against the signed /Applications/AnyDoor.app).
    private static let clientRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"9VM4RM39R3\" and identifier \"dev.bybee.AnyDoor\""

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard isValidClient(conn) else { return false }
        conn.exportedInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        conn.exportedObject = self
        conn.resume()
        return true
    }

    private func isValidClient(_ conn: NSXPCConnection) -> Bool {
        // Audit-token guest lookup closes the PID-recycling TOCTOU window that a
        // PID-based check would leave open.
        var ok: ObjCBool = false
        var token = AnyDoorXPCPeerAuditToken(conn, &ok)
        guard ok.boolValue else { return false }
        let tokenData = Data(bytes: &token, count: MemoryLayout.size(ofValue: token))
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(Self.clientRequirement as CFString, [], &req) == errSecSuccess,
              let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    // MARK: PrivilegedHelperProtocol

    func writeHosts(_ content: String, withReply reply: @escaping @Sendable (String?) -> Void) {
        guard content.utf8.count <= PrivilegedHelperConstants.maxPayloadBytes else {
            reply("payload too large"); return
        }
        writeQueue.async {
            do {
                try Self.atomicWrite(content)
                reply(nil)
            } catch {
                reply(String(describing: error))
            }
        }
    }

    func helperVersion(withReply reply: @escaping @Sendable (String) -> Void) {
        // The helper is a bare Mach-O without an Info.plist; read the shared constant instead.
        reply(PrivilegedHelperConstants.helperVersion)
    }

    func shutDown(withReply reply: @escaping @Sendable (String?) -> Void) {
        writeQueue.async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/sbin/shutdown")
            proc.arguments = ["-h", "now"]
            do {
                try proc.run()
                // The machine is going down; reply best-effort before exit.
                reply(nil)
            } catch {
                reply(String(describing: error))
            }
        }
    }

    /// Write to a temp file in /etc (same filesystem so rename is atomic), then
    /// fsync, set root:wheel 0644, and rename over /etc/hosts.
    private static func atomicWrite(_ content: String) throws {
        let dir = "/etc"
        let template = "\(dir)/.hosts.anydoor.XXXXXX"
        var bytes = Array(template.utf8) + [0]
        let fd = bytes.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw NSError(domain: "hosts", code: Int(errno)) }
        // `bytes` is the mkstemp template with the trailing NUL we appended;
        // mkstemp rewrites it in place without changing its length.
        let tmpPath = String(decoding: bytes.dropLast(), as: UTF8.self)
        defer { unlink(tmpPath) }

        let data = Array(content.utf8)
        var written = 0
        while written < data.count {
            let n = data[written...].withUnsafeBytes { write(fd, $0.baseAddress, data.count - written) }
            if n <= 0 { close(fd); throw NSError(domain: "hosts", code: Int(errno)) }
            written += n
        }
        fsync(fd)
        fchown(fd, 0, 0)            // root:wheel
        fchmod(fd, 0o644)
        close(fd)
        guard rename(tmpPath, "\(dir)/hosts") == 0 else {
            throw NSError(domain: "hosts", code: Int(errno))
        }
    }
}
