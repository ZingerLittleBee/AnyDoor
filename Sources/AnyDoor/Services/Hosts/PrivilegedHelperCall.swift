import Foundation
import HostsHelperShared

/// Drives a single request to the privileged helper over XPC with a hard
/// timeout and connection invalidation/interruption handling.
///
/// Why this exists: a bare `withCheckedThrowingContinuation` around an
/// `NSXPCConnection` resumes only from the proxy's error handler (a *send*
/// failure) and the reply block. If the helper accepts the message but never
/// calls its reply (root daemon wedged, `/etc` write blocked, killed mid-reply)
/// and the connection never errors, neither closure fires and the continuation
/// hangs forever — silently killing the Hosts feature / scheduled shutdown until
/// relaunch. Here the first of {reply, send error, interruption, invalidation,
/// timeout} resolves exactly once (a `CheckedContinuation` traps on a second
/// resume), and a timeout invalidates the connection so a wedged helper still
/// surfaces an error instead of hanging.
enum PrivilegedHelperCall {
    /// Invoke `request` on the helper proxy. `request` must call its `finish`
    /// closure with nil on success or a message on failure. Throws the error
    /// built by `makeError` if the connection drops, no proxy can be created, or
    /// the helper does not reply within `timeout`.
    static func run(
        timeout: Duration = .seconds(10),
        makeError: @escaping @Sendable (String) -> Error,
        request: (_ proxy: PrivilegedHelperProtocol, _ finish: @escaping @Sendable (String?) -> Void) -> Void
    ) async throws {
        // NSXPCConnection's resume/invalidate/proxy calls are thread-safe, so it
        // is safe to touch from the timeout task and the connection's own
        // handler queues; the language can't prove that, hence the opt-out.
        nonisolated(unsafe) let conn = NSXPCConnection(
            machServiceName: PrivilegedHelperConstants.machServiceName,
            options: .privileged
        )
        conn.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)

        let state = CallState()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // The single place that resolves the continuation, guarded so only
            // the first signal wins and the timeout task is cancelled.
            @Sendable func settle(_ failure: String?) {
                guard state.claim() else { return }
                conn.invalidationHandler = nil
                conn.interruptionHandler = nil
                conn.invalidate()
                if let failure {
                    cont.resume(throwing: makeError(failure))
                } else {
                    cont.resume(returning: ())
                }
            }

            conn.invalidationHandler = { settle("connection invalidated") }
            conn.interruptionHandler = { settle("connection interrupted") }
            conn.resume()

            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                settle(String(describing: error))
            } as? PrivilegedHelperProtocol

            guard let proxy else {
                settle("no proxy")
                return
            }

            let timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                if Task.isCancelled { return }
                settle("timed out waiting for the privileged helper")
            }
            state.setTimeout(timeoutTask)

            request(proxy, settle)
        }
    }
}

/// One-shot resume guard shared between the XPC handler queues and the timeout
/// task. `claim()` returns true for exactly one caller and cancels the timeout.
private final class CallState: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var timeoutTask: Task<Void, Never>?

    /// Returns true the first time only; cancels the timeout on the winning call.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        timeoutTask?.cancel()
        timeoutTask = nil
        return true
    }

    /// Stash the timeout task, or cancel it immediately if the call already
    /// resolved (a fast reply can beat this assignment).
    func setTimeout(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if fired {
            task.cancel()
        } else {
            timeoutTask = task
        }
    }
}
