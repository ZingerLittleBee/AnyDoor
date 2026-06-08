# Scheduled Shutdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a one-shot "Scheduled Shutdown" (定时关机) quick action to the menu-bar panel: arm a countdown, see "将于 HH:mm 关机", get a cancelable warning, then shut down (graceful by default, optional forced via the privileged helper).

**Architecture:** A dedicated `@MainActor ScheduledShutdownService` owns config (UserDefaults), the absolute-`Date` countdown, sleep/wake re-validation, the warning window, and shutdown execution. A thin `ScheduledShutdownProvider` (`ToggleProvider`) plugs into the panel/hotkey machinery, mirroring Keep Awake. Execution goes through a `ShutdownExecuting` boundary: graceful → `AppleScriptRunner` (System Events), forced → the existing root helper, generalized from `HostsHelperProtocol` to `PrivilegedHelperProtocol`.

**Tech Stack:** Swift 6.2 (strict concurrency, `.v6`), SwiftUI + AppKit, NSXPC privileged helper, UserDefaults, XCTest.

**Spec:** `docs/superpowers/specs/2026-06-08-scheduled-shutdown-design.md`

---

## File Structure

**New files**
- `Sources/AnyDoor/Services/ScheduledShutdown.swift` — domain types: `ScheduledShutdownDuration`, `ScheduledShutdownState`, `ShutdownExecuting`, `ShutdownWarningPresenting`, `SystemShutdownExecutor`.
- `Sources/AnyDoor/Services/ScheduledShutdownService.swift` — the brain.
- `Sources/AnyDoor/Services/Providers/ScheduledShutdownProvider.swift` — thin toggle adapter.
- `Sources/AnyDoor/Services/PrivilegedShutdownClient.swift` — XPC caller (forced).
- `Sources/AnyDoor/Views/ShutdownWarningView.swift` — warning SwiftUI content.
- `Sources/AnyDoor/Views/ShutdownWarningWindowController.swift` — floating NSPanel presenter.
- `Tests/AnyDoorTests/ScheduledShutdownServiceTests.swift` — service unit tests + mocks.

**Modified files**
- `Sources/AnyDoor/Models/BuiltinItem.swift` — new `.scheduledShutdown` case + switch arms.
- `Sources/AnyDoor/Services/PanelStore.swift` — state cache, subtitle, toggle special-case, duration setter, onChange, refreshAll.
- `Sources/AnyDoor/Views/MenuBarView.swift` — duration menu + row wiring.
- `Sources/AnyDoor/AppDelegate.swift` — register provider, wire onChange, bootstrap on launch.
- `Sources/AnyDoor/Utilities/L10n.swift` — new keys.
- `Sources/AnyDoor/Resources/Localizable.xcstrings` — new entries.
- `Sources/HostsHelperShared/HostsHelperProtocol.swift` — rename to `PrivilegedHelperProtocol`/`PrivilegedHelperConstants`, add `shutDown`, bump version.
- `Sources/AnyDoorHostsHelper/HostsHelperListener.swift` — implement `shutDown`, adopt renamed types.
- `Sources/AnyDoorHostsHelper/main.swift` — adopt renamed constants.
- `Sources/AnyDoor/Services/Hosts/PrivilegedHelperWriter.swift` — adopt renamed types.
- `Sources/AnyDoor/Views/GeneralSettingsView.swift` — forced toggle + lead/default settings.
- `Sources/AnyDoor/Services/SyncSettingsRegistry.swift` — whitelist config keys.
- `Sources/AnyDoor/Services/BackupService.swift` — reconcile hook.
- `CLAUDE.md`, `AGENTS.md`, `CHANGELOG.md` — docs.

**Build/test commands**
- Build: `swift build`
- All tests: `swift test`
- Single test: `swift test --filter AnyDoorTests.ScheduledShutdownServiceTests/<name>`

---

## Task 1: Domain types and the graceful executor

**Files:**
- Create: `Sources/AnyDoor/Services/ScheduledShutdown.swift`
- Test: `Tests/AnyDoorTests/ScheduledShutdownServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AnyDoorTests/ScheduledShutdownServiceTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class ScheduledShutdownServiceTests: XCTestCase {
    func testDurationSecondsFloorsAtOneMinute() {
        XCTAssertEqual(ScheduledShutdownDuration.minutes(30).seconds, 1800)
        XCTAssertEqual(ScheduledShutdownDuration.minutes(0).seconds, 60)   // floored to 1 min
        XCTAssertEqual(ScheduledShutdownDuration.minutes(-5).seconds, 60)
    }

    func testStateIsArmed() {
        XCTAssertFalse(ScheduledShutdownState.off.isArmed)
        XCTAssertTrue(ScheduledShutdownState.armed(fireDate: Date()).isArmed)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnyDoorTests.ScheduledShutdownServiceTests/testDurationSecondsFloorsAtOneMinute`
Expected: FAIL — compile error, `ScheduledShutdownDuration` not found.

- [ ] **Step 3: Write the domain types**

Create `Sources/AnyDoor/Services/ScheduledShutdown.swift`:

```swift
import Foundation

/// User-selectable countdown presets for Scheduled Shutdown.
enum ScheduledShutdownDuration: Hashable, Sendable {
    case minutes(Int)

    /// Seconds until shutdown. Floored to one minute so a stray 0 never schedules
    /// an instant fire.
    var seconds: TimeInterval {
        switch self {
        case .minutes(let m): return TimeInterval(max(1, m)) * 60
        }
    }
}

/// Public state exposed to PanelStore. `.armed` carries the absolute target so
/// the panel can render "将于 HH:mm 关机" without polling.
enum ScheduledShutdownState: Hashable, Sendable {
    case off
    case armed(fireDate: Date)

    var isArmed: Bool {
        if case .armed = self { return true }
        return false
    }
}

/// Side-effect boundary for the actual shutdown so the service is testable
/// without powering off the machine.
protocol ShutdownExecuting: Sendable {
    func shutDown(forced: Bool) async throws
}

/// Boundary for the cancelable pre-fire warning UI so the service can be tested
/// without creating a real window.
@MainActor
protocol ShutdownWarningPresenting: AnyObject {
    func present(totalSeconds: Int, onCancel: @escaping @MainActor () -> Void)
    func update(secondsRemaining: Int)
    func dismiss()
}

/// Production executor. Graceful uses System Events (Automation permission only,
/// honors unsaved-work prompts). The forced branch (privileged helper) is wired
/// in Task 12; until then both modes shut down gracefully.
struct SystemShutdownExecutor: ShutdownExecuting {
    func shutDown(forced: Bool) async throws {
        _ = try await AppleScriptRunner.run(
            "tell application \"System Events\" to shut down"
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AnyDoorTests.ScheduledShutdownServiceTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/ScheduledShutdown.swift Tests/AnyDoorTests/ScheduledShutdownServiceTests.swift
git commit -m "feat(shutdown): add scheduled-shutdown domain types and graceful executor"
```

---

## Task 2: ScheduledShutdownService — arm / cancel / fire

**Files:**
- Create: `Sources/AnyDoor/Services/ScheduledShutdownService.swift`
- Test: `Tests/AnyDoorTests/ScheduledShutdownServiceTests.swift` (append)

- [ ] **Step 1: Add mocks and failing tests**

Append to `Tests/AnyDoorTests/ScheduledShutdownServiceTests.swift`:

```swift
// MARK: - Test doubles

final class MockShutdownExecutor: ShutdownExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [Bool] = []
    var errorToThrow: Error?
    var calls: [Bool] { lock.withLock { _calls } }

    func shutDown(forced: Bool) async throws {
        if let errorToThrow { throw errorToThrow }
        lock.withLock { _calls.append(forced) }
    }
}

@MainActor
final class MockShutdownWarning: ShutdownWarningPresenting {
    var presentedSeconds: Int?
    var lastUpdate: Int?
    var dismissCount = 0
    var onCancel: (@MainActor () -> Void)?

    func present(totalSeconds: Int, onCancel: @escaping @MainActor () -> Void) {
        presentedSeconds = totalSeconds
        self.onCancel = onCancel
    }
    func update(secondsRemaining: Int) { lastUpdate = secondsRemaining }
    func dismiss() { dismissCount += 1 }
}

@MainActor
private func makeService(
    now: Date,
    executor: MockShutdownExecutor = MockShutdownExecutor(),
    warning: MockShutdownWarning = MockShutdownWarning()
) -> (ScheduledShutdownService, MockShutdownExecutor, MockShutdownWarning, UserDefaults) {
    let suite = UserDefaults(suiteName: "test.shutdown.\(UUID().uuidString)")!
    let service = ScheduledShutdownService(
        executor: executor, warning: warning, defaults: suite, now: { now }
    )
    return (service, executor, warning, suite)
}

extension ScheduledShutdownServiceTests {
    @MainActor
    func testArmPersistsFireDateAndSetsState() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (service, _, _, suite) = makeService(now: now)

        service.arm(.minutes(30))

        guard case .armed(let fireDate) = service.state else {
            return XCTFail("expected armed")
        }
        XCTAssertEqual(fireDate.timeIntervalSince1970, now.timeIntervalSince1970 + 1800, accuracy: 0.5)
        XCTAssertEqual(suite.double(forKey: "scheduledShutdown.fireDate"),
                       now.timeIntervalSince1970 + 1800, accuracy: 0.5)
    }

    @MainActor
    func testCancelClearsStateAndDefaults() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (service, _, warning, suite) = makeService(now: now)
        service.arm(.minutes(30))

        service.cancel()

        XCTAssertEqual(service.state, .off)
        XCTAssertNil(suite.object(forKey: "scheduledShutdown.fireDate"))
        XCTAssertGreaterThanOrEqual(warning.dismissCount, 1)
    }

    @MainActor
    func testPerformFireClearsStateThenExecutorRuns() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (service, executor, _, suite) = makeService(now: now)
        service.arm(.minutes(30))

        service.performFire()
        XCTAssertEqual(service.state, .off)
        XCTAssertNil(suite.object(forKey: "scheduledShutdown.fireDate"))

        await service.executeShutdown()
        XCTAssertEqual(executor.calls, [false])  // graceful by default
    }

    @MainActor
    func testForcedFlagRoutesToExecutor() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (service, executor, _, suite) = makeService(now: now)
        suite.set(true, forKey: "scheduledShutdown.forced")

        await service.executeShutdown()
        XCTAssertEqual(executor.calls, [true])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AnyDoorTests.ScheduledShutdownServiceTests/testArmPersistsFireDateAndSetsState`
Expected: FAIL — `ScheduledShutdownService` not found.

- [ ] **Step 3: Implement the service**

Create `Sources/AnyDoor/Services/ScheduledShutdownService.swift`:

```swift
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
```

> `L(.shutdownToastFailed)` is added in Task 7; `ShutdownWarningWindowController` in Task 9. The service will not COMPILE standalone yet — that is expected; it is completed by later tasks. To keep Task 2 green in isolation, temporarily stub the two missing symbols at the BOTTOM of this file and delete the stubs in their owning tasks:

```swift
// TEMP stubs — removed in Task 7 (L key) and Task 9 (window controller).
// Task 7 deletes this and adds the real L10n.Key case.
private extension L10n.Key { static var shutdownToastFailed: L10n.Key { .builtinKeepAwake } }
// Task 9 deletes this and adds the real controller.
final class ShutdownWarningWindowController: ShutdownWarningPresenting {
    func present(totalSeconds: Int, onCancel: @escaping @MainActor () -> Void) {}
    func update(secondsRemaining: Int) {}
    func dismiss() {}
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AnyDoorTests.ScheduledShutdownServiceTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/ScheduledShutdownService.swift Tests/AnyDoorTests/ScheduledShutdownServiceTests.swift
git commit -m "feat(shutdown): add ScheduledShutdownService arm/cancel/fire core"
```

---

## Task 3: Launch re-arm, missed-deadline, sleep/wake, reload

**Files:**
- Modify: `Sources/AnyDoor/Services/ScheduledShutdownService.swift`
- Test: `Tests/AnyDoorTests/ScheduledShutdownServiceTests.swift` (append)

- [ ] **Step 1: Append failing tests**

```swift
extension ScheduledShutdownServiceTests {
    @MainActor
    func testBootstrapReArmsFutureFireDate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let suite = UserDefaults(suiteName: "test.shutdown.\(UUID().uuidString)")!
        suite.set(now.timeIntervalSince1970 + 600, forKey: "scheduledShutdown.fireDate")
        let service = ScheduledShutdownService(
            executor: MockShutdownExecutor(), warning: MockShutdownWarning(),
            defaults: suite, now: { now }
        )

        service.bootstrapOnLaunch()

        guard case .armed(let fireDate) = service.state else { return XCTFail("expected armed") }
        XCTAssertEqual(fireDate.timeIntervalSince1970, now.timeIntervalSince1970 + 600, accuracy: 0.5)
    }

    @MainActor
    func testBootstrapCancelsMissedFireDateWithoutFiring() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let suite = UserDefaults(suiteName: "test.shutdown.\(UUID().uuidString)")!
        suite.set(now.timeIntervalSince1970 - 600, forKey: "scheduledShutdown.fireDate") // past
        let executor = MockShutdownExecutor()
        let service = ScheduledShutdownService(
            executor: executor, warning: MockShutdownWarning(), defaults: suite, now: { now }
        )

        service.bootstrapOnLaunch()

        XCTAssertEqual(service.state, .off)
        XCTAssertNil(suite.object(forKey: "scheduledShutdown.fireDate"))
        XCTAssertEqual(executor.calls, [])  // did NOT shut down retroactively
    }

    @MainActor
    func testHandleWakeOverdueEntersWarningFlowAndFires() {
        // fireDate is in the past relative to the wake clock → overdue → fire.
        var current = Date(timeIntervalSince1970: 1_000_000)
        let suite = UserDefaults(suiteName: "test.shutdown.\(UUID().uuidString)")!
        let executor = MockShutdownExecutor()
        let service = ScheduledShutdownService(
            executor: executor, warning: MockShutdownWarning(), defaults: suite, now: { current }
        )
        service.arm(.minutes(1))                 // fireDate = now + 60
        current = current.addingTimeInterval(120) // simulate sleeping past it

        service.handleWake()

        XCTAssertEqual(service.state, .off)       // performFire cleared state
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AnyDoorTests.ScheduledShutdownServiceTests/testBootstrapReArmsFutureFireDate`
Expected: FAIL — `bootstrapOnLaunch` not found.

- [ ] **Step 3: Add lifecycle methods**

In `ScheduledShutdownService.swift`, add these methods inside the class (e.g. after `cancel()`):

```swift
    // MARK: - Lifecycle

    /// Re-arm (or clear) from the persisted absolute target on app launch, and
    /// register the wake observer. A deadline missed while the app was quit is
    /// cancelled (never fired retroactively).
    func bootstrapOnLaunch() {
        registerWakeObserver()
        guard let fireDate = persistedFireDate() else { return }
        if fireDate.timeIntervalSince(now()) > 0 {
            armAt(fireDate: fireDate, persist: false)
        } else {
            defaults.removeObject(forKey: Self.fireDateKey)
            state = .off
            notify()
            ToastPresenter.shared.show(.failure(L(.shutdownToastMissed)))
        }
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
            MainActor.assumeIsolated { self?.handleWake() }
        }
    }

    private func persistedFireDate() -> Date? {
        guard let ts = defaults.object(forKey: Self.fireDateKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: ts)
    }
```

> `L(.shutdownToastMissed)` is added in Task 7. Add a temporary alias next to the existing temp stub at the bottom of the file so Task 3 stays green:

```swift
// TEMP — removed in Task 7.
private extension L10n.Key { static var shutdownToastMissed: L10n.Key { .builtinKeepAwake } }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AnyDoorTests.ScheduledShutdownServiceTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/ScheduledShutdownService.swift Tests/AnyDoorTests/ScheduledShutdownServiceTests.swift
git commit -m "feat(shutdown): add launch re-arm, missed-deadline and wake handling"
```

---

## Task 4: Add the `.scheduledShutdown` builtin catalog entry

**Files:**
- Modify: `Sources/AnyDoor/Models/BuiltinItem.swift`

- [ ] **Step 1: Add the enum case**

In `BuiltinItem.swift`, add `case scheduledShutdown` to the enum case list (near the other power actions, e.g. right after `case systemSleep`). The raw value is automatically `"scheduledShutdown"`.

- [ ] **Step 2: Add it to the `.toggle` group in `kind`**

Modify `BuiltinItem.swift:63-64`:

```swift
        case .keepAwake, .muteAudio, .hideDesktopIcons, .showHiddenFiles, .darkMode,
             .hideDock, .autoHideMenuBar, .keyboardLock, .scheduledShutdown: return .toggle
```

- [ ] **Step 3: Add the `titleKey` arm**

In the `titleKey` switch (near line 82), add:

```swift
        case .scheduledShutdown: return .builtinScheduledShutdown
```

- [ ] **Step 4: Add the `symbol` arm**

In the `symbol` switch (near line 132), add:

```swift
        case .scheduledShutdown: return "power"
```

- [ ] **Step 5: Add the `defaultOrder` arm**

In the `defaultOrder` switch (after `.systemSleep: return 1100`), add:

```swift
        case .scheduledShutdown: return 1200
```

- [ ] **Step 6: Build to verify exhaustiveness**

Run: `swift build`
Expected: FAIL with errors in `L10n.Key` ("type 'L10n.Key' has no member 'builtinScheduledShutdown'") — this confirms every `BuiltinItem` switch is satisfied except the not-yet-added L10n key. `defaultVisibility` needs no edit (it switches on `.kind`, and `.toggle` returns `true`). `requiresAutomation` needs no edit (defaults to `false` — graceful shutdown surfaces permission via toast, not the panel permission row).

> If `swift build` reports any *non-exhaustive switch* error referencing `.scheduledShutdown` (other than the expected `L10n.Key` member error), add the missing arm in that switch before proceeding.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Models/BuiltinItem.swift
git commit -m "feat(shutdown): add scheduledShutdown builtin catalog entry"
```

---

## Task 5: Localization keys and catalog entries

**Files:**
- Modify: `Sources/AnyDoor/Utilities/L10n.swift`
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings`
- Modify: `Sources/AnyDoor/Services/ScheduledShutdownService.swift` (delete temp stubs)

- [ ] **Step 1: Add the L10n.Key cases**

In `L10n.swift`, add these cases to the `enum Key` (keep alphabetical-ish by raw value, near the existing `builtin.*` / `panel.subtitle.*` / `settings.*` groups):

```swift
        case builtinScheduledShutdown = "builtin.scheduledShutdown"
        case panelSubtitleShutdownAt = "panel.subtitle.shutdownAt"
        case scheduledShutdownDuration15Min = "scheduledShutdown.duration.15min"
        case scheduledShutdownDuration30Min = "scheduledShutdown.duration.30min"
        case scheduledShutdownDuration1Hour = "scheduledShutdown.duration.1hour"
        case scheduledShutdownDuration2Hour = "scheduledShutdown.duration.2hour"
        case scheduledShutdownDurationCancel = "scheduledShutdown.duration.cancel"
        case scheduledShutdownDurationMenuHelp = "scheduledShutdown.duration.menuHelp"
        case shutdownToastMissed = "shutdown.toast.missed"
        case shutdownToastFailed = "shutdown.toast.failed"
        case shutdownWarningTitle = "shutdown.warning.title"
        case shutdownWarningMessage = "shutdown.warning.message"
        case shutdownWarningCancel = "shutdown.warning.cancel"
        case settingsShutdown = "settings.shutdown"
        case settingsShutdownForced = "settings.shutdown.forced"
        case settingsShutdownForcedHelp = "settings.shutdown.forcedHelp"
        case settingsShutdownWarningLead = "settings.shutdown.warningLead"
        case settingsShutdownDefaultDuration = "settings.shutdown.defaultDuration"
```

- [ ] **Step 2: Add the .xcstrings entries**

In `Localizable.xcstrings`, add these entries to the top-level `"strings"` object (follow the exact shape of the existing `builtin.keepAwake` entry):

```json
"builtin.scheduledShutdown" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Scheduled Shutdown" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "定时关机" } }
  }
},
"panel.subtitle.shutdownAt" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Shut down at %@" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "将于 %@ 关机" } }
  }
},
"scheduledShutdown.duration.15min" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "In 15 minutes" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "15 分钟后" } }
  }
},
"scheduledShutdown.duration.30min" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "In 30 minutes" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "30 分钟后" } }
  }
},
"scheduledShutdown.duration.1hour" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "In 1 hour" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "1 小时后" } }
  }
},
"scheduledShutdown.duration.2hour" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "In 2 hours" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "2 小时后" } }
  }
},
"scheduledShutdown.duration.cancel" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Cancel Shutdown" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "取消定时关机" } }
  }
},
"scheduledShutdown.duration.menuHelp" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Schedule a shutdown" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "设置定时关机" } }
  }
},
"shutdown.toast.missed" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Scheduled shutdown expired and was not run" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "定时关机计划已过期，未执行" } }
  }
},
"shutdown.toast.failed" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Scheduled shutdown failed" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "定时关机失败" } }
  }
},
"shutdown.warning.title" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Scheduled Shutdown" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "定时关机" } }
  }
},
"shutdown.warning.message" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Shutting down in %lld seconds" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "将在 %lld 秒后关机" } }
  }
},
"shutdown.warning.cancel" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Cancel" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "取消" } }
  }
},
"settings.shutdown" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Scheduled Shutdown" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "定时关机" } }
  }
},
"settings.shutdown.forced" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Force shutdown" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "强制关机" } }
  }
},
"settings.shutdown.forcedHelp" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Skip unsaved-work prompts. Requires the privileged helper." } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "跳过未保存内容提示，需要启用特权助手。" } }
  }
},
"settings.shutdown.warningLead" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Warning before shutdown (seconds)" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "关机前提醒（秒）" } }
  }
},
"settings.shutdown.defaultDuration" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Hotkey default duration (minutes)" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "热键默认时长（分钟）" } }
  }
}
```

- [ ] **Step 3: Delete the temp L10n stubs from the service**

In `ScheduledShutdownService.swift`, delete BOTH temporary `private extension L10n.Key { ... }` lines added in Tasks 2 and 3 (the `shutdownToastFailed` and `shutdownToastMissed` aliases). Keep the temporary `ShutdownWarningWindowController` stub — it is removed in Task 9.

- [ ] **Step 4: Build to verify keys resolve**

Run: `swift build`
Expected: PASS. The xcstrings plugin compiles the catalog; `L(.shutdownToastFailed)` and `.builtinScheduledShutdown` now resolve.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings Sources/AnyDoor/Services/ScheduledShutdownService.swift
git commit -m "feat(shutdown): add scheduled-shutdown localized strings"
```

---

## Task 6: ScheduledShutdownProvider + PanelStore integration

**Files:**
- Create: `Sources/AnyDoor/Services/Providers/ScheduledShutdownProvider.swift`
- Modify: `Sources/AnyDoor/Services/PanelStore.swift`

- [ ] **Step 1: Create the thin provider**

Create `Sources/AnyDoor/Services/Providers/ScheduledShutdownProvider.swift`:

```swift
import Foundation

/// Thin adapter so the panel row + global hotkey route through the standard
/// PanelStore toggle machinery. All real state lives in
/// `ScheduledShutdownService` (the MainActor brain); this provider just bridges.
actor ScheduledShutdownProvider: ToggleProvider {
    let itemKey: BuiltinItem = .scheduledShutdown
    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        await MainActor.run { ScheduledShutdownService.shared.state.isArmed }
    }

    func setState(_ enabled: Bool) async throws {
        await MainActor.run {
            if enabled {
                ScheduledShutdownService.shared.arm(
                    .minutes(ScheduledShutdownService.shared.defaultMinutes)
                )
            } else {
                ScheduledShutdownService.shared.cancel()
            }
        }
    }
}
```

- [ ] **Step 2: Add the PanelStore state cache**

In `PanelStore.swift`, after the `keepAwakeState` property (around line 47), add:

```swift
    /// Current Scheduled Shutdown state. Owns the `.armed(fireDate:)` value used
    /// by the subtitle. Pushed in via `onScheduledShutdownStateChange` from the
    /// service and from explicit mutations through `setScheduledShutdownDuration`.
    private(set) var scheduledShutdownState: ScheduledShutdownState = .off
```

- [ ] **Step 3: Add the subtitle arm**

In `PanelStore.subtitle(for:)` (around line 150), add a case before `default:`:

```swift
        case .scheduledShutdown:
            switch scheduledShutdownState {
            case .off:
                return nil
            case .armed(let fireDate):
                return L(.panelSubtitleShutdownAt, shutdownTimeString(fireDate))
            }
```

And add this helper next to `keepAwakeEndTimeString` (around line 174):

```swift
    /// Renders the shutdown target time using the app's current language. Built
    /// per call because a `DateFormatter`'s locale is frozen at construction.
    private func shutdownTimeString(_ fireDate: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = LocalizationManager.shared.effectiveLocale
        return formatter.string(from: fireDate)
    }
```

- [ ] **Step 4: Add the toggle special-case**

In `PanelStore.toggle(_:)` (after the `if item == .keepAwake { ... }` block, around line 220), add:

```swift
        if item == .scheduledShutdown {
            guard !togglesInFlight.contains(item) else { return }
            togglesInFlight.insert(item)
            defer { togglesInFlight.remove(item) }
            let armed = ScheduledShutdownService.shared.state.isArmed
            await setScheduledShutdownDuration(
                armed ? nil : .minutes(ScheduledShutdownService.shared.defaultMinutes)
            )
            return
        }
```

- [ ] **Step 5: Add the duration setter + onChange**

After `setKeepAwakeDuration` / `onKeepAwakeStateChange` (around line 265), add:

```swift
    /// Apply a Scheduled Shutdown duration (or `nil` to cancel). Caches state
    /// eagerly so the panel doesn't render a stale frame.
    func setScheduledShutdownDuration(_ duration: ScheduledShutdownDuration?) async {
        if let duration {
            ScheduledShutdownService.shared.arm(duration)
        } else {
            ScheduledShutdownService.shared.cancel()
        }
        scheduledShutdownState = ScheduledShutdownService.shared.state
        toggleStates[.scheduledShutdown] = scheduledShutdownState.isArmed
        rebuild()
    }

    /// Callback target wired into `ScheduledShutdownService.onChange`.
    func onScheduledShutdownStateChange(_ state: ScheduledShutdownState) {
        scheduledShutdownState = state
        toggleStates[.scheduledShutdown] = state.isArmed
        rebuild()
    }
```

- [ ] **Step 6: Sync state in refreshAll**

In `PanelStore.refreshAll()` (after the `keepAwakeState` pull, around line 197), add:

```swift
        scheduledShutdownState = ScheduledShutdownService.shared.state
        toggleStates[.scheduledShutdown] = scheduledShutdownState.isArmed
```

- [ ] **Step 7: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/AnyDoor/Services/Providers/ScheduledShutdownProvider.swift Sources/AnyDoor/Services/PanelStore.swift
git commit -m "feat(shutdown): wire ScheduledShutdownProvider into PanelStore"
```

---

## Task 7: AppDelegate wiring (register provider, onChange, bootstrap)

**Files:**
- Modify: `Sources/AnyDoor/AppDelegate.swift`

- [ ] **Step 1: Register the provider**

In `AppDelegate.applicationDidFinishLaunching`, add `ScheduledShutdownProvider()` to the `providers` array (after `SystemSleepProvider()`, around line 79):

```swift
            SystemSleepProvider(),
            ScheduledShutdownProvider(),
```

- [ ] **Step 2: Wire onChange + bootstrap after PanelStore.bootstrap**

Immediately after `PanelStore.shared.bootstrap(modelContainer: modelContainer, providers: providers)` (line 109), add:

```swift
        // Scheduled Shutdown: push state to the panel and re-arm any persisted
        // schedule (or cancel a deadline missed while the app was quit).
        ScheduledShutdownService.shared.onChange = { state in
            PanelStore.shared.onScheduledShutdownStateChange(state)
        }
        ScheduledShutdownService.shared.bootstrapOnLaunch()
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 4: Manual smoke test**

Run: `swift run AnyDoor`
Open the menu-bar panel. Expected: a "定时关机" row appears (a toggle row). It does nothing useful yet (the menu lands in Task 8), but it must render without crashing. Quit the app.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/AppDelegate.swift
git commit -m "feat(shutdown): register provider and bootstrap schedule on launch"
```

---

## Task 8: MenuBarView duration menu + row wiring

**Files:**
- Modify: `Sources/AnyDoor/Views/MenuBarView.swift`

- [ ] **Step 1: Add the duration menu + button helper**

In `MenuBarView.swift`, near `keepAwakeDurationMenu`, add:

```swift
    @ViewBuilder
    private var scheduledShutdownDurationMenu: some View {
        let state = panel.scheduledShutdownState
        Menu {
            scheduledShutdownDurationButton(15, titleKey: .scheduledShutdownDuration15Min)
            scheduledShutdownDurationButton(30, titleKey: .scheduledShutdownDuration30Min)
            scheduledShutdownDurationButton(60, titleKey: .scheduledShutdownDuration1Hour)
            scheduledShutdownDurationButton(120, titleKey: .scheduledShutdownDuration2Hour)
            if state.isArmed {
                Divider()
                Button(role: .destructive) {
                    Task { await panel.setScheduledShutdownDuration(nil) }
                } label: {
                    LocalizedText(.scheduledShutdownDurationCancel)
                }
            }
        } label: {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L(.scheduledShutdownDurationMenuHelp))
    }

    private func scheduledShutdownDurationButton(_ minutes: Int, titleKey: L10n.Key) -> some View {
        Button {
            Task { await panel.setScheduledShutdownDuration(.minutes(minutes)) }
        } label: {
            LocalizedText(titleKey)
        }
    }
```

- [ ] **Step 2: Add the row branch**

In `MenuBarView.rowView`, add a branch for `.scheduledShutdown` BEFORE the generic `else` (mirror the `.keepAwake` branch). Insert it right after the `if case .builtin(.keepAwake) = entry.source { ... }` block, joining as `else if`:

```swift
        } else if case .builtin(.scheduledShutdown) = entry.source {
            PanelRowView(
                entry: entry,
                onToggle: {
                    Task { await panel.toggle(.scheduledShutdown) }
                },
                onAction: {},
                onSubmenu: {},
                onPermission: openPermissionsSettings,
                trailingAccessory: AnyView(scheduledShutdownDurationMenu)
            )
        } else if case let .builtin(item) = entry.source, item.kind == .submenu {
```

> The final clause above (`else if case let .builtin(item) = ... .submenu`) is the EXISTING next branch — you are inserting your new `else if` in front of it, not replacing it.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 4: Manual smoke test (graceful end-to-end, dry-run)**

Run: `swift run AnyDoor`. Grant Accessibility if prompted. Open the panel, hover the "定时关机" row, click the clock accessory → the preset menu appears. Pick "15 分钟后". Expected: the row subtitle shows "将于 HH:mm 关机" (15 minutes ahead) and the toggle reads on. Open the menu again → "取消定时关机" appears; click it → subtitle clears, toggle off.

> Do NOT let a real shutdown fire during testing. Use the menu to cancel, or quit the app, well before any deadline. (Forced mode is not wired yet; the graceful path would otherwise trigger a real System Events shutdown at the deadline.)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/MenuBarView.swift
git commit -m "feat(shutdown): add duration menu and panel row wiring"
```

---

## Task 9: Cancelable warning window

**Files:**
- Create: `Sources/AnyDoor/Views/ShutdownWarningView.swift`
- Create: `Sources/AnyDoor/Views/ShutdownWarningWindowController.swift`
- Modify: `Sources/AnyDoor/Services/ScheduledShutdownService.swift` (delete the temp window stub)

- [ ] **Step 1: Create the SwiftUI content**

Create `Sources/AnyDoor/Views/ShutdownWarningView.swift`:

```swift
import SwiftUI

/// Compact warning shown shortly before a scheduled shutdown fires. A live
/// countdown plus a prominent Cancel button so an accidental schedule is easy
/// to abort.
struct ShutdownWarningView: View {
    let secondsRemaining: Int
    let onCancel: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "power")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.red)
            LocalizedText(.shutdownWarningTitle)
                .font(.system(size: 15, weight: .semibold))
            Text(L(.shutdownWarningMessage, secondsRemaining))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(role: .cancel) {
                onCancel()
            } label: {
                LocalizedText(.shutdownWarningCancel)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
```

- [ ] **Step 2: Create the window controller**

Create `Sources/AnyDoor/Views/ShutdownWarningWindowController.swift`:

```swift
import AppKit
import SwiftUI

/// Floating, non-activating panel that hosts `ShutdownWarningView`. Conforms to
/// `ShutdownWarningPresenting` so `ScheduledShutdownService` can show/update/
/// dismiss it without referencing AppKit directly (and tests can inject a mock).
@MainActor
final class ShutdownWarningWindowController: ShutdownWarningPresenting {
    private var panel: NSPanel?
    private var seconds: Int = 0
    private var onCancel: (@MainActor () -> Void)?

    func present(totalSeconds: Int, onCancel: @escaping @MainActor () -> Void) {
        self.seconds = totalSeconds
        self.onCancel = onCancel
        let panel = ensurePanel()
        render()
        positionCenteredTop(panel)
        panel.orderFrontRegardless()
    }

    func update(secondsRemaining: Int) {
        seconds = secondsRemaining
        render()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]
        panel = p
        return p
    }

    private func render() {
        let view = ShutdownWarningView(secondsRemaining: seconds) { [weak self] in
            self?.onCancel?()
        }
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        panel?.setContentSize(size)
        panel?.contentView = host
    }

    private func positionCenteredTop(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height - 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
```

- [ ] **Step 3: Delete the temp stub**

In `ScheduledShutdownService.swift`, delete the temporary `final class ShutdownWarningWindowController: ShutdownWarningPresenting { ... }` stub added in Task 2. The real class now lives in its own file.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 5: Run tests (ensure mocks still satisfy the protocol)**

Run: `swift test --filter AnyDoorTests.ScheduledShutdownServiceTests`
Expected: PASS (9 tests).

- [ ] **Step 6: Manual smoke test (the warning window)**

Temporarily set a short lead and short duration to see the window without waiting:
Run: `swift run AnyDoor`. In a separate terminal set a 65s lead so a 1-minute-ish flow shows the warning quickly is not possible (presets are ≥15min); instead verify visually by arming "15 分钟后" and confirming the row subtitle, then CANCEL. Full warning-window verification is exercised by Task 16's optional end-to-end check. Quit the app.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Views/ShutdownWarningView.swift Sources/AnyDoor/Views/ShutdownWarningWindowController.swift Sources/AnyDoor/Services/ScheduledShutdownService.swift
git commit -m "feat(shutdown): add cancelable pre-fire warning window"
```

---

## Task 10: Generalize the privileged helper protocol

**Files:**
- Modify: `Sources/HostsHelperShared/HostsHelperProtocol.swift`
- Modify: `Sources/AnyDoorHostsHelper/HostsHelperListener.swift`
- Modify: `Sources/AnyDoorHostsHelper/main.swift`
- Modify: `Sources/AnyDoor/Services/Hosts/PrivilegedHelperWriter.swift`

> This task renames the XPC types (cosmetic generalization) WITHOUT touching the
> Mach service name or the daemon plist name — so an already-approved helper
> needs no re-approval. The method selector `writeHosts:withReply:` is unchanged.

- [ ] **Step 1: Rename the protocol + constants and bump the version**

Replace the body of `Sources/HostsHelperShared/HostsHelperProtocol.swift` with:

```swift
import Foundation

/// Shared identifiers and the XPC contract between the AnyDoor app and the
/// privileged helper. Kept free of feature-specific logic on purpose.
public enum PrivilegedHelperConstants {
    /// Mach service name vended by the LaunchDaemon and connected to by the app.
    /// UNCHANGED across the rename so an approved helper needs no re-approval.
    public static let machServiceName = "dev.bybee.AnyDoor.HostsHelper"
    /// Upper bound on a single write payload (bytes) to bound helper memory.
    public static let maxPayloadBytes = 1_048_576  // 1 MiB
    /// Bump alongside protocol or behavior changes so the app can detect stale helpers.
    public static let helperVersion = "2"
}

/// XPC interface implemented by the root helper.
@objc public protocol PrivilegedHelperProtocol {
    /// Replace `/etc/hosts` with `content`. Replies with nil on success or an
    /// error message describing the failure.
    func writeHosts(_ content: String, withReply reply: @escaping (String?) -> Void)
    /// Returns the helper's bundle/build version for diagnostics + upgrade checks.
    func helperVersion(withReply reply: @escaping (String) -> Void)
}
```

- [ ] **Step 2: Update the helper listener**

In `Sources/AnyDoorHostsHelper/HostsHelperListener.swift`, change the type references:

- Class declaration: `HostsHelperProtocol` → `PrivilegedHelperProtocol`:
  ```swift
  final class HostsHelperListener: NSObject, NSXPCListenerDelegate, PrivilegedHelperProtocol, @unchecked Sendable {
  ```
- In `shouldAcceptNewConnection`:
  ```swift
          conn.exportedInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
  ```
- In `writeHosts` and `helperVersion`, change `HostsHelperConstants` → `PrivilegedHelperConstants`:
  ```swift
          guard content.utf8.count <= PrivilegedHelperConstants.maxPayloadBytes else {
  ```
  ```swift
          reply(PrivilegedHelperConstants.helperVersion)
  ```

- [ ] **Step 3: Update main.swift**

In `Sources/AnyDoorHostsHelper/main.swift`:

```swift
import Foundation
import HostsHelperShared

let delegate = HostsHelperListener()
let listener = NSXPCListener(machServiceName: PrivilegedHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
// On-demand: launchd starts us on connect; exit when idle.
RunLoop.current.run()
```

- [ ] **Step 4: Update PrivilegedHelperWriter**

In `Sources/AnyDoor/Services/Hosts/PrivilegedHelperWriter.swift`, change `HostsHelperConstants` → `PrivilegedHelperConstants` and `HostsHelperProtocol` → `PrivilegedHelperProtocol`:

```swift
            let conn = NSXPCConnection(machServiceName: PrivilegedHelperConstants.machServiceName,
                                       options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
```
```swift
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: HostsWriterError.writeFailed(String(describing: error)))
            } as? PrivilegedHelperProtocol
```

- [ ] **Step 5: Build the whole package (app + helper)**

Run: `swift build`
Expected: PASS. If any `HostsHelperConstants` / `HostsHelperProtocol` reference remains, the compiler will name the file + line — update it (grep: `grep -rn "HostsHelperProtocol\|HostsHelperConstants" Sources`).

- [ ] **Step 6: Run the full test suite (hosts must still pass)**

Run: `swift test`
Expected: PASS (no regressions in hosts tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/HostsHelperShared/HostsHelperProtocol.swift Sources/AnyDoorHostsHelper/HostsHelperListener.swift Sources/AnyDoorHostsHelper/main.swift Sources/AnyDoor/Services/Hosts/PrivilegedHelperWriter.swift
git commit -m "refactor(helper): generalize HostsHelperProtocol to PrivilegedHelperProtocol"
```

---

## Task 11: Add `shutDown` to the helper

**Files:**
- Modify: `Sources/HostsHelperShared/HostsHelperProtocol.swift`
- Modify: `Sources/AnyDoorHostsHelper/HostsHelperListener.swift`

- [ ] **Step 1: Add the protocol method**

In `Sources/HostsHelperShared/HostsHelperProtocol.swift`, add to `PrivilegedHelperProtocol`:

```swift
    /// Power the machine off as root. Replies with nil on success or an error
    /// message. A fixed verb — no caller-supplied arguments — so there is no
    /// command-injection surface.
    func shutDown(withReply reply: @escaping (String?) -> Void)
```

- [ ] **Step 2: Implement it in the listener**

In `Sources/AnyDoorHostsHelper/HostsHelperListener.swift`, add (after `helperVersion`):

```swift
    func shutDown(withReply reply: @escaping (String?) -> Void) {
        writeQueue.async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/sbin/shutdown")
            proc.arguments = ["-h", "now"]
            do {
                try proc.run()
                // The machine is going down; reply best-effort before exit.
                reply(nil)
            } catch {
                reply(String(describing: error))
            }
        }
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/HostsHelperShared/HostsHelperProtocol.swift Sources/AnyDoorHostsHelper/HostsHelperListener.swift
git commit -m "feat(helper): add privileged shutDown method"
```

---

## Task 12: PrivilegedShutdownClient + forced executor branch

**Files:**
- Create: `Sources/AnyDoor/Services/PrivilegedShutdownClient.swift`
- Modify: `Sources/AnyDoor/Services/ScheduledShutdown.swift`

- [ ] **Step 1: Create the XPC client**

Create `Sources/AnyDoor/Services/PrivilegedShutdownClient.swift` (modeled on `PrivilegedHelperWriter`):

```swift
import Foundation
import HostsHelperShared

/// Sends a forced-shutdown request to the root helper over XPC. Reused approval:
/// requires the same enabled LaunchDaemon as the hosts writer.
struct PrivilegedShutdownClient: Sendable {
    enum ClientError: Error { case noProxy, failed(String) }

    func shutDown() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let conn = NSXPCConnection(machServiceName: PrivilegedHelperConstants.machServiceName,
                                       options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
            conn.resume()
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: ClientError.failed(String(describing: error)))
            } as? PrivilegedHelperProtocol
            guard let proxy else {
                conn.invalidate()
                cont.resume(throwing: ClientError.noProxy)
                return
            }
            proxy.shutDown { errorMessage in
                conn.invalidate()
                if let errorMessage {
                    cont.resume(throwing: ClientError.failed(errorMessage))
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }
}
```

- [ ] **Step 2: Expand the executor to route forced**

In `Sources/AnyDoor/Services/ScheduledShutdown.swift`, replace the `SystemShutdownExecutor` graceful-only body with the full version:

```swift
struct SystemShutdownExecutor: ShutdownExecuting {
    func shutDown(forced: Bool) async throws {
        if forced {
            try await PrivilegedShutdownClient().shutDown()
        } else {
            _ = try await AppleScriptRunner.run(
                "tell application \"System Events\" to shut down"
            )
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 4: Run tests (executor routing already covered)**

Run: `swift test --filter AnyDoorTests.ScheduledShutdownServiceTests/testForcedFlagRoutesToExecutor`
Expected: PASS — confirms the `forced` flag reaches the executor (the mock asserts routing; the real `PrivilegedShutdownClient` is not exercised in unit tests since XPC needs the installed daemon).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/PrivilegedShutdownClient.swift Sources/AnyDoor/Services/ScheduledShutdown.swift
git commit -m "feat(shutdown): route forced shutdown through the privileged helper"
```

---

## Task 13: Settings UI + sync whitelist

**Files:**
- Modify: `Sources/AnyDoor/Views/GeneralSettingsView.swift`
- Modify: `Sources/AnyDoor/Services/SyncSettingsRegistry.swift`

- [ ] **Step 1: Whitelist the portable config keys**

In `SyncSettingsRegistry.entries`, add (after the `hyperKey.*` lines):

```swift
        Entry(key: "scheduledShutdown.forced", type: .bool),
        Entry(key: "scheduledShutdown.warningLeadSeconds", type: .int),
        Entry(key: "scheduledShutdown.defaultMinutes", type: .int),
```

> `scheduledShutdown.fireDate` is intentionally NOT whitelisted — it is a live,
> machine-local target, like the other deliberately-absent machine-specific keys.

- [ ] **Step 2: Add a settings Section**

In `GeneralSettingsView.swift`, add the `@AppStorage` bindings near the other ones at the top of the view struct:

```swift
    @AppStorage(ScheduledShutdownService.forcedKey) private var shutdownForced = false
    @AppStorage(ScheduledShutdownService.warningLeadKey) private var shutdownWarningLead = 60
    @AppStorage(ScheduledShutdownService.defaultMinutesKey) private var shutdownDefaultMinutes = 30
```

And add a Section to the form body (place it after an existing section; match the surrounding section idiom):

```swift
                Section {
                    Toggle(isOn: $shutdownForced) {
                        VStack(alignment: .leading, spacing: 2) {
                            LocalizedText(.settingsShutdownForced)
                            LocalizedText(.settingsShutdownForcedHelp)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: shutdownForced) { _, isOn in
                        // Forced needs the privileged helper. Guide the user to
                        // enable it if it isn't already.
                        if isOn, HelperManager.shared.readiness() != .enabled {
                            _ = HelperManager.shared.ensureRegistered()
                            if HelperManager.shared.readiness() == .requiresApproval {
                                HelperManager.shared.openApprovalSettings()
                            }
                        }
                    }
                    Stepper(value: $shutdownWarningLead, in: 0...300, step: 15) {
                        Text(L(.settingsShutdownWarningLead) + ": \(shutdownWarningLead)")
                    }
                    Stepper(value: $shutdownDefaultMinutes, in: 5...240, step: 5) {
                        Text(L(.settingsShutdownDefaultDuration) + ": \(shutdownDefaultMinutes)")
                    }
                } header: {
                    LocalizedText(.settingsShutdown)
                }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 4: Manual smoke test**

Run: `swift run AnyDoor`. Open Settings → General. Expected: a "定时关机" section with the Force toggle, warning-lead stepper, and default-duration stepper. Toggling Force on when the helper isn't enabled opens System Settings → Login Items (helper approval). Quit.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/GeneralSettingsView.swift Sources/AnyDoor/Services/SyncSettingsRegistry.swift
git commit -m "feat(shutdown): add settings (forced/lead/default) and sync whitelist"
```

---

## Task 14: Backup reconcile hook

**Files:**
- Modify: `Sources/AnyDoor/Services/BackupService.swift`

- [ ] **Step 1: Add the reconcile call**

In `BackupService.reconcileAfterImport()` (around line 141), add before `PanelStore.shared.rebuild()`:

```swift
        ScheduledShutdownService.shared.reloadFromDefaults()
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/BackupService.swift
git commit -m "feat(shutdown): re-arm schedule after backup import"
```

---

## Task 15: Documentation

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `CLAUDE.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Changelog**

Under the `## [Unreleased]` heading in `CHANGELOG.md`, add (create an `### Added` subsection if the convention there uses one; otherwise match the existing entry style):

```markdown
- Scheduled Shutdown: arm a one-shot countdown to shut the Mac down, with a cancelable pre-fire warning, graceful or optional forced shutdown, and the schedule surviving relaunch.
```

- [ ] **Step 2: CLAUDE.md + AGENTS.md**

In BOTH `CLAUDE.md` and `AGENTS.md` (they must stay in sync — `AGENTS.md` opens with a "mirrors CLAUDE.md" comment), add a bullet to the Architecture Notes describing Scheduled Shutdown. Suggested text:

```markdown
- **Scheduled Shutdown**: `ScheduledShutdownService` (`@MainActor`, like HyperKey/CommandPalette) owns a one-shot schedule — it persists the absolute target `Date` (`scheduledShutdown.fireDate`), re-arms on launch (cancelling a deadline missed while quit), re-validates on `NSWorkspace.didWakeNotification`, and shows a cancelable floating-`NSPanel` warning (`ShutdownWarningWindowController`) before firing. A thin `ScheduledShutdownProvider` (`ToggleProvider`) plugs into the panel/hotkey path; `PanelStore` mirrors its Keep Awake plumbing (`scheduledShutdownState`, `setScheduledShutdownDuration`, `onScheduledShutdownStateChange`). Execution goes through `ShutdownExecuting`: graceful via `AppleScriptRunner` (System Events, Automation permission), forced via the privileged helper. The hosts XPC contract was generalized from `HostsHelperProtocol` to `PrivilegedHelperProtocol` (`shutDown` method added; Mach service + plist names unchanged so no re-approval). Config (`forced`/`warningLeadSeconds`/`defaultMinutes`) is portable via `SyncSettingsRegistry`; the live `fireDate` is machine-local.
```

Also update the privileged-helper bullet's protocol name reference (`HostsHelperProtocol` → `PrivilegedHelperProtocol`) where it appears in the helper/XPC note.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md CLAUDE.md AGENTS.md
git commit -m "docs(shutdown): document scheduled shutdown feature"
```

---

## Task 16: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Clean build**

Run: `swift build`
Expected: PASS, no warnings introduced by this feature.

- [ ] **Step 2: Full test suite**

Run: `swift test`
Expected: PASS — all tests including the 9 `ScheduledShutdownServiceTests` and the existing hosts/keepAwake suites.

- [ ] **Step 3: Grep for leftover temp stubs / old type names**

Run: `grep -rn "TEMP" Sources/AnyDoor/Services/ScheduledShutdownService.swift; grep -rn "HostsHelperProtocol\|HostsHelperConstants" Sources`
Expected: no output (all temp stubs deleted; no old XPC type names remain).

- [ ] **Step 4: Manual smoke (graceful, real fire — optional, destructive)**

Only if you want to verify a real shutdown: set the default duration to 5 minutes and the warning lead to 240 seconds in Settings, arm via the menu, confirm the warning window appears ~4 minutes in with a live countdown and a working Cancel. CANCEL it — do not let it fire unless you intend to shut down. Confirm cancel clears the row subtitle.

- [ ] **Step 5: Finish the branch**

Use the superpowers:finishing-a-development-branch skill to decide merge/PR. The work is on `feat/scheduled-shutdown`.

---

## Self-Review (completed by plan author)

**Spec coverage:** countdown presets (T8), graceful + forced (T1/T11/T12), cancelable warning (T9), absolute-Date persistence + launch re-arm (T2/T3), sleep/wake (T3), missed-deadline cancel (T3), panel/subtitle/hotkey (T4/T6/T7/T8), helper generalization + no re-approval (T10/T11), permissions handled via toast (T2), localization (T5), backup/sync (T13/T14), docs (T15). All spec sections map to a task.

**Placeholder scan:** The only "TEMP"/stub markers are explicitly introduced and explicitly deleted within the plan (T2→T5 for L keys, T2→T9 for the window controller); T16 Step 3 greps to confirm none remain. No "TBD"/"handle edge cases"/"similar to" placeholders.

**Type consistency:** `ScheduledShutdownDuration.minutes`, `ScheduledShutdownState.off/.armed(fireDate:)`, `ShutdownExecuting.shutDown(forced:)`, `ShutdownWarningPresenting.present(totalSeconds:onCancel:)/update(secondsRemaining:)/dismiss()`, `ScheduledShutdownService.arm/cancel/performFire/executeShutdown/beginWarning/handleWake/bootstrapOnLaunch/reloadFromDefaults`, `PanelStore.scheduledShutdownState/setScheduledShutdownDuration/onScheduledShutdownStateChange`, `PrivilegedHelperProtocol.shutDown(withReply:)`, `PrivilegedShutdownClient.shutDown()`, the four `ScheduledShutdownService.*Key` statics — all used consistently across tasks.
