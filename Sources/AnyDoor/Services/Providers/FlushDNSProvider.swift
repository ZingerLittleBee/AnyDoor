import Foundation
import PluginInterface

/// Flush the macOS DNS resolver cache.
///
/// Runs `dscacheutil -flushcache`, which talks to mDNSResponder over IPC and
/// does NOT require root. The companion `killall -HUP mDNSResponder` would be
/// more thorough but needs sudo (mDNSResponder runs as root), so it's omitted
/// — flushcache alone covers the common case without an admin password prompt.
actor FlushDNSProvider: ActionProvider {
    let itemKey: BuiltinItem = .flushDNS
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        _ = try await ShellRunner.run("/usr/bin/dscacheutil", args: ["-flushcache"])
    }
}
