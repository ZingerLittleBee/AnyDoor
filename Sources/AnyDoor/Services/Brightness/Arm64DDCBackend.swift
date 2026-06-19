#if arch(arm64)
import Foundation
import IOKit
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "ddc.arm64")

// MARK: - Private IOAVService symbol declarations
//
// These three symbols live in CoreDisplay/IOKit's private surface. Function
// signatures are not copyrightable; the calling convention is documented in
// public Apple sample code (AVCustomEdit, AVScreenShack) and in Apple's
// open-source IOAVService headers shipped historically with xnu.

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(
    _ allocator: CFAllocator?,
    _ service: io_service_t
) -> Unmanaged<AnyObject>?

@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(
    _ service: AnyObject,
    _ chipAddress: UInt32,
    _ offset: UInt32,
    _ buffer: UnsafeMutableRawPointer,
    _ length: UInt32
) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(
    _ service: AnyObject,
    _ chipAddress: UInt32,
    _ offset: UInt32,
    _ buffer: UnsafeRawPointer,
    _ length: UInt32
) -> IOReturn

// MARK: - Backend

struct Arm64DDCBackend: DDCBackend {
    /// Per-process cache: displayID -> IOAVService object. Invalidated by
    /// the caller (DisplayBrightnessService) on screen-change notifications.
    private static let cache = AVServiceCache()

    func transportReady(displayID: CGDirectDisplayID) -> Bool {
        return Self.cache.service(for: displayID) != nil
    }

    func invalidateCaches() {
        Self.cache.invalidate()
    }

    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16? {
        guard let service = Self.cache.service(for: displayID) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> UInt16? in
            // DDC VCP read request, 2 data bytes [op=0x01, vcp]:
            //   [length=0x80|2, op=0x01, vcp, chksum]
            // The source byte (0x51) is supplied via IOAVServiceWriteI2C's
            // dataAddress parameter and is NOT placed in the packet buffer,
            // but it still counts toward the checksum domain.
            var request: [UInt8] = [0x82, 0x01, vcp, 0x00]
            request[request.count - 1] = ddcChecksum(packet: request)

            let writeResult = request.withUnsafeBufferPointer { buf -> IOReturn in
                IOAVServiceWriteI2C(service, 0x37, 0x51, buf.baseAddress!, UInt32(buf.count))
            }
            guard writeResult == KERN_SUCCESS else { return nil }

            // Per DDC/CI: the source must wait at least 40 ms before reading the reply.
            try? await Task.sleep(nanoseconds: 50_000_000)

            // 11-byte VCP response:
            //   [src=0x6E, len=0x88, op=0x02, result=0x00, vcp, type,
            //    maxHi, maxLo, curHi, curLo, chksum]
            var reply = [UInt8](repeating: 0, count: 11)
            let readResult = reply.withUnsafeMutableBufferPointer { buf -> IOReturn in
                IOAVServiceReadI2C(service, 0x37, 0x51, buf.baseAddress!, UInt32(buf.count))
            }
            guard readResult == KERN_SUCCESS, reply[0] == 0x6E, reply[1] == 0x88,
                  reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp else {
                return nil
            }
            let current = (UInt16(reply[8]) << 8) | UInt16(reply[9])
            return current
        }.value
    }

    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws {
        guard let service = Self.cache.service(for: displayID) else {
            throw NSError(domain: "Arm64DDC", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "transport not ready"])
        }
        try await Task.detached(priority: .userInitiated) {
            // DDC VCP write, 4 data bytes [op=0x03, vcp, valHi, valLo]:
            //   [length=0x80|4, op=0x03, vcp, valHi, valLo, chksum]
            // The source byte (0x51) is supplied via IOAVServiceWriteI2C's
            // dataAddress parameter and is NOT in the packet buffer.
            var packet: [UInt8] = [
                0x84, 0x03, vcp,
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF),
                0x00
            ]
            packet[packet.count - 1] = ddcChecksum(packet: packet)

            let result = packet.withUnsafeBufferPointer { buf -> IOReturn in
                IOAVServiceWriteI2C(service, 0x37, 0x51, buf.baseAddress!, UInt32(buf.count))
            }
            guard result == KERN_SUCCESS else {
                throw NSError(domain: "Arm64DDC", code: Int(result),
                              userInfo: [NSLocalizedDescriptionKey: "I2C write failed"])
            }
        }.value
    }
}

/// XOR-checksum over the packet, excluding the trailing checksum slot.
/// Seed is `dest(0x6E) ^ src(0x51) = 0x3F`: those two bytes belong to the
/// DDC framing but are sent out-of-band by IOAVService (as I2C chip and
/// data addresses) rather than appearing in the buffer.
private func ddcChecksum(packet: [UInt8]) -> UInt8 {
    var chk: UInt8 = 0x6E ^ 0x51
    for i in 0..<(packet.count - 1) { chk ^= packet[i] }
    return chk
}

/// Per-displayID IOAVService lookup, cached for the process lifetime.
/// Higher layers must drop entries on screen-change notifications.
private final class AVServiceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [CGDirectDisplayID: AnyObject] = [:]

    func service(for displayID: CGDirectDisplayID) -> AnyObject? {
        lock.withLock {
            if let s = map[displayID] { return s }
            guard let s = locateService(for: displayID) else { return nil }
            map[displayID] = s
            return s
        }
    }

    func invalidate() {
        lock.withLock {
            map.removeAll()
        }
    }

    /// Pairs each external `CGDirectDisplayID` with a `DCPAVServiceProxy`
    /// IORegistry entry by position.
    ///
    /// Background: on macOS 26 Apple Silicon the `IOAVService` class is no
    /// longer populated (`ioreg`'s class counter shows zero instances).
    /// Active entries are `DCPAVServiceProxy` (provider `AFKEndpointInterface`,
    /// `Location = External` for external monitors). These entries have no
    /// `VendorID` / `ProductID` / `AlphanumericSerialNumber` properties to
    /// match against `CGDisplay*Number`, so we fall back to position-based
    /// matching: enumerate proxies in IORegistry order, then the Nth external
    /// online display gets the Nth proxy. For typical setups (1-3 external
    /// monitors) the pairing is stable across reboots.
    ///
    /// Worst case (mismatched pairing): brightness slider for monitor A
    /// drives monitor B. Spec § "Out-of-scope failure modes" explicitly
    /// accepts position-based fallback as the v1 strategy.
    private func locateService(for displayID: CGDirectDisplayID) -> AnyObject? {
        let proxies = enumerateExternalProxies()
        // The caller owns every enumerated proxy and must release each one. Do it
        // on EVERY return path with a single defer: the guards below can bail
        // before any work (e.g. a stale displayID, or more online external
        // displays than proxies), which previously leaked the whole array. The
        // chosen proxy is released here too — IOAVServiceCreateWithService's
        // takeRetainedValue holds an independent reference, so releasing the
        // io_service_t afterward is correct and never double-frees.
        defer { for service in proxies { IOObjectRelease(service) } }
        guard !proxies.isEmpty else { return nil }
        let externalDisplays = onlineExternalDisplays()
        guard let index = externalDisplays.firstIndex(of: displayID),
              index < proxies.count else { return nil }
        let service = proxies[index]
        return IOAVServiceCreateWithService(kCFAllocatorDefault, service)?
            .takeRetainedValue()
    }

    /// Online external displays in `CGGetOnlineDisplayList` order.
    private func onlineExternalDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.filter { CGDisplayIsBuiltin($0) == 0 }
    }

    /// `DCPAVServiceProxy` IORegistry entries with `Location == "External"`.
    /// Caller owns the returned `io_service_t` references (must `IOObjectRelease`).
    private func enumerateExternalProxies() -> [io_service_t] {
        var iter: io_iterator_t = 0
        guard let matching = IOServiceMatching("DCPAVServiceProxy") else { return [] }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }

        var out: [io_service_t] = []
        while case let service = IOIteratorNext(iter), service != 0 {
            if let props = serviceProperties(service),
               let location = props["Location"] as? String,
               location == "External" {
                out.append(service)   // ownership transferred to caller
            } else {
                IOObjectRelease(service)
            }
        }
        return out
    }

    private func serviceProperties(_ service: io_service_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let dict = unmanaged?.takeRetainedValue() else { return nil }
        return dict as? [String: Any]
    }
}

#endif
