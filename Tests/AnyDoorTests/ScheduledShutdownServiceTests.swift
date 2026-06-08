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
