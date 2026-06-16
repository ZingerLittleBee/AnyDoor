import Foundation
import HostsHelperShared

/// Production writer: sends the composed hosts content to the root helper over XPC.
struct PrivilegedHelperWriter: HostsWriter {
    func write(_ content: String) async throws {
        try await PrivilegedHelperCall.run(
            makeError: { HostsWriterError.writeFailed($0) },
            request: { proxy, finish in
                proxy.writeHosts(content) { errorMessage in finish(errorMessage) }
            }
        )
    }
}
