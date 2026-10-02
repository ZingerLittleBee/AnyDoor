import AppKit
import CoreServices
import PluginInterface

/// Automation (Apple Events) permission for the apps AnyDoor scripts.
///
/// AnyDoor sends Apple Events to System Events (dark mode, graceful scheduled
/// shutdown) and to Finder (Empty Trash, Image Conversion's Finder selection).
/// Automation is a per-target TCC permission with no "drag into list" pane, so
/// this offers a status check plus a request that shows the standard system
/// prompt. `systemEvents` (a live, bounded, non-prompting check) and
/// `request()` cover System Events, the target the Dark Mode panel row and the
/// Settings and onboarding rows report; `determine(target:askUserIfNeeded:)`
/// checks any target.
///
/// `AEDeterminePermissionToAutomateTarget` reports `procNotFound` when the target
/// app is not running, so `activateSystemEvents()` must run before a System
/// Events `request()`. The `systemEvents` check launches System Events itself
/// while it still needs a verdict.
enum AutomationPermission {
    private static let systemEventsBundleID = "com.apple.systemevents"
    private static let systemEventsURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/System Events.app")

    /// System Events' verdict, shared by the Dark Mode panel row and the
    /// Settings and onboarding permission rows, so they agree and a System
    /// Events that stops answering ties up one check at most. System Events
    /// quits when idle, so the check launches it while a verdict is still
    /// needed. The launch counts against the check's one-second bound: when
    /// starting System Events and checking take longer, as on a cold start, the
    /// first read after AnyDoor launches reports `.undetermined`, and a later
    /// read reports the verdict the check recorded.
    static let systemEvents = AutomationPermissionCheck(
        target: systemEventsBundleID,
        launchTarget: { await AutomationPermission.activateSystemEvents() }
    )

    /// Launches System Events (faceless, non-activating) so the status check
    /// returns a real verdict instead of `procNotFound`.
    static func activateSystemEvents() async {
        guard NSRunningApplication
            .runningApplications(withBundleIdentifier: systemEventsBundleID)
            .isEmpty
        else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(
            at: systemEventsURL, configuration: config)
    }

    /// Shows the system Automation prompt when the state is undetermined.
    /// Blocks until the user responds — call off the main actor. Returns true
    /// when AnyDoor ends up authorized.
    static func request() -> Bool {
        determine(target: systemEventsBundleID, askUserIfNeeded: true) == noErr
    }

    static func openSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Whether AnyDoor may send Apple Events to the running app `bundleID`:
    /// `noErr` when allowed, `errAEEventNotPermitted` when denied,
    /// `errAEEventWouldRequireUserConsent` when the user has not decided yet and
    /// `askUserIfNeeded` is false, and `procNotFound` when the target is not
    /// running. It waits for the target app itself to answer, so it blocks for
    /// as long as the target hangs, and it also waits for the user's answer
    /// when `askUserIfNeeded` is true. Never call it on the main thread.
    static func determine(target bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        var address = AEAddressDesc()
        let createStatus = bundleID.withCString {
            AECreateDesc(typeApplicationBundleID, $0, bundleID.utf8.count, &address)
        }
        guard createStatus == noErr else { return OSStatus(createStatus) }
        defer { AEDisposeDesc(&address) }
        return AEDeterminePermissionToAutomateTarget(
            &address, typeWildCard, typeWildCard, askUserIfNeeded)
    }
}

/// One target app's Automation verdict, checked live without prompting.
///
/// `AutomationPermission.determine` waits for the target app itself to answer,
/// so it blocks for as long as the target hangs. Each check therefore runs on
/// this instance's own serial queue, never on the main thread, a caller's
/// actor, or a cooperative thread. Reads share the check in flight, so a
/// target that stops answering ties up one check at most. A read waits until
/// that check finishes or has run for `timeout`, and then reports the last
/// verdict; once the check has run that long, reads report the last verdict
/// at once instead of waiting on it. The check still records its own verdict
/// whenever the target answers.
actor AutomationPermissionCheck {
    /// The check in flight, and the reads waiting for it.
    private struct RunningCheck {
        let id: Int
        let deadlineTimer: Task<Void, Never>
        /// Set once the check has run for `timeout`; reads stop waiting for it.
        var isOverdue = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let determine: @Sendable () -> OSStatus
    /// Starts the target when a check finds it not running and a verdict is
    /// still needed; nil for a target a check must never launch (Finder).
    private let launchTarget: (@Sendable () async -> Void)?
    private let timeout: Duration
    private let queue: DispatchQueue
    /// Last definite verdict, from a live check or from the caller's own Apple
    /// Event (`record(_:)`); nil before the first one.
    private var lastVerdict: PermissionStatus?
    private var runningCheck: RunningCheck?
    private var lastCheckID = 0

    /// `determine` replaces the live non-prompting check of `bundleID`; tests
    /// inject it so they never reach TCC.
    init(
        target bundleID: String,
        timeout: Duration = .seconds(1),
        launchTarget: (@Sendable () async -> Void)? = nil,
        determine: (@Sendable () -> OSStatus)? = nil
    ) {
        self.timeout = timeout
        self.launchTarget = launchTarget
        self.determine = determine ?? {
            AutomationPermission.determine(target: bundleID, askUserIfNeeded: false)
        }
        queue = DispatchQueue(label: "dev.bybee.AnyDoor.automation.\(bundleID)")
    }

    /// The live verdict; the last one while the target is not running or has
    /// not answered within `timeout`; `.undetermined` before any verdict.
    var status: PermissionStatus {
        get async {
            if runningCheck == nil { startCheck() }
            if runningCheck?.isOverdue == false {
                await withCheckedContinuation { park($0) }
            }
            return lastVerdict ?? .undetermined
        }
    }

    /// Records what the caller's own Apple Event to the target found.
    func record(_ verdict: PermissionStatus) {
        lastVerdict = verdict
    }

    /// No verdict yet, or denied: the states a grant in System Settings has to
    /// clear, which a check of a target that isn't running can't do.
    private var needsVerdict: Bool { lastVerdict == nil || lastVerdict == .denied }

    private func startCheck() {
        lastCheckID += 1
        let id = lastCheckID
        let deadlineTimer = Task {
            try? await Task.sleep(for: timeout)
            stopWaiting(for: id)
        }
        runningCheck = RunningCheck(id: id, deadlineTimer: deadlineTimer)
        Task {
            var status = await runDetermine()
            if status == OSStatus(procNotFound), needsVerdict, let launchTarget {
                await launchTarget()
                status = await runDetermine()
            }
            if let verdict = AutomationPermissionCheck.verdict(for: status) {
                lastVerdict = verdict
            }
            finishCheck(id)
        }
    }

    private func runDetermine() async -> OSStatus {
        let determine = determine
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: determine()) }
        }
    }

    /// Holds a read until the check in flight finishes or has run for `timeout`.
    private func park(_ waiter: CheckedContinuation<Void, Never>) {
        guard let check = runningCheck, !check.isOverdue else { return waiter.resume() }
        runningCheck?.waiters.append(waiter)
    }

    /// The check has run for `timeout`: release its readers, and let later
    /// reads report the last verdict at once while it stays stuck.
    private func stopWaiting(for id: Int) {
        guard let check = runningCheck, check.id == id else { return }
        runningCheck?.isOverdue = true
        runningCheck?.waiters.removeAll()
        for waiter in check.waiters { waiter.resume() }
    }

    private func finishCheck(_ id: Int) {
        guard let check = runningCheck, check.id == id else { return }
        runningCheck = nil
        check.deadlineTimer.cancel()
        for waiter in check.waiters { waiter.resume() }
    }

    /// Maps a non-prompting check; nil when it gives no verdict, such as
    /// `procNotFound` while the target isn't running.
    private static func verdict(for status: OSStatus) -> PermissionStatus? {
        switch status {
        case OSStatus(noErr): .granted
        case OSStatus(errAEEventNotPermitted): .denied
        // Not decided yet: the row stays runnable, so a click shows the system
        // prompt instead of sending the user to System Settings.
        case OSStatus(errAEEventWouldRequireUserConsent): .undetermined
        default: nil
        }
    }
}
