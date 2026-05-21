import Foundation

/// Flush macOS DNS resolver caches.
///
/// Both `dscacheutil -flushcache` and `killall -HUP mDNSResponder` require root,
/// so the script runs with `with administrator privileges`, which triggers the
/// system's native authentication dialog. No Automation permission required —
/// admin-privileges scripts use their own authorization prompt.
actor FlushDNSProvider: ActionProvider {
    let itemKey: BuiltinItem = .flushDNS
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        _ = try await AppleScriptRunner.run("""
            do shell script "dscacheutil -flushcache && killall -HUP mDNSResponder" with administrator privileges
        """)
    }
}
