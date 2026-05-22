import XCTest
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
}
