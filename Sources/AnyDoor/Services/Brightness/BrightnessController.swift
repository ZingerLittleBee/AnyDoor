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

    init(backend: DDCBackend) {
        self.backend = backend
    }

    /// Transport probe — fast, no VCP query. Returns true iff the backend reports
    /// the display reachable. A subsequent read or write may still time out.
    func probe(displayID: CGDirectDisplayID) async -> Bool {
        return backend.transportReady(displayID: displayID)
    }

    /// Reads current brightness, normalised 0.0...1.0; nil on backend nil.
    func read(displayID: CGDirectDisplayID) async -> Float? {
        guard let raw = await backend.read(displayID: displayID, vcp: Self.vcpBrightness) else {
            return nil
        }
        return Float(min(raw, Self.maxValue)) / Float(Self.maxValue)
    }

    /// Writes brightness (0.0...1.0). Throws `Failure.writeFailed` after exactly
    /// one retry on transient failure.
    func write(displayID: CGDirectDisplayID, value: Float) async throws {
        let clamped = max(0, min(1, value))
        let raw = UInt16((clamped * Float(Self.maxValue)).rounded())
        do {
            try await backend.write(displayID: displayID, vcp: Self.vcpBrightness, value: raw)
        } catch {
            logger.debug("DDC write retry for display \(displayID, privacy: .public)")
            do {
                try await backend.write(displayID: displayID, vcp: Self.vcpBrightness, value: raw)
            } catch {
                throw Failure.writeFailed
            }
        }
    }
}
