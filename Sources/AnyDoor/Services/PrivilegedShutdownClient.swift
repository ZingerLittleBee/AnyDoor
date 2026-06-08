import Foundation
import HostsHelperShared

/// Sends a forced-shutdown request to the root helper over XPC. Reused approval:
/// requires the same enabled LaunchDaemon as the hosts writer.
struct PrivilegedShutdownClient: Sendable {
    enum ClientError: Error { case noProxy, failed(String) }

    func shutDown() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let conn = NSXPCConnection(machServiceName: PrivilegedHelperConstants.machServiceName,
                                       options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
            conn.resume()
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: ClientError.failed(String(describing: error)))
            } as? PrivilegedHelperProtocol
            guard let proxy else {
                conn.invalidate()
                cont.resume(throwing: ClientError.noProxy)
                return
            }
            proxy.shutDown { errorMessage in
                conn.invalidate()
                if let errorMessage {
                    cont.resume(throwing: ClientError.failed(errorMessage))
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }
}
