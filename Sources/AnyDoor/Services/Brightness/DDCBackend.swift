import Foundation
import CoreGraphics

/// Abstract DDC/CI transport. Two production implementations exist
/// (`IntelDDCBackend` and `Arm64DDCBackend`), selected per slice via
/// `#if arch(arm64)` in the wiring code. `MockDDCBackend` is used by tests.
protocol DDCBackend: Sendable {
    /// Fast, side-effect-free check: is the I2C / IOAVService transport
    /// reachable for this display? Does NOT issue a VCP read.
    func transportReady(displayID: CGDirectDisplayID) -> Bool

    /// Issue a VCP read. Returns nil on timeout / NACK / unsupported VCP.
    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16?

    /// Issue a VCP write. Throws on I/O failure.
    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws
}

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

    func setReadResult(_ value: UInt16?, for displayID: CGDirectDisplayID) {
        lock.lock(); defer { lock.unlock() }
        _readResults[displayID] = value
    }

    func setWriteError(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        _writeError = error
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
