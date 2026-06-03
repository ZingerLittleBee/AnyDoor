import Foundation
import HostsHelperShared

/// Production writer: sends the composed hosts content to the root helper over XPC.
struct PrivilegedHelperWriter: HostsWriter {
    func write(_ content: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let conn = NSXPCConnection(machServiceName: HostsHelperConstants.machServiceName,
                                       options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: HostsHelperProtocol.self)
            conn.resume()
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: HostsWriterError.writeFailed(String(describing: error)))
            } as? HostsHelperProtocol
            guard let proxy else {
                conn.invalidate()
                cont.resume(throwing: HostsWriterError.writeFailed("no proxy"))
                return
            }
            proxy.writeHosts(content) { errorMessage in
                conn.invalidate()
                if let errorMessage {
                    cont.resume(throwing: HostsWriterError.writeFailed(errorMessage))
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }
}
