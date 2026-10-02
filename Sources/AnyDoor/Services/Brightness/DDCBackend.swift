import CoreGraphics

/// Abstract DDC/CI transport. Two production implementations exist
/// (`IntelDDCBackend` and `Arm64DDCBackend`), selected per slice via
/// `#if arch(arm64)` in the wiring code. `MockDDCBackend` (in the
/// AnyDoorTests target) is used by tests.
protocol DDCBackend: Sendable {
    /// Fast, side-effect-free check: is the I2C / IOAVService transport
    /// reachable for this display? Does NOT issue a VCP read.
    func transportReady(displayID: CGDirectDisplayID) -> Bool

    /// Issue a VCP read. Returns nil on timeout / NACK / unsupported VCP.
    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16?

    /// Issue a VCP write. Throws on I/O failure.
    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws

    /// Drop any per-displayID transport caches. Called by
    /// `DisplayBrightnessService.refresh()` on every screen-change notification
    /// so that hot-unplug + replug with a recycled `CGDirectDisplayID` does not
    /// route subsequent I/O to a defunct transport object.
    func invalidateCaches()
}

extension DDCBackend {
    /// Default no-op for backends that don't cache (Intel, via the vendored
    /// MonitorControl `IntelDDC`, re-resolves per call; mocks have no transport).
    func invalidateCaches() {}
}
