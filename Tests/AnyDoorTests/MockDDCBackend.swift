import Foundation
import CoreGraphics
@testable import AnyDoor

/// In-memory mock for unit tests. Scripted return values + recording of calls.
final class MockDDCBackend: DDCBackend, @unchecked Sendable {
    struct ReadCall: Equatable { let displayID: CGDirectDisplayID; let vcp: UInt8 }
    struct WriteCall: Equatable { let displayID: CGDirectDisplayID; let vcp: UInt8; let value: UInt16 }

    private let lock = NSLock()
    private var _transportSupported: Set<CGDirectDisplayID>
    private var _readResults: [CGDirectDisplayID: UInt16?]
    private var _writeError: Error?
    private(set) var readCalls: [ReadCall] = []
    private(set) var writeCalls: [WriteCall] = []

    init(transportSupported: Set<CGDirectDisplayID> = [],
         readResults: [CGDirectDisplayID: UInt16?] = [:],
         writeError: Error? = nil) {
        self._transportSupported = transportSupported
        self._readResults = readResults
        self._writeError = writeError
    }

    func transportReady(displayID: CGDirectDisplayID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _transportSupported.contains(displayID)
    }

    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16? {
        lock.withLock {
            readCalls.append(ReadCall(displayID: displayID, vcp: vcp))
            return _readResults[displayID] ?? nil
        }
    }

    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws {
        let err: Error? = lock.withLock {
            writeCalls.append(WriteCall(displayID: displayID, vcp: vcp, value: value))
            return _writeError
        }
        if let err { throw err }
    }
}
