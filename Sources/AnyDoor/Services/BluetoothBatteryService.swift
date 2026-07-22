import Foundation
import PluginInterface
import PluginSupport
import os

enum BluetoothBatteryError: Equatable, Sendable {
    case readFailed
}

/// Observable store for connected Bluetooth accessory battery levels.
///
/// Reads two public, permission-free macOS sources off the MainActor via
/// `ShellRunner` — `system_profiler SPBluetoothDataType -json` (rich, earbud
/// L/R/case) and `pmset -g accps` (covers HID++ mice system_profiler misses) —
/// then folds them together in `BluetoothBatteryParser`. There is no push
/// notification for battery changes, so the UI polls on demand (popover hover)
/// and results are cached for `cacheDuration` to avoid re-spawning subprocesses.
@MainActor
@Observable
final class BluetoothBatteryService {
    // MARK: - Public state

    private(set) var devices: [BluetoothBatteryDevice] = []
    private(set) var isRefreshing: Bool = false
    private(set) var lastError: BluetoothBatteryError? = nil

    // MARK: - Dependencies

    private let cacheDuration: TimeInterval
    private let now: () -> Date
    private static let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "BluetoothBattery")

    // MARK: - Internal refresh state

    private var generation: UInt64 = 0
    private var lastSuccessfulRefreshAt: Date?

    // MARK: - Lifecycle

    // First touched from main-actor UI code. Use MainThreadIsolation rather than
    // MainActor.assumeIsolated so a first access after a ScreenCaptureKit capture
    // (which can leave the main thread's executor tracking dangling) does not
    // fault the swift_task_isCurrentExecutor check. See MainThreadIsolation.
    static let shared: BluetoothBatteryService = MainThreadIsolation.run { BluetoothBatteryService() }

    init(cacheDuration: TimeInterval = 30, now: @escaping () -> Date = Date.init) {
        self.cacheDuration = cacheDuration
        self.now = now
    }

    // MARK: - Refresh

    func refresh(force: Bool = false) async {
        if !force, isCacheFresh { return }

        generation &+= 1
        let myGen = generation
        isRefreshing = true

        // Spawn both probes concurrently; either may fail independently (a `nil`
        // result), so we tolerate one source being unavailable.
        async let spProbe = ShellRunner.run(
            "/usr/sbin/system_profiler",
            args: ["SPBluetoothDataType", "-json"],
            timeout: 12
        )
        async let pmProbe = ShellRunner.run(
            "/usr/bin/pmset",
            args: ["-g", "accps"],
            timeout: 6
        )
        let sp = try? await spProbe
        let pm = try? await pmProbe

        // A newer refresh superseded us while we awaited the subprocesses.
        guard myGen == generation else { return }

        guard sp != nil || pm != nil else {
            lastError = .readFailed
            isRefreshing = false
            Self.logger.error("both battery probes failed")
            return
        }

        // Parsing walks up to a few hundred KB of JSON; keep it off the MainActor.
        let parsed = await Task.detached(priority: .userInitiated) {
            BluetoothBatteryParser.merge(
                systemProfilerJSON: sp?.data(using: .utf8),
                pmsetOutput: pm
            )
        }.value

        guard myGen == generation else { return }
        devices = parsed
        lastError = nil
        lastSuccessfulRefreshAt = now()
        isRefreshing = false
    }

    private var isCacheFresh: Bool {
        guard lastError == nil, let lastSuccessfulRefreshAt else { return false }
        return now().timeIntervalSince(lastSuccessfulRefreshAt) < cacheDuration
    }
}
