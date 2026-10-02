import XCTest
import PluginInterface
@testable import AnyDoor

/// Drives `LockScreenProvider`'s strategy order through its injected inputs.
/// Every test replaces all of them, so none runs `CGSession` or calls the real
/// `SACLockScreenImmediate`, and none locks the session.
final class LockScreenProviderTests: XCTestCase {

    /// The strategy steps the provider took, in order. The provider calls its
    /// inputs from its own actor, so access is serialized with a lock.
    private final class StepLog: @unchecked Sendable {
        enum Step: Equatable {
            case cgSession
            case immediateLock
            case failureToast
        }

        private let lock = NSLock()
        private var steps: [Step] = []

        func record(_ step: Step) {
            lock.lock(); defer { lock.unlock() }
            steps.append(step)
        }

        var snapshot: [Step] {
            lock.lock(); defer { lock.unlock() }
            return steps
        }
    }

    /// - Parameters:
    ///   - cgSessionError: Thrown by the `CGSession -suspend` run; `nil` succeeds.
    ///   - immediateLockStatus: What `SACLockScreenImmediate` returns; `nil`
    ///     stands for a symbol that can't be resolved.
    private func makeProvider(
        log: StepLog,
        cgSessionExists: Bool,
        cgSessionError: (any Error)? = nil,
        immediateLockStatus: Int32?
    ) -> LockScreenProvider {
        LockScreenProvider(
            cgSessionExists: { cgSessionExists },
            runCGSession: {
                log.record(.cgSession)
                if let cgSessionError { throw cgSessionError }
            },
            lockImmediately: {
                log.record(.immediateLock)
                return immediateLockStatus
            },
            presentFailure: { log.record(.failureToast) }
        )
    }

    func testCGSessionSuccessDoesNotUseImmediateLock() async {
        let log = StepLog()
        let provider = makeProvider(log: log, cgSessionExists: true, immediateLockStatus: 0)

        await provider.run()

        XCTAssertEqual(log.snapshot, [.cgSession])
    }

    func testMissingCGSessionLocksImmediately() async {
        let log = StepLog()
        let provider = makeProvider(log: log, cgSessionExists: false, immediateLockStatus: 0)

        await provider.run()

        XCTAssertEqual(log.snapshot, [.immediateLock], "a missing tool must not be launched")
    }

    func testFailedCGSessionFallsBackToImmediateLock() async {
        let log = StepLog()
        let provider = makeProvider(
            log: log,
            cgSessionExists: true,
            cgSessionError: BuiltinError.shellFailed(code: 1, output: ""),
            immediateLockStatus: 0
        )

        await provider.run()

        XCTAssertEqual(log.snapshot, [.cgSession, .immediateLock])
    }

    func testUnavailableImmediateLockShowsFailureToast() async {
        let log = StepLog()
        let provider = makeProvider(log: log, cgSessionExists: false, immediateLockStatus: nil)

        await provider.run()

        XCTAssertEqual(log.snapshot, [.immediateLock, .failureToast])
    }

    func testNonZeroImmediateLockStatusShowsFailureToast() async {
        let log = StepLog()
        let provider = makeProvider(log: log, cgSessionExists: false, immediateLockStatus: 22)

        await provider.run()

        XCTAssertEqual(log.snapshot, [.immediateLock, .failureToast])
    }

    /// A launch failure (any error other than `shellFailed`) also falls back,
    /// and with no immediate lock either, the user gets the toast.
    func testCGSessionLaunchFailureWithoutImmediateLockShowsFailureToast() async {
        let log = StepLog()
        let provider = makeProvider(
            log: log,
            cgSessionExists: true,
            cgSessionError: CocoaError(.fileReadNoPermission),
            immediateLockStatus: nil
        )

        await provider.run()

        XCTAssertEqual(log.snapshot, [.cgSession, .immediateLock, .failureToast])
    }
}
