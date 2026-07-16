import XCTest
import PluginInterface
@testable import AnyDoor

final class ShellRunnerTests: XCTestCase {

    /// An explicit short timeout still terminates a long-running process.
    func testExplicitTimeoutKillsLongProcess() async {
        do {
            _ = try await ShellRunner.run("/bin/sleep", args: ["2"], timeout: 0.3)
            XCTFail("expected the watchdog to terminate the process")
        } catch BuiltinError.shellFailed(_, let output) {
            XCTAssertTrue(output.contains("timeout"), "got: \(output)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A nil timeout disables the watchdog: the same 1s process that an explicit
    /// 0.3s timeout would kill now runs to completion.
    func testNilTimeoutDoesNotKillProcess() async throws {
        let start = Date()
        _ = try await ShellRunner.run("/bin/sleep", args: ["1"], timeout: nil)
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

        let output = try await ShellRunner.run("/bin/cat", args: [tmp.path], timeout: 5)
        XCTAssertEqual(output.count, size, "expected the full \(size)-byte output, got \(output.count)")
    }
}
