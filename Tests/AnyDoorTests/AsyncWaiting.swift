import XCTest

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
