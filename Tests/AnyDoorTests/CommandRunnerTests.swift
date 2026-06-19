import XCTest
@testable import AnyDoor

final class CommandRunnerTests: XCTestCase {

    /// stdout larger than the OS pipe buffer (~64KB) must stream out while the
    /// child runs. Draining the pipes only after the process exits deadlocks the
    /// child on write() once a buffer fills, tripping the timeout. Regression for
    /// that deadlock (same drain-after-exit shape as ShellRunner).
    func testLargeStdoutDoesNotDeadlock() async throws {
        let size = 512 * 1024  // well above the ~64KB pipe buffer
        let payload = String(repeating: "a", count: size)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmdrunner-large-\(UUID().uuidString).txt")
        try payload.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try await DefaultCommandRunner().run("/bin/cat", args: [tmp.path], timeout: 5)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, size, "expected the full \(size)-byte stdout, got \(result.stdout.count)")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    /// A child that outlives the deadline must make run() throw `.timeout`
    /// promptly. The timeout branch awaits the drain readers, so terminate()
    /// must close the child's write ends (→ EOF) and let those reads resolve —
    /// guarding against the await itself hanging.
    func testTimeoutThrowsPromptlyWithoutHanging() async {
        let start = Date()
        do {
            _ = try await DefaultCommandRunner().run("/bin/sleep", args: ["10"], timeout: 0.5)
            XCTFail("expected a timeout error for a child that outlives the deadline")
        } catch {
            XCTAssertTrue(error is HyperKeyError, "expected HyperKeyError.timeout, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5,
                          "timeout path must not hang awaiting the drain readers")
    }
}
