#if !arch(arm64)
import Foundation
import CoreGraphics
import DDC

/// Wraps reitermarkus/DDC.swift for Intel Macs. Apple Silicon uses
/// `Arm64DDCBackend` instead (DDC.swift's `IOFBGetI2CInterfaceCount`
/// path does not work on arm64).
struct IntelDDCBackend: DDCBackend {
    func transportReady(displayID: CGDirectDisplayID) -> Bool {
        return DDC(for: displayID) != nil
    }

    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16? {
        await Task.detached(priority: .userInitiated) {
            guard let ddc = DDC(for: displayID),
                  let (current, _) = ddc.read(command: vcp) else { return UInt16?.none }
            return current
        }.value
    }

    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let ddc = DDC(for: displayID) else {
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
