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

        // performFire() kicks off the shutdown on its own Task; await exactly
        // that task rather than calling executeShutdown() again (which would
        // double-count the executor invocation).
        await service.fireTask?.value
        XCTAssertEqual(executor.calls, [false])  // graceful by default, fired once
    }

    @MainActor
    func testForcedFlagRoutesToExecutor() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (service, executor, _, suite) = makeService(now: now)
        suite.set(true, forKey: "scheduledShutdown.forced")

        await service.executeShutdown()
        XCTAssertEqual(executor.calls, [true])
    }

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
    func testHandleWakeOverduePresentsCancelableWarningInsteadOfFiringImmediately() {
        // The deadline lapsed while the Mac slept. The shutdown must NOT fire
        // instantly with no warning — it must re-anchor a short cancelable grace.
        var current = Date(timeIntervalSince1970: 1_000_000)
        let suite = UserDefaults(suiteName: "test.shutdown.\(UUID().uuidString)")!
        let executor = MockShutdownExecutor()
        let warning = MockShutdownWarning()
        let service = ScheduledShutdownService(
            executor: executor, warning: warning, defaults: suite, now: { current }
        )
        service.arm(.minutes(1))                 // fireDate = now + 60
        current = current.addingTimeInterval(120) // simulate sleeping past it

        service.handleWake()

        XCTAssertNotNil(warning.presentedSeconds, "an overdue wake must show a cancelable warning")
        XCTAssertGreaterThan(warning.presentedSeconds ?? 0, 0)
        XCTAssertTrue(service.state.isArmed, "should re-arm a grace window, not fire immediately")
        XCTAssertNil(service.fireTask, "no shutdown should be kicked off during the grace window")
        XCTAssertEqual(executor.calls, [], "must not shut down before the grace window elapses")
    }

    @MainActor
    func testHandleWakeOverdueGraceWarningIsCancelable() {
        var current = Date(timeIntervalSince1970: 1_000_000)
        let suite = UserDefaults(suiteName: "test.shutdown.\(UUID().uuidString)")!
        let executor = MockShutdownExecutor()
        let warning = MockShutdownWarning()
        let service = ScheduledShutdownService(
            executor: executor, warning: warning, defaults: suite, now: { current }
        )
        service.arm(.minutes(1))
        current = current.addingTimeInterval(120)
        service.handleWake()

        warning.onCancel?()                      // user cancels during the grace window

        XCTAssertEqual(service.state, .off)
        XCTAssertNil(suite.object(forKey: "scheduledShutdown.fireDate"))
        XCTAssertEqual(executor.calls, [], "cancelling the grace warning aborts the shutdown")
    }
}
