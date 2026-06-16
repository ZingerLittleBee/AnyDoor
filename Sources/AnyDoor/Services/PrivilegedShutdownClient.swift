import Foundation
import HostsHelperShared

/// Sends a forced-shutdown request to the root helper over XPC. Reused approval:
/// requires the same enabled LaunchDaemon as the hosts writer.
struct PrivilegedShutdownClient: Sendable {
    enum ClientError: Error { case noProxy, failed(String) }

    func shutDown() async throws {
        try await PrivilegedHelperCall.run(
            makeError: { ClientError.failed($0) },
            request: { proxy, finish in
                proxy.shutDown { errorMessage in finish(errorMessage) }
            }
        )
    }
}
