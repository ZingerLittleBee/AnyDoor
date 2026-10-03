import XCTest
import SwiftData
import PluginInterface
@testable import AnyDoor

/// Backend that fails the first N acquires, then behaves normally. Lets tests
/// exercise the IOPM-failure path without touching real power management.
final class ThrowingKeepAwakeBackend: KeepAwakeBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _isHeld = false
    private var _remainingFailures: Int
    private(set) var acquireAttempts = 0

    init(failuresBeforeSuccess: Int) {
        self._remainingFailures = failuresBeforeSuccess
    }

    var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isHeld
    }

    func acquire() throws {
        lock.lock(); defer { lock.unlock() }
        acquireAttempts += 1
        if _isHeld { return }
        if _remainingFailures > 0 {
            _remainingFailures -= 1
            throw BuiltinError.ioKitFailed(-1)
        }
        _isHeld = true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        guard _isHeld else { return }
        _isHeld = false
    }
}

/// In-memory backend that counts acquire/release calls. Lets us assert the
/// provider holds at most one assertion at a time and never leaks across mode
/// changes or manual disable.
final class MockKeepAwakeBackend: KeepAwakeBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _isHeld = false
    private var _acquireCount = 0
    private var _releaseCount = 0

    var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isHeld
    }
    var acquireCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _acquireCount
    }
    var releaseCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _releaseCount
    }

    func acquire() throws {
        lock.lock(); defer { lock.unlock() }
        if _isHeld { return }
        _isHeld = true
        _acquireCount += 1
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        guard _isHeld else { return }
        _isHeld = false
        _releaseCount += 1
    }
}

final class KeepAwakeProviderTests: XCTestCase {

    func testApplyIndefiniteAcquiresAndReportsOn() async throws {
        let backend = MockKeepAwakeBackend()
        let provider = KeepAwakeProvider(backend: backend)

        try await provider.apply(.indefinite)

        let state = await provider.currentState
        XCTAssertEqual(state, .indefinite)
        XCTAssertTrue(backend.isHeld)
        XCTAssertEqual(backend.acquireCount, 1)
        XCTAssertEqual(backend.releaseCount, 0)

        let isOn = try await provider.readState()
        XCTAssertTrue(isOn)
    }

    func testApplyTimedSchedulesEndDateAndHoldsAssertion() async throws {
        let backend = MockKeepAwakeBackend()
        let provider = KeepAwakeProvider(backend: backend)

        let before = Date()
        try await provider.apply(.minutes(15))
        let after = Date()

        let state = await provider.currentState
        guard case .timed(let endDate) = state else {
            return XCTFail("expected .timed state, got \(state)")
        }
        // End-date should be ~15 minutes after the apply call. Allow a wide
        // band so the assertion never races with scheduler latency in CI.
        let expectedMin = before.addingTimeInterval(15 * 60 - 2)
        let expectedMax = after.addingTimeInterval(15 * 60 + 2)
        XCTAssertGreaterThanOrEqual(endDate, expectedMin)
        XCTAssertLessThanOrEqual(endDate, expectedMax)
        XCTAssertTrue(backend.isHeld)
        XCTAssertEqual(backend.acquireCount, 1)
    }

    func testSwitchingDurationReplacesPriorScheduleWithoutLeakingAssertion() async throws {
        let backend = MockKeepAwakeBackend()
        let provider = KeepAwakeProvider(backend: backend)

        try await provider.apply(.minutes(60))
        try await provider.apply(.minutes(15))
        try await provider.apply(.indefinite)

        let state = await provider.currentState
        XCTAssertEqual(state, .indefinite)
        XCTAssertTrue(backend.isHeld)
        // The assertion stayed held continuously across the three mode
        // changes — acquire should only have been called once and release
        // never (idempotent acquire when already held).
        XCTAssertEqual(backend.acquireCount, 1, "switching mode should not stack assertions")
        XCTAssertEqual(backend.releaseCount, 0, "switching mode must not release the held assertion")
    }

    func testApplyNilReleasesAndReturnsToOff() async throws {
        let backend = MockKeepAwakeBackend()
        let provider = KeepAwakeProvider(backend: backend)

        try await provider.apply(.minutes(30))
        XCTAssertTrue(backend.isHeld)

        try await provider.apply(nil)

        let state = await provider.currentState
        XCTAssertEqual(state, .off)
        XCTAssertFalse(backend.isHeld)
        XCTAssertEqual(backend.acquireCount, 1)
        XCTAssertEqual(backend.releaseCount, 1)
    }

    func testExpirationReleasesAssertionAndFiresOnChange() async throws {
        let backend = MockKeepAwakeBackend()

        // Track state transitions delivered through the MainActor callback.
        // Using an actor-bound class avoids Sendable warnings on a mutable
        // captured array.
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var states: [KeepAwakeState] = []
            func append(_ s: KeepAwakeState) {
                lock.lock(); defer { lock.unlock() }
                states.append(s)
            }
            func snapshot() -> [KeepAwakeState] {
                lock.lock(); defer { lock.unlock() }
                return states
            }
        }
        let recorder = Recorder()

        let provider = KeepAwakeProvider(
            backend: backend,
            onChange: { state in recorder.append(state) }
        )

        try await provider.apply(.minutes(30))
        // Simulate the timer firing without waiting half an hour.
        await provider.handleExpiration()

        let state = await provider.currentState
        XCTAssertEqual(state, .off, "expiration should drop state back to off")
        XCTAssertFalse(backend.isHeld, "expiration must release the assertion")
        XCTAssertEqual(backend.releaseCount, 1, "expiration must release exactly once")

        let observed = recorder.snapshot()
        XCTAssertTrue(observed.contains(.off), "onChange should have reported the off transition")
        if case .timed = observed.first {
            // OK — first event was the timed state.
        } else {
            XCTFail("first onChange should have reported the timed state, got \(observed)")
        }
    }

    func testManualDisableCancelsPendingExpirationSoLaterFireIsNoOp() async throws {
        let backend = MockKeepAwakeBackend()
        let provider = KeepAwakeProvider(backend: backend)

        try await provider.apply(.minutes(45))
        try await provider.apply(nil)
        // Simulate a stale timer callback firing after manual disable. The
        // provider must ignore it because state is already .off — otherwise
        // a second release would double-decrement the (imaginary) counter
        // and a state change would re-fire.
        await provider.handleExpiration()

        let state = await provider.currentState
        XCTAssertEqual(state, .off)
        XCTAssertEqual(backend.releaseCount, 1, "stale expiration callback must not re-release")
    }

    func testToggleProviderConformanceUsesIndefiniteOnEnable() async throws {
        let backend = MockKeepAwakeBackend()
        let provider = KeepAwakeProvider(backend: backend)

        // PanelStore.toggle bypasses setState (it calls apply through
        // setKeepAwakeDuration), so this pins the conformance on its own.
        try await provider.setState(true)
        var state = await provider.currentState
        XCTAssertEqual(state, .indefinite)

        try await provider.setState(false)
        state = await provider.currentState
        XCTAssertEqual(state, .off)
        XCTAssertFalse(backend.isHeld)
    }

    func testApplyThrowsLeavesStateOffWhenAcquireFailsFromOff() async throws {
        let backend = ThrowingKeepAwakeBackend(failuresBeforeSuccess: 1)
        let provider = KeepAwakeProvider(backend: backend)

        // First apply hits the throwing backend. State must remain .off so
        // the UI doesn't claim an assertion is held that the system rejected.
        do {
            try await provider.apply(.indefinite)
            XCTFail("expected acquire to throw on first call")
        } catch {
            // expected
        }

        let state = await provider.currentState
        XCTAssertEqual(state, .off, "failed acquire must leave state at .off")
        XCTAssertFalse(backend.isHeld)

        // Recovery: a follow-up apply with the same duration succeeds because
        // the mock is configured to fail only the first attempt.
        try await provider.apply(.indefinite)
        let recovered = await provider.currentState
        XCTAssertEqual(recovered, .indefinite)
        XCTAssertTrue(backend.isHeld)
    }

    @MainActor
    func testPanelStoreSetKeepAwakeDurationResyncsCacheOnAcquireFailure() async throws {
        // Bootstrap a fresh PanelStore with a throwing provider so we can
        // assert the catch path pulls the provider's real state into the
        // cache instead of leaving an optimistically-written value behind.
        // The store records its notice instead of opening the toast window.
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self,
            configurations: config
        )
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)

        let backend = ThrowingKeepAwakeBackend(failuresBeforeSuccess: 1)
        let provider = KeepAwakeProvider(backend: backend)
        var toasts: [ToastStyle] = []
        let store = PanelStore(presentToast: { toasts.append($0) })
        store.bootstrap(modelContainer: container, providers: [provider])

        // Drive a failing turn-on through the public mutation path.
        await store.setKeepAwakeDuration(.indefinite)

        XCTAssertEqual(store.keepAwakeState, .off,
                       "catch branch must resync cache with provider's true state")

        let keepAwakeEntry = store.topLevelEntries.first { entry in
            if case .builtin(.keepAwake) = entry.source { return true } else { return false }
        }
        XCTAssertEqual(keepAwakeEntry?.toggleState, false,
                       "panel row must not render as on after a rejected acquire")

        // A duration choice reports the failure once, naming the command.
        guard toasts.count == 1, case .failure(let message) = toasts.first else {
            return XCTFail("expected exactly one failure notice, got \(toasts.map(\.message))")
        }
        XCTAssertEqual(message, L(.toastCommandFailed, L(.builtinKeepAwake)))
    }

    @MainActor
    func testPanelStoreToggleTurnsKeepAwakeOnIndefinitelyAndOff() async throws {
        // Behavior preservation: the row and its hotkey switch Keep Awake on
        // with the same `switchOnDuration` as `setState`
        // (testToggleProviderConformanceUsesIndefiniteOnEnable).
        let backend = MockKeepAwakeBackend()
        let provider = KeepAwakeProvider(backend: backend)
        let store = try makePanelLaneTestStore(rows: [.keepAwake], providers: [provider])

        await store.toggle(.keepAwake)
        XCTAssertEqual(store.keepAwakeState, .indefinite)
        XCTAssertTrue(backend.isHeld)

        await store.toggle(.keepAwake)
        XCTAssertEqual(store.keepAwakeState, .off)
        XCTAssertFalse(backend.isHeld)
    }

    func testSwitchingFromTimedToIndefiniteThenExpirationNoOp() async throws {
        let backend = MockKeepAwakeBackend()
        let provider = KeepAwakeProvider(backend: backend)

        try await provider.apply(.minutes(15))
        try await provider.apply(.indefinite)
        // If a stale expiration task somehow survived the mode switch and
        // fired here, the guard inside `handleExpiration` should still
        // protect the indefinite assertion.
        await provider.handleExpiration()

        let state = await provider.currentState
        XCTAssertEqual(state, .indefinite)
        XCTAssertTrue(backend.isHeld, "indefinite assertion must survive a stale timer callback")
    }

    // MARK: - Presets and the end-time subtitle

    func testTimedPresetsRunFromFifteenMinutesToTwelveHours() {
        XCTAssertEqual(KeepAwakePreset.timed.map(\.minutes), [15, 30, 60, 120, 240, 480, 720])
        XCTAssertEqual(
            Set(KeepAwakePreset.timed.map(\.titleKey)).count,
            KeepAwakePreset.timed.count,
            "each preset needs its own title"
        )
    }

    func testTwelveHourPresetSchedulesEndDateTwelveHoursOut() async throws {
        let backend = MockKeepAwakeBackend()
        let provider = KeepAwakeProvider(backend: backend)
        let preset = try XCTUnwrap(KeepAwakePreset.timed.last)

        let before = Date()
        try await provider.apply(preset.duration)
        let after = Date()
        addTeardownBlock { try? await provider.apply(nil) }

        let state = await provider.currentState
        guard case .timed(let endDate) = state else {
            return XCTFail("expected .timed state, got \(state)")
        }
        XCTAssertGreaterThanOrEqual(endDate, before.addingTimeInterval(12 * 3600 - 2))
        XCTAssertLessThanOrEqual(endDate, after.addingTimeInterval(12 * 3600 + 2))
        XCTAssertTrue(backend.isHeld)
    }

    @MainActor
    func testUntilSubtitleNamesTomorrowOnlyAfterMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let evening = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 4, hour: 20
        )))
        let sameDay = evening.addingTimeInterval(2 * 3600)
        let nextDay = evening.addingTimeInterval(8 * 3600)

        let previous = LocalizationManager.shared.preference
        defer { LocalizationManager.shared.preference = previous }
        for language in [LanguagePreference.en, .zh] {
            LocalizationManager.shared.preference = language
            XCTAssertEqual(
                PanelStore.keepAwakeUntilSubtitle(endDate: sameDay, now: evening, calendar: calendar, time: "T"),
                L(.panelSubtitleKeepAwakeUntil, "T")
            )
            XCTAssertEqual(
                PanelStore.keepAwakeUntilSubtitle(endDate: nextDay, now: evening, calendar: calendar, time: "T"),
                L(.panelSubtitleKeepAwakeUntilTomorrow, "T")
            )
        }
        LocalizationManager.shared.preference = .en
        XCTAssertEqual(
            PanelStore.keepAwakeUntilSubtitle(endDate: nextDay, now: evening, calendar: calendar, time: "4:00 AM"),
            "Awake until 4:00 AM tomorrow"
        )
        LocalizationManager.shared.preference = .zh
        XCTAssertEqual(
            PanelStore.keepAwakeUntilSubtitle(endDate: nextDay, now: evening, calendar: calendar, time: "04:00"),
            "保持至明天 04:00"
        )
    }
}
