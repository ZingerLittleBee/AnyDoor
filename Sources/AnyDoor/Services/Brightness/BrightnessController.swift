import Foundation
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "brightness.controller")

/// Serialises VCP 0x10 I/O for one or more displays. One write retry on failure.
/// Read/write timeouts handled by the underlying backend.
///
/// Always operates on VCP 0x10 (brightness). Values are normalised to 0.0...1.0
/// on the public API; internally converted to the DDC byte range 0...100.
actor BrightnessController {
    enum Failure: Error { case transportUnavailable, writeFailed }

    private let backend: DDCBackend
    private static let vcpBrightness: UInt8 = 0x10
    /// DDC standard: brightness max value byte for VCP 0x10 on essentially every
    /// monitor. A VCP-max handshake is deferred (see spec § "Out-of-scope failure modes").
    private static let maxValue: UInt16 = 100

    /// Tail of a serial transaction chain. The backend runs each I2C exchange in
    /// a detached task, so `await backend.*` releases this actor's isolation — a
    /// reentrant caller could otherwise start a second transaction while one is
    /// still on the wire, and two interleaved DDC/CI exchanges on the same bus
    /// corrupt each other (garbled reads, dropped writes). Every transaction
    /// awaits its predecessor here first, so the actor genuinely serialises VCP
    /// I/O as documented above.
    private var lastTransaction: Task<Void, Never>?

    init(backend: DDCBackend) {
        self.backend = backend
    }

    /// Run `work` strictly after the in-flight transaction completes. Reading
    /// `lastTransaction` and reassigning it happen with no `await` in between, so
    /// the chain can't be torn by reentrancy; only `work` itself (and the wait on
    /// the predecessor) suspends.
    private func serialized<T: Sendable>(_ work: @Sendable @escaping () async -> T) async -> T {
        let previous = lastTransaction
        let task = Task { () -> T in
            await previous?.value
            return await work()
        }
        lastTransaction = Task { _ = await task.value }
        return await task.value
    }

    /// Transport probe — fast, no VCP query. Returns true iff the backend reports
    /// the display reachable. A subsequent read or write may still time out.
    func probe(displayID: CGDirectDisplayID) async -> Bool {
        await serialized { [backend] in
            backend.transportReady(displayID: displayID)
        }
    }

    /// Forward cache invalidation to the backend. Called by
    /// `DisplayBrightnessService.refresh()` on every screen-change so stale
    /// IOAVService handles from unplugged displays are dropped before we
    /// probe / read the new topology. Serialised so a refresh can't drop the
    /// cache mid-transaction.
    func invalidateCaches() async {
        await serialized { [backend] in
            backend.invalidateCaches()
        }
    }

    /// Reads current brightness, normalised 0.0...1.0; nil on backend nil.
    func read(displayID: CGDirectDisplayID) async -> Float? {
        await serialized { [backend] in
            guard let raw = await backend.read(displayID: displayID, vcp: Self.vcpBrightness) else {
                return nil
            }
            return Float(min(raw, Self.maxValue)) / Float(Self.maxValue)
        }
    }

    /// Writes brightness (0.0...1.0). Throws `Failure.writeFailed` after exactly
    /// one retry on transient failure. The write + its retry run as one serial
    /// transaction so a concurrent write can't slip between them.
    func write(displayID: CGDirectDisplayID, value: Float) async throws {
        let clamped = max(0, min(1, value))
        let raw = UInt16((clamped * Float(Self.maxValue)).rounded())
        let failure: Failure? = await serialized { [backend] in
            do {
                try await backend.write(displayID: displayID, vcp: Self.vcpBrightness, value: raw)
                return nil
            } catch {
                logger.debug("DDC write retry for display \(displayID, privacy: .public)")
                do {
                    try await backend.write(displayID: displayID, vcp: Self.vcpBrightness, value: raw)
                    return nil
                } catch {
                    return Failure.writeFailed
                }
            }
        }
        if let failure { throw failure }
    }
}
