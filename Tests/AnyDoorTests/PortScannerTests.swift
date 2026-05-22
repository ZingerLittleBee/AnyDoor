import XCTest
@testable import AnyDoor

final class PortScannerTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "txt") else {
            XCTFail("fixture \(name).txt not found in test bundle")
            throw XCTSkip("missing fixture")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParseSingleIPv4Listener() throws {
        let raw = try fixture("lsof-single-ipv4")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.pid, 67035)
        XCTAssertEqual(r.port, 3000)
        XCTAssertEqual(r.processName, "node")
        XCTAssertEqual(r.binds, [PortBind(address: "*", family: .ipv4)])
    }

    func testParseMultiPort() throws {
        let raw = try fixture("lsof-multi-port")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map(\.port), [80, 443, 5432])
        for r in records { XCTAssertEqual(r.pid, 898); XCTAssertEqual(r.processName, "OrbStack Helper") }
    }

    func testParseDualStackMergesBinds() throws {
        let raw = try fixture("lsof-dual-stack")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.pid, 75837)
        XCTAssertEqual(r.port, 5000)
        XCTAssertEqual(r.binds.count, 2)
        XCTAssertEqual(Set(r.binds.map(\.family)), Set([.ipv4, .ipv6]))
        // Ordering: IPv4 first then IPv6 (sorted by rawValue).
        XCTAssertEqual(r.binds.map(\.family), [.ipv4, .ipv6])
    }

    func testParseMultiBindSamePort() throws {
        let raw = try fixture("lsof-multi-bind")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.binds.count, 2)
        XCTAssertEqual(Set(r.binds.map(\.address)), Set(["127.0.0.1", "0.0.0.0"]))
    }

    func testParseIPv6ZoneId() throws {
        let raw = try fixture("lsof-ipv6-zone")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.port, 1234)
        XCTAssertEqual(r.binds, [PortBind(address: "fe80::1%en0", family: .ipv6)])
    }

    func testParseCommandWithSpaces() throws {
        let raw = try fixture("lsof-command-spaces")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].processName, "Google Chrome Helper")
    }

    func testParseEscapeSequence() throws {
        let raw = try fixture("lsof-escape")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].processName, "weird name")
    }

    // Stub runner used to exercise scanner branches without spawning lsof.
    private struct StubRunner: SubprocessRunning {
        let result: SubprocessResult
        func run(path: String, args: [String], timeout: Duration) async throws -> SubprocessResult {
            result
        }
    }

    func testScanEmptyResultExit1BothStreamsEmpty() async throws {
        let scanner = PortScanner(runner: StubRunner(
            result: SubprocessResult(stdout: "", stderr: "", exit: 1, timedOut: false)
        ))
        let records = try await scanner.scanTCPListening()
        XCTAssertEqual(records, [])
    }

    func testScanExit1WithStderrIsFailure() async {
        let scanner = PortScanner(runner: StubRunner(
            result: SubprocessResult(stdout: "", stderr: "lsof: permission denied\n", exit: 1, timedOut: false)
        ))
        do {
            _ = try await scanner.scanTCPListening()
            XCTFail("expected lsofFailed")
        } catch let PortScanError.lsofFailed(code, stderr) {
            XCTAssertEqual(code, 1)
            XCTAssertTrue(stderr.contains("permission denied"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testScanTimeoutThrowsRegardlessOfExit() async {
        let scanner = PortScanner(runner: StubRunner(
            result: SubprocessResult(stdout: "anything", stderr: "", exit: 0, timedOut: true)
        ))
        do {
            _ = try await scanner.scanTCPListening()
            XCTFail("expected lsofTimeout")
        } catch PortScanError.lsofTimeout {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testLsofRunnerThrowsCancellationInsteadOfExit15WhenTaskIsCancelled() async {
        let runner = LsofRunner()
        let task = Task {
            try await runner.run(path: "/bin/sleep", args: ["5"], timeout: .seconds(10))
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testScanSuccessfulParse() async throws {
        let raw = try fixture("lsof-single-ipv4")
        let scanner = PortScanner(runner: StubRunner(
            result: SubprocessResult(stdout: raw, stderr: "", exit: 0, timedOut: false)
        ))
        let records = try await scanner.scanTCPListening()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].port, 3000)
    }
}
