import Foundation
import HostsHelperShared
import PluginInterface

/// Production write path for `/etc/hosts`: sends the composed content to the
/// root helper over XPC. Core infrastructure (amended ADR-0005) — the Hosts
/// plugin reaches it through `PluginHostServices.privilegedHelper`.
struct PrivilegedHelperWriter {
    func write(_ content: String) async throws {
        try await PrivilegedHelperCall.run(
            makeError: { PrivilegedHelperCallError(message: $0) },
            request: { proxy, finish in
                proxy.writeHosts(content) { errorMessage in finish(errorMessage) }
            }
        )
    }
}
