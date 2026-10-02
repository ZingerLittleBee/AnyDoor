import XCTest
@testable import AnyDoor

private let shell = "/bin/sh"
private let sleepTool = "/bin/sleep"
private let trueTool = "/usr/bin/true"

/// Drives `LsofRunner` with real child processes it spawns itself. Every run
/// goes through `bounded(within:)`, because a regressed runner can block a
/// thread forever and the test has to fail instead of hanging.
final class LsofRunnerTests: XCTestCase {

    func testWatchdogTerminatesAChildThatOutlivesItsTimeout() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await bounded(within: 10) {
            try await LsofRunner().run(path: sleepTool, args: ["30"], timeout: .milliseconds(300))
        }
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exit, SIGTERM)
        XCTAssertGreaterThanOrEqual(clock.now - start, .milliseconds(300), "the watchdog fired early")
    }

    /// The child closes stdout and stderr, then exits later. EOF must not end the
    /// run: the result carries the real exit status, not a timeout. The runner
    /// used to cancel its watchdog at EOF, and the cancelled watchdog still saw
    /// the child running, so it reported a timeout and killed the child. Its
    /// `waitUntilExit()` after EOF could also block forever.
    func testChildThatClosesItsOutputBeforeExitingReportsItsRealExit() async throws {
        let result = try await bounded(within: 10) {
            try await LsofRunner().run(
                path: shell, args: ["-c", "exec >&- 2>&-; sleep 0.3; exit 7"], timeout: .seconds(10)
            )
        }
        XCTAssertEqual(result, SubprocessResult(stdout: "", stderr: "", exit: 7, timedOut: false))
    }

    /// EOF arrives at once, but the child keeps running: the watchdog must stay
    /// armed and end it at the deadline, not at EOF.
    func testWatchdogStillGuardsAChildThatClosedItsOutput() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await bounded(within: 10) {
            try await LsofRunner().run(
                path: shell, args: ["-c", "exec >&- 2>&-; exec sleep 30"], timeout: .milliseconds(300)
            )
        }
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exit, SIGTERM)
        XCTAssertGreaterThanOrEqual(clock.now - start, .milliseconds(300), "the child was killed at EOF")
    }

    /// Normal exits racing the watchdog's cancellation. The runner used to
    /// report some normal exits as timed out, and a `waitUntilExit()` after EOF
    /// hung within a few dozen runs.
    func testFastExitsNeverHangOrReportATimeout() async throws {
        let results = try await bounded(within: 30) {
            var results: [SubprocessResult] = []
            for _ in 0..<200 {
                results.append(try await LsofRunner().run(path: trueTool, args: [], timeout: .seconds(10)))
            }
            return results
        }
        XCTAssertEqual(results.filter(\.timedOut).count, 0, "normal exits reported as timed out")
        XCTAssertEqual(results.filter { $0.exit != 0 }.count, 0)
    }

    /// Cancelling the calling task terminates the child and throws
    /// `CancellationError` instead of returning the SIGTERM exit. The cancel
    /// waits until the child has signalled that it runs, so it exercises the
    /// termination rather than the check before the launch. The child would
    /// sleep for 30 seconds within its 60-second timeout, so finishing within
    /// the bound means the cancellation killed it.
    func testCancellationTerminatesTheChildAndThrowsCancellationError() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("lsofrunner-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let path = marker.path
        do {
            _ = try await bounded(within: 5, cancelWhen: { FileManager.default.fileExists(atPath: path) }) {
                try await LsofRunner().run(
                    path: shell, args: ["-c", "touch \"$1\"; exec sleep 30", "sh", path], timeout: .seconds(60)
                )
            }
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }
}
