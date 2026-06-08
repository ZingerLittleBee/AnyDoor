import AppKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "shutdown")

/// Owns the one-shot scheduled-shutdown lifecycle: config (UserDefaults), the
/// absolute-`Date` countdown, sleep/wake re-validation, the cancelable warning,
/// and shutdown execution. `@MainActor` because it drives UI (panel state +
/// warning window) and observes `NSWorkspace` notifications. State is pushed to
/// PanelStore via the `onChange` callback.
@MainActor
final class ScheduledShutdownService {
    static let shared = ScheduledShutdownService(
        executor: SystemShutdownExecutor(),
        warning: ShutdownWarningWindowController()
    )

    // Persisted keys. `fireDate` is the live, machine-local target; the rest are
    // portable config (whitelisted in SyncSettingsRegistry).
    static let fireDateKey = "scheduledShutdown.fireDate"
    static let forcedKey = "scheduledShutdown.forced"
    static let warningLeadKey = "scheduledShutdown.warningLeadSeconds"
    static let defaultMinutesKey = "scheduledShutdown.defaultMinutes"

    private let executor: any ShutdownExecuting
    private let warning: any ShutdownWarningPresenting
    private let defaults: UserDefaults
    private let now: () -> Date

    private(set) var state: ScheduledShutdownState = .off

    /// Pushed to PanelStore on every transition (mutation, fire, cancel, wake).
    var onChange: (@MainActor @Sendable (ScheduledShutdownState) -> Void)?

    private var warningTimer: Timer?
    private var countdownTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(
        executor: any ShutdownExecuting,
        warning: any ShutdownWarningPresenting,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() }
    ) {
        self.executor = executor
        self.warning = warning
        self.defaults = defaults
        self.now = now
    }

    // MARK: - Config (read fresh, like ClipboardPreferences)

    /// Forced shutdown bypasses unsaved-work prompts via the privileged helper.
    var forced: Bool { defaults.object(forKey: Self.forcedKey) as? Bool ?? false }
    /// Seconds before `fireDate` to show the cancelable warning.
    var warningLeadSeconds: Int { defaults.object(forKey: Self.warningLeadKey) as? Int ?? 60 }
    /// Duration the hotkey/`setState(true)` path arms.
    var defaultMinutes: Int { defaults.object(forKey: Self.defaultMinutesKey) as? Int ?? 30 }

    // MARK: - Arm / cancel

    func arm(_ duration: ScheduledShutdownDuration) {
        let fireDate = now().addingTimeInterval(duration.seconds)
        armAt(fireDate: fireDate, persist: true)
    }

    private func armAt(fireDate: Date, persist: Bool) {
        invalidateTimers()
        warning.dismiss()
        state = .armed(fireDate: fireDate)
        if persist {
            defaults.set(fireDate.timeIntervalSince1970, forKey: Self.fireDateKey)
        }
        scheduleTimers(fireDate: fireDate)
        notify()
    }

    func cancel() {
        invalidateTimers()
        warning.dismiss()
        state = .off
        defaults.removeObject(forKey: Self.fireDateKey)
        notify()
    }

    // MARK: - Timers (anchored to the absolute fireDate)

    private func scheduleTimers(fireDate: Date) {
        let lead = TimeInterval(max(0, warningLeadSeconds))
        let warningDate = max(now(), fireDate.addingTimeInterval(-lead))
        let interval = max(0, warningDate.timeIntervalSince(now()))
        warningTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginWarning() }
        }
    }

    /// Internal for testing: start (or resume) the cancelable warning.
    func beginWarning() {
        guard case .armed(let fireDate) = state else { return }
        let remaining = Int(fireDate.timeIntervalSince(now()).rounded())
        if remaining <= 0 {
            performFire()
            return
        }
        warning.present(totalSeconds: remaining, onCancel: { [weak self] in self?.cancel() })
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickCountdown() }
        }
    }

    private func tickCountdown() {
        guard case .armed(let fireDate) = state else { return }
        let remaining = Int(fireDate.timeIntervalSince(now()).rounded())
        if remaining <= 0 {
            performFire()
        } else {
            warning.update(secondsRemaining: remaining)
        }
    }

    /// Internal for testing: clear state synchronously, then kick off the async
    /// shutdown. Splitting the two keeps state assertions deterministic.
    func performFire() {
        invalidateTimers()
        warning.dismiss()
        state = .off
        defaults.removeObject(forKey: Self.fireDateKey)
        notify()
        Task { await self.executeShutdown() }
    }

    /// Internal for testing: the awaitable shutdown call. Surfaces failures
    /// loudly — a silently-swallowed failure would leave the user believing the
    /// Mac will power off when it won't.
    func executeShutdown() async {
        let forced = self.forced
        do {
            try await executor.shutDown(forced: forced)
        } catch {
            logger.error("Scheduled shutdown failed: \(String(describing: error))")
            ToastPresenter.shared.show(.failure(L(.shutdownToastFailed)))
        }
    }

    private func invalidateTimers() {
        warningTimer?.invalidate(); warningTimer = nil
        countdownTimer?.invalidate(); countdownTimer = nil
    }

    private func notify() {
        onChange?(state)
    }
}

// TEMP stubs — removed in Task 5 (L key) and Task 9 (window controller).
// Task 5 deletes this and adds the real L10n.Key case.
private extension L10n.Key { static var shutdownToastFailed: L10n.Key { .builtinKeepAwake } }
// Task 9 deletes this and adds the real controller.
@MainActor
final class ShutdownWarningWindowController: ShutdownWarningPresenting {
    func present(totalSeconds: Int, onCancel: @escaping @MainActor () -> Void) {}
    func update(secondsRemaining: Int) {}
    func dismiss() {}
}
