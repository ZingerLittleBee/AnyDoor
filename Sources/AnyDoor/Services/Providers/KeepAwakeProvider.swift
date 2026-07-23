import Foundation
import IOKit.pwr_mgt
import OSLog
import PluginInterface

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "keepawake")

/// User-selectable presets for how long Keep Awake should hold the assertion.
enum KeepAwakeDuration: Hashable, Sendable {
    case indefinite
    case minutes(Int)

    var seconds: TimeInterval? {
        switch self {
        case .indefinite:     return nil
        case .minutes(let m): return TimeInterval(m) * 60
        }
    }
}

/// Public state exposed to PanelStore. Encodes both the on/off bit and the
/// scheduled end-date so views can render a "Awake until HH:mm" subtitle
/// without polling — the timed end-date is stable until the next mutation.
enum KeepAwakeState: Hashable, Sendable {
    case off
    case indefinite
    case timed(endDate: Date)

    var isOn: Bool {
        switch self {
        case .off:                  return false
        case .indefinite, .timed:   return true
        }
    }
}

/// Side-effect boundary for the IOPMAssertion. Abstracting it makes the
/// provider testable without touching real power-management state and lets
/// unit tests verify acquire/release symmetry.
protocol KeepAwakeBackend: Sendable {
    func acquire() throws
    func release()
    var isHeld: Bool { get }
}

/// Production backend wrapping `IOPMAssertionCreateWithName` /
/// `IOPMAssertionRelease`. The assertion is also released implicitly at
/// process exit, so the only leak path would be a missed `release()` call
/// while the app is running — the provider's expiration logic prevents that.
final class IOKitKeepAwakeBackend: KeepAwakeBackend, @unchecked Sendable {
    private var assertionID: IOPMAssertionID?

    var isHeld: Bool { assertionID != nil }

    func acquire() throws {
        guard assertionID == nil else { return }
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "AnyDoor Keep Awake" as CFString,
            &newID
        )
        guard result == kIOReturnSuccess else {
            logger.error("IOPMAssertionCreateWithName failed: \(result)")
            throw BuiltinError.ioKitFailed(Int32(result))
        }
        assertionID = newID
    }

    func release() {
        guard let id = assertionID else { return }
        IOPMAssertionRelease(id)
        assertionID = nil
    }
}

/// Prevents the system from sleeping while the assertion is held.
///
/// Two modes:
/// - `indefinite` — assertion held until the user disables it.
/// - `timed(endDate:)` — assertion auto-released after a fixed interval.
///
/// Every mutation cancels any pending expiration `Task` before scheduling a
/// new one, so re-applying a mode never stacks assertions or timers. State
/// changes are pushed to PanelStore via an injected MainActor callback.
actor KeepAwakeProvider: ToggleProvider {
    let itemKey: BuiltinItem = .keepAwake
    var permission: PermissionStatus { .notRequired }

    private let backend: any KeepAwakeBackend
    private let onChange: (@MainActor @Sendable (KeepAwakeState) -> Void)?
    private var state: KeepAwakeState = .off
    private var expirationTask: Task<Void, Never>?

    init(
        backend: any KeepAwakeBackend = IOKitKeepAwakeBackend(),
        onChange: (@MainActor @Sendable (KeepAwakeState) -> Void)? = nil
    ) {
        self.backend = backend
        self.onChange = onChange
    }

    /// Current state snapshot. Used by PanelStore for the eager cache refresh
    /// performed in `refreshAll()`.
    var currentState: KeepAwakeState { state }

    // MARK: - ToggleProvider conformance

    func readState() async throws -> Bool { state.isOn }

    /// Boolean conformance used by the global hotkey path. Enabling defaults
    /// to `.indefinite` (the conservative choice — the user pressed a hotkey,
    /// they expect a simple on/off semantics, not a duration prompt).
    /// Disabling cancels any timed mode and any pending expiration task.
    func setState(_ enabled: Bool) async throws {
        try await apply(enabled ? .indefinite : nil)
    }

    // MARK: - Duration-aware API

    /// Apply a duration (or `nil` to disable). Always cancels the previous
    /// expiration task first; only holds one IOPM assertion at a time
    /// regardless of how often it is called.
    func apply(_ duration: KeepAwakeDuration?) async throws {
        // Cancel any pending expiration up front: mode changes, re-applies
        // and disable all share this prelude.
        expirationTask?.cancel()
        expirationTask = nil

        guard let duration else {
            backend.release()
            await update(state: .off)
            return
        }

        // Idempotent — no-op when already held.
        try backend.acquire()

        switch duration {
        case .indefinite:
            await update(state: .indefinite)

        case .minutes(let minutes):
            // Defensive floor: never schedule a zero/negative timer that
            // would fire immediately and confuse the user.
            let safeMinutes = max(1, minutes)
            let seconds = TimeInterval(safeMinutes) * 60
            let endDate = Date().addingTimeInterval(seconds)
            await update(state: .timed(endDate: endDate))
            scheduleExpiration(after: seconds)
        }
    }

    private func scheduleExpiration(after seconds: TimeInterval) {
        let nanos = UInt64(seconds * 1_000_000_000)
        expirationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            await self.handleExpiration()
        }
    }

    /// Internal so unit tests can simulate the timer firing without sleeping
    /// for real wall-clock minutes. Production code only reaches it from the
    /// expiration `Task` above.
    func handleExpiration() async {
        // Defensive: if the state changed between the timer firing and us
        // grabbing the actor (e.g., user manually switched to indefinite),
        // do nothing — releasing here would drop an assertion the new mode
        // still needs.
        guard case .timed = state else { return }
        backend.release()
        await update(state: .off)
    }

    private func update(state newState: KeepAwakeState) async {
        state = newState
        if let onChange {
            let snapshot = newState
            await MainActor.run { onChange(snapshot) }
        }
    }
}
