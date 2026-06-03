import Foundation

/// In-memory `HostsWriter` for unit tests. Records the last payload and can be
/// configured to throw.
final class MockHostsWriter: HostsWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastWritten: String?
    private var _writeCount = 0
    var errorToThrow: Error?

    var lastWritten: String? { lock.withLock { _lastWritten } }
    var writeCount: Int { lock.withLock { _writeCount } }

    func write(_ content: String) async throws {
        if let errorToThrow { throw errorToThrow }
        lock.withLock {
            _lastWritten = content
            _writeCount += 1
        }
    }
}
