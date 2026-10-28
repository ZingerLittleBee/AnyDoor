import Foundation

/// Only the final constant-time exchange holds this lock. Stop revokes it before
/// waiting for detached work; an obsolete I/O task cannot enter a later session.
/// All mutable state is lock-protected. Replace this unchecked boundary when a
/// standard synchronous locking primitive carries Sendable in the deployment SDK.
final class ClipboardLinkedFileMutationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGeneration: UInt64?

    func activate(_ generation: UInt64) {
        lock.withLock { activeGeneration = generation }
    }

    func revoke() {
        lock.withLock { activeGeneration = nil }
    }

    func perform<Value>(generation: UInt64, _ operation: () throws -> Value) throws -> Value {
        try lock.withLock {
            guard activeGeneration == generation else { throw CancellationError() }
            try Task.checkCancellation()
            return try operation()
        }
    }
}
