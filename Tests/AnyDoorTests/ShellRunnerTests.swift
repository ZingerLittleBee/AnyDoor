import XCTest
import PluginInterface
@testable import AnyDoor

/// `ShellRunner` adapts `ProcessRunner` to the providers' `String` result and
/// `BuiltinError`; these runs pin that mapping with real child processes. Every
/// run is bounded so a regressed runner fails the test instead of hanging it.
final class ShellRunnerTests: XCTestCase {

    /// Success returns stdout alone. The Bluetooth battery probe parses it as
    /// JSON, which fails when stderr text is mixed in.
    func testSuccessReturnsStdoutWithoutStderr() async throws {
        let output = try await bounded(within: 10) {
            try await ShellRunner.run("/bin/sh", args: ["-c", "printf '{}'; printf 'warning' >&2"])
        }
        XCTAssertEqual(output, "{}")
    }

    /// A non-zero exit throws, which the providers' `try` relies on to abort a
    /// toggle, carrying the exit code and stdout followed by stderr.
    func testNonZeroExitThrowsShellFailedWithStdoutThenStderr() async throws {
        do {
            _ = try await bounded(within: 10) {
                try await ShellRunner.run("/bin/sh", args: ["-c", "printf out; printf err >&2; exit 3"])
            }
            XCTFail("expected shellFailed")
        } catch BuiltinError.shellFailed(let code, let output) {
            XCTAssertEqual(code, 3)
            XCTAssertEqual(output, "outerr")
        }
    }

    /// An explicit timeout still terminates a long-running process, and the error
    /// keeps its shape: code -1 and the output so far behind "timeout: ". The
    /// child prints at once; the 2-second budget leaves a loaded machine ample
    /// time to do that before the watchdog fires.
    func testExplicitTimeoutKillsLongProcess() async throws {
        do {
            _ = try await bounded(within: 10) {
                try await ShellRunner.run("/bin/sh", args: ["-c", "printf partial; exec sleep 30"], timeout: 2)
            }
            XCTFail("expected the watchdog to terminate the process")
        } catch BuiltinError.shellFailed(let code, let output) {
            XCTAssertEqual(code, -1)
            XCTAssertEqual(output, "timeout: partial")
        }
    }

    /// A launch failure must not be a `BuiltinError`: `RegionCapture` swallows
    /// `shellFailed` as a possibly cancelled selection, and a tool that could not
    /// run has to reach the user as a failure instead.
    func testLaunchFailureThrowsSpawnFailedRatherThanShellFailed() async throws {
        do {
            _ = try await bounded(within: 10) {
                try await ShellRunner.run("/nonexistent/anydoor-test-tool")
            }
            XCTFail("expected spawnFailed")
        } catch SubprocessError.spawnFailed {
            // expected
        }
    }

    /// A nil timeout disables the watchdog: the same 1s process that an explicit
    /// 0.3s timeout would kill now runs to completion.
    func testNilTimeoutDoesNotKillProcess() async throws {
        let start = Date()
        _ = try await bounded(within: 10) {
            try await ShellRunner.run("/bin/sleep", args: ["1"], timeout: nil)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 0.8, "process should have run for ~1s, not been killed early")
    }

    /// Output larger than the OS pipe buffer (~64KB) must stream out while the
    /// child runs. Draining the pipe only after the process exits deadlocks the
    /// child on write() once the buffer fills, tripping the timeout watchdog.
    /// Regression for that deadlock (it broke the system_profiler battery probe).
    func testLargeOutputDoesNotDeadlock() async throws {
        let size = 512 * 1024  // well above the ~64KB pipe buffer
        let payload = String(repeating: "a", count: size)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shellrunner-large-\(UUID().uuidString).txt")
        try payload.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let path = tmp.path
        let output = try await bounded(within: 10) {
            try await ShellRunner.run("/bin/cat", args: [path], timeout: 5)
        }
        XCTAssertEqual(output.count, size, "expected the full \(size)-byte output, got \(output.count)")
    }
}
