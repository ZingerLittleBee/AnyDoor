import XCTest
import os

/// Polls `condition` until it holds, failing the test if `timeout` lapses first.
/// A synchronous closure converts implicitly, so both `{ flag }` and
/// `{ await actor.count == 2 }` are accepted.
///
/// Prefer this over sleeping for a fixed margin before a positive assertion. A
/// fixed sleep encodes a deadline the machine may miss under load (a loaded CI
/// runner overran an 80ms wait on a 16ms debounce), and the resulting failure
/// reads as a flake rather than a real signal. Waiting on the effect keeps the
/// assertion meaningful: a condition that never holds still fails, just later.
///
/// Assertions of the "must NOT happen" kind are the deliberate exception —
/// those need a bounded wait, and a slow machine only makes them more
/// conservative.
@MainActor
func waitUntil(
    _ description: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () async -> Bool
) async {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if await !condition() {
        XCTFail("timed out after \(timeout)s waiting for \(description)", file: file, line: line)
    }
}

/// Thrown by `bounded(within:cancelWhen:_:)` once it has recorded the failure,
/// so the test stops at the call that hung.
struct BoundedWaitTimedOut: Error {}

/// Runs `operation` in its own task and waits at most `timeout` for its result,
/// rethrowing what it threw.
///
/// Use this where a regression would block a thread outright (a subprocess wait,
/// for instance) rather than just never satisfy a condition. The bound must not
/// depend on the operation honoring cancellation, so a hang abandons the stuck
/// task, fails the test, and throws `BoundedWaitTimedOut` instead of blocking
/// CI. For an operation whose cancellation is under test, `cancelWhen` cancels
/// the task once that condition first holds; the same bound covers the wait
/// for it.
func bounded<T: Sendable>(
    within timeout: TimeInterval,
    cancelWhen shouldCancel: (@Sendable () -> Bool)? = nil,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let deadline = ContinuousClock.now + .seconds(timeout)
    let outcome = OSAllocatedUnfairLock<Result<T, any Error>?>(initialState: nil)
    let task = Task {
        let result: Result<T, any Error>
        do { result = .success(try await operation()) } catch { result = .failure(error) }
        outcome.withLock { $0 = result }
    }
    var cancelPending = shouldCancel != nil
    while ContinuousClock.now < deadline {
        if let result = outcome.withLock({ $0 }) { return try result.get() }
        if cancelPending, shouldCancel?() == true {
            task.cancel()
            cancelPending = false
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if let result = outcome.withLock({ $0 }) { return try result.get() }
    XCTFail("timed out after \(timeout)s; the operation never finished", file: file, line: line)
    throw BoundedWaitTimedOut()
}
