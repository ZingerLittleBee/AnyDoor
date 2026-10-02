import XCTest
@testable import AnyDoor

private let shell = URL(fileURLWithPath: "/bin/sh")
private let sleepTool = URL(fileURLWithPath: "/bin/sleep")
private let trueTool = URL(fileURLWithPath: "/usr/bin/true")

/// Drives `ProcessRunner` with real child processes it spawns itself. Every run
/// goes through `bounded(within:)`, because a regressed runner can block a
/// thread forever and the test has to fail instead of hanging.
final class ProcessRunnerTests: XCTestCase {

    func testCapturesStdoutAndStderrSeparatelyWithTheExitStatus() async throws {
        let result = try await bounded(within: 10) {
            try await ProcessRunner().run(
                shell, arguments: ["-c", "printf out; printf err >&2; exit 3"], timeout: .seconds(10)
            )
        }
        XCTAssertEqual(result, SubprocessResult(stdout: "out", stderr: "err", exit: 3, timedOut: false))
    }

    /// Output larger than the OS pipe buffer (~64KB) on either stream must flow
    /// out while the child runs. Draining a pipe only after the exit would block
    /// the child on write() once that buffer fills.
    func testLargeOutputOnBothStreamsDoesNotDeadlock() async throws {
        let size = 512 * 1024  // well above the ~64KB pipe buffer
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("processrunner-large-\(UUID().uuidString).txt")
        try String(repeating: "a", count: size).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let path = file.path
        let result = try await bounded(within: 20) {
            try await ProcessRunner().run(
                shell, arguments: ["-c", "cat \"$1\"; cat \"$1\" >&2", "sh", path], timeout: .seconds(15)
            )
        }
        XCTAssertEqual(result.exit, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.count, size, "expected the full \(size)-byte stdout")
        XCTAssertEqual(result.stderr.count, size, "expected the full \(size)-byte stderr")
    }

    func testMissingExecutableThrowsSpawnFailed() async throws {
        do {
            _ = try await bounded(within: 10) {
                try await ProcessRunner().run(
                    URL(fileURLWithPath: "/nonexistent/anydoor-test-tool"), arguments: [], timeout: .seconds(5)
                )
            }
            XCTFail("expected spawnFailed")
        } catch SubprocessError.spawnFailed {
            // expected
        }
    }

    func testWatchdogTerminatesAChildThatOutlivesItsTimeout() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await bounded(within: 10) {
            try await ProcessRunner().run(sleepTool, arguments: ["30"], timeout: .milliseconds(300))
        }
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exit, SIGTERM)
        XCTAssertGreaterThanOrEqual(clock.now - start, .milliseconds(300), "the watchdog fired early")
    }

    /// The child closes stdout and stderr, then exits later. EOF must not end the
    /// run: the result carries the real exit status, not a timeout. The old lsof
    /// runner cancelled its watchdog at EOF, and the cancelled watchdog still saw
    /// the child running, so it reported a timeout and killed the child. Its
    /// `waitUntilExit()` after EOF could also block forever.
    func testChildThatClosesItsOutputBeforeExitingReportsItsRealExit() async throws {
        let result = try await bounded(within: 10) {
            try await ProcessRunner().run(
                shell, arguments: ["-c", "exec >&- 2>&-; sleep 0.3; exit 7"], timeout: .seconds(10)
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
            try await ProcessRunner().run(
                shell, arguments: ["-c", "exec >&- 2>&-; exec sleep 30"], timeout: .milliseconds(300)
            )
        }
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exit, SIGTERM)
        XCTAssertGreaterThanOrEqual(clock.now - start, .milliseconds(300), "the child was killed at EOF")
    }

    /// Normal exits racing the watchdog's cancellation. With the old lsof runner,
    /// a run of fast children reported some normal exits as timed out, and a
    /// `waitUntilExit()` after EOF hung within a few dozen runs.
    func testFastExitsNeverHangOrReportATimeout() async throws {
        let results = try await bounded(within: 30) {
            var results: [SubprocessResult] = []
            for _ in 0..<200 {
                results.append(try await ProcessRunner().run(trueTool, arguments: [], timeout: .seconds(10)))
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
    /// sleep for 30 seconds without a timeout, so finishing within the bound
    /// means the cancellation killed it.
    func testCancellationTerminatesTheChildAndThrowsCancellationError() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("processrunner-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let path = marker.path
        do {
            _ = try await bounded(within: 5, cancelWhen: { FileManager.default.fileExists(atPath: path) }) {
                try await ProcessRunner().run(
                    shell, arguments: ["-c", "touch \"$1\"; exec sleep 30", "sh", path], timeout: nil
                )
            }
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }
}
