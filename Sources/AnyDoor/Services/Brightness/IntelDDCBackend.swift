#if !arch(arm64)
import Foundation
import CoreGraphics

/// DDC/CI transport for Intel Macs, built on the vendored MonitorControl
/// `IntelDDC` (MIT) in `Vendor/MonitorControlIntelDDC.swift`. Apple Silicon
/// uses `Arm64DDCBackend` instead (the IOFramebuffer I2C path used here does
/// not work on arm64).
struct IntelDDCBackend: DDCBackend {
    func transportReady(displayID: CGDirectDisplayID) -> Bool {
        return IntelDDC(for: displayID) != nil
    }

    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16? {
        await Task.detached(priority: .userInitiated) {
            guard let ddc = IntelDDC(for: displayID),
                  let (current, _) = ddc.read(command: vcp) else { return UInt16?.none }
            return current
        }.value
    }

    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let ddc = IntelDDC(for: displayID) else {
                throw NSError(domain: "IntelDDC", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "DDC unavailable"])
            }
            let ok = ddc.write(command: vcp, value: value)
            if !ok {
                throw NSError(domain: "IntelDDC", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "DDC write failed"])
            }
        }.value
    }
}
#endif
