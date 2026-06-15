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
    /// Set on clean termination, consumed on the next launch. Distinguishes a
    /// deadline missed because the app was cleanly not running (Quit / silent
    /// update relaunch / system restart — expected, stay quiet) from one missed
    /// because the app crashed (worth surfacing).
    static let cleanExitKey = "scheduledShutdown.cleanExit"

    private let executor: any ShutdownExecuting
    private let warning: any ShutdownWarningPresenting
    private let defaults: UserDefaults
    private let now: () -> Date
    private let notifyMissed: @MainActor () -> Void

    private(set) var state: ScheduledShutdownState = .off

    /// Pushed to PanelStore on every transition (mutation, fire, cancel, wake).
    var onChange: (@MainActor @Sendable (ScheduledShutdownState) -> Void)?

    private var warningTimer: Timer?
    private var countdownTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    /// The shutdown kicked off by `performFire()`. Retained so it isn't dropped
    /// mid-flight and so tests can await exactly that invocation.
    private(set) var fireTask: Task<Void, Never>?

    init(
        executor: any ShutdownExecuting,
        warning: any ShutdownWarningPresenting,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() },
        notifyMissed: @escaping @MainActor () -> Void = {
            // Informational (not error) styling, held longer than the default so
            // it is actually readable — the previous red 1s flash was the source
            // of the "Scheduled … failed" confusion.
            ToastPresenter.shared.show(.info(L(.shutdownToastMissed)), duration: 4.0)
        }
    ) {
        self.executor = executor
        self.warning = warning
        self.defaults = defaults
        self.now = now
        self.notifyMissed = notifyMissed
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

    // MARK: - Lifecycle

    /// Re-arm (or clear) from the persisted absolute target on app launch, and
    /// register the wake observer. A deadline missed while the app was quit is
    /// cancelled (never fired retroactively).
    func bootstrapOnLaunch() {
        registerWakeObserver()
        // Consume the clean-exit marker first, unconditionally: clearing it on
        // every launch means a crash in THIS session (which never reaches
        // `markCleanExit`) is detected as unclean next time.
        let wasCleanExit = defaults.bool(forKey: Self.cleanExitKey)
        defaults.removeObject(forKey: Self.cleanExitKey)

        guard let fireDate = persistedFireDate() else { return }
        if fireDate.timeIntervalSince(now()) > 0 {
            armAt(fireDate: fireDate, persist: false)
        } else {
            defaults.removeObject(forKey: Self.fireDateKey)
            state = .off
            notify()
            // A deadline missed while the app was cleanly not running is
            // expected (the timer only fires while alive) — only surface the
            // genuinely surprising crash-induced miss.
            if !wasCleanExit {
                notifyMissed()
            }
        }
    }

    /// Record that the app is terminating cleanly. Called from
    /// `applicationWillTerminate`; skipped on crash/force-quit so the next launch
    /// can tell the two apart.
    func markCleanExit() {
        defaults.set(true, forKey: Self.cleanExitKey)
    }

    /// Re-read live state after a backup import. Config getters read fresh, so
    /// this only re-arms the timer from the (possibly changed) persisted target.
    func reloadFromDefaults() {
        invalidateTimers()
        warning.dismiss()
        if let fireDate = persistedFireDate(), fireDate.timeIntervalSince(now()) > 0 {
            armAt(fireDate: fireDate, persist: false)
            return
        }
        defaults.removeObject(forKey: Self.fireDateKey)
        state = .off
        notify()
    }

    /// Internal for testing: re-validate against the wall clock after wake. If
    /// the deadline passed while asleep, enter the warning flow (which fires
    /// immediately when overdue — the cancelable warning keeps that safe).
    func handleWake() {
        guard case .armed(let fireDate) = state else { return }
        invalidateTimers()
        if fireDate.timeIntervalSince(now()) <= 0 {
            beginWarning()
        } else {
            scheduleTimers(fireDate: fireDate)
        }
    }

    private func registerWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Run synchronously on the main thread via MainThreadIsolation rather
            // than MainActor.assumeIsolated, whose swift_task_isCurrentExecutor
            // check can fault on the main thread after a ScreenCaptureKit capture
            // (see MainThreadIsolation).
            MainThreadIsolation.run { self?.handleWake() }
        }
    }

    private func persistedFireDate() -> Date? {
        guard let ts = defaults.object(forKey: Self.fireDateKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    // MARK: - Timers (anchored to the absolute fireDate)

    private func scheduleTimers(fireDate: Date) {
        let lead = TimeInterval(max(0, warningLeadSeconds))
        let warningDate = max(now(), fireDate.addingTimeInterval(-lead))
        let interval = max(0, warningDate.timeIntervalSince(now()))
        warningTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainThreadIsolation.run { self?.beginWarning() }
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
            MainThreadIsolation.run { self?.tickCountdown() }
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
        fireTask = Task { await self.executeShutdown() }
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
