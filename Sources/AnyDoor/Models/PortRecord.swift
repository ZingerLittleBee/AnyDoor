import Foundation
import Darwin

/// Listening TCP port discovered on the local machine. Identity is `(pid, port)`.
struct PortRecord: Sendable, Hashable, Identifiable {
    let port: UInt16
    let pid: pid_t
    let processName: String
    let executablePath: String?
    let commandLine: String?
    /// Every distinct bind seen for this (pid, port). Never empty; ordered IPv4 first then IPv6.
    let binds: [PortBind]
    var id: String { "\(pid)-\(port)" }
}

struct PortBind: Sendable, Hashable {
    let address: String          // "*", "127.0.0.1", "::1", "fe80::1%en0", ...
    let family: AddressFamily
}

enum AddressFamily: String, Sendable, Hashable, CaseIterable {
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"
}

/// Outcome of a `Darwin.kill(2)` syscall. `errno` is captured immediately into
/// the failure case to avoid clobbering by subsequent system calls.
enum SignalResult: Sendable, Equatable {
    case success
    case failure(POSIXErrorCode)
}

/// View-model grouping of records belonging to a single process. Used by the tree view.
struct ProcessGroup: Sendable, Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let processName: String
    let ports: [PortRecord]      // sorted by port ascending
}
