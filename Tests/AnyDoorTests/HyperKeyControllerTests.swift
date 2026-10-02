import XCTest
@testable import AnyDoor

final class FakeSubprocessRunner: SubprocessRunning, @unchecked Sendable {
    var responses: [SubprocessResult] = []
    var calls: [(executableURL: URL, arguments: [String])] = []

    func run(_ executableURL: URL, arguments: [String], timeout: Duration?) async throws -> SubprocessResult {
        // Like ProcessRunner, a cancelled caller gets CancellationError and
        // nothing runs.
        try Task.checkCancellation()
        calls.append((executableURL, arguments))
        if responses.isEmpty {
            return SubprocessResult(stdout: "", stderr: "no response", exit: 1, timedOut: false)
        }
        return responses.removeFirst()
    }
}

final class HyperKeyControllerTests: XCTestCase {
    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "hyperKey.ownedSignatures")
    }

    func testApplyOnEmptySystem() async throws {
        let runner = FakeSubprocessRunner()
        runner.responses = [
            SubprocessResult(stdout: "(null)\n", stderr: "", exit: 0, timedOut: false),
            SubprocessResult(stdout: "", stderr: "", exit: 0, timedOut: false),
        ]
        let controller = HyperKeyController(runner: runner)
        let sig = try await controller.apply(trigger: .capsLock, virtualKey: .f19)
        XCTAssertEqual(sig.src, HyperKeyTrigger.capsLock.hidUsage!)
        XCTAssertEqual(sig.dst, HyperKeyVirtualKey.f19.hidUsage)
        XCTAssertTrue(controller.hasPersistedSignatures)
    }

    func testGetFailureDoesNotInvokeSet() async throws {
        let runner = FakeSubprocessRunner()
        runner.responses = [
            SubprocessResult(stdout: "", stderr: "boom", exit: 1, timedOut: false),
        ]
        let controller = HyperKeyController(runner: runner)
        do {
            _ = try await controller.apply(trigger: .capsLock, virtualKey: .f19)
            XCTFail("expected throw")
        } catch HyperKeyError.hidutilFailed {
            XCTAssertEqual(runner.calls.count, 1)
        }
    }

    func testGetFailureRollsBackPersistedOwnership() async throws {
        let runner = FakeSubprocessRunner()
        runner.responses = [
            // first apply: GET (empty) + SET (ok)
            SubprocessResult(stdout: "(null)\n", stderr: "", exit: 0, timedOut: false),
            SubprocessResult(stdout: "", stderr: "", exit: 0, timedOut: false),
            // second apply: GET fails — hidutil never mutated, no SET
            SubprocessResult(stdout: "", stderr: "boom", exit: 1, timedOut: false),
        ]
        let controller = HyperKeyController(runner: runner)
        let first = try await controller.apply(trigger: .capsLock, virtualKey: .f19)

        do {
            _ = try await controller.apply(trigger: .leftControl, virtualKey: .f19)
            XCTFail("expected throw")
        } catch {
            // A failed GET means hidutil is unchanged, so the pre-persisted signature
            // must be rolled back to the prior state — not left dangling.
            let data = UserDefaults.standard.data(forKey: "hyperKey.ownedSignatures")!
            let set = try JSONDecoder().decode(OwnedSignatures.self, from: data)
            XCTAssertEqual(set, [first])
        }
    }

    func testApplyRevertsPersistedSetOnSetFailure() async throws {
        let runner = FakeSubprocessRunner()
        runner.responses = [
            // first apply: GET (empty) + SET (ok)
            SubprocessResult(stdout: "(null)\n", stderr: "", exit: 0, timedOut: false),
            SubprocessResult(stdout: "", stderr: "", exit: 0, timedOut: false),
            // second apply: GET (has first sig) + SET (fails) + revert GET + revert SET
            SubprocessResult(stdout: "(\n  {\n    HIDKeyboardModifierMappingSrc = 30064771129;\n    HIDKeyboardModifierMappingDst = 30064771176;\n  }\n)\n", stderr: "", exit: 0, timedOut: false),
            SubprocessResult(stdout: "", stderr: "rmw failed", exit: 1, timedOut: false),
            SubprocessResult(stdout: "(\n  {\n    HIDKeyboardModifierMappingSrc = 30064771146;\n    HIDKeyboardModifierMappingDst = 30064771176;\n  }\n)\n", stderr: "", exit: 0, timedOut: false),
            SubprocessResult(stdout: "", stderr: "", exit: 0, timedOut: false),
        ]
        let controller = HyperKeyController(runner: runner)
        let first = try await controller.apply(trigger: .capsLock, virtualKey: .f19)

        do {
            _ = try await controller.apply(trigger: .leftControl, virtualKey: .f19)
            XCTFail("expected throw")
        } catch {
            let data = UserDefaults.standard.data(forKey: "hyperKey.ownedSignatures")!
            let set = try JSONDecoder().decode(OwnedSignatures.self, from: data)
            XCTAssertEqual(set, [first])
        }
    }

    /// A GET the runner had to terminate is a timeout, not a hidutil failure
    /// carrying the killed child's status, and it never reaches SET.
    func testTimedOutGetThrowsTimeoutWithoutInvokingSet() async throws {
        let runner = FakeSubprocessRunner()
        runner.responses = [
            SubprocessResult(stdout: "", stderr: "", exit: SIGTERM, timedOut: true),
        ]
        let controller = HyperKeyController(runner: runner)
        do {
            _ = try await controller.apply(trigger: .capsLock, virtualKey: .f19)
            XCTFail("expected throw")
        } catch HyperKeyError.timeout {
            XCTAssertEqual(runner.calls.count, 1)
            XCTAssertFalse(controller.hasPersistedSignatures)
        }
    }

    /// A SET that timed out may already have changed the mapping, so it throws
    /// `.timeout` and still takes the revert path.
    func testTimedOutSetThrowsTimeoutAndRevertsTheMapping() async throws {
        let runner = FakeSubprocessRunner()
        runner.responses = [
            // GET (empty) + SET (timed out) + revert GET + revert SET
            SubprocessResult(stdout: "(null)\n", stderr: "", exit: 0, timedOut: false),
            SubprocessResult(stdout: "", stderr: "", exit: SIGTERM, timedOut: true),
            SubprocessResult(stdout: "(null)\n", stderr: "", exit: 0, timedOut: false),
            SubprocessResult(stdout: "", stderr: "", exit: 0, timedOut: false),
        ]
        let controller = HyperKeyController(runner: runner)
        do {
            _ = try await controller.apply(trigger: .capsLock, virtualKey: .f19)
            XCTFail("expected throw")
        } catch HyperKeyError.timeout {
            XCTAssertEqual(runner.calls.count, 4, "a timed-out SET must be reverted")
            XCTAssertFalse(controller.hasPersistedSignatures)
        }
    }

    func testClearWithEmptyOwnedIsNoOp() async throws {
        let runner = FakeSubprocessRunner()
        let controller = HyperKeyController(runner: runner)
        try await controller.clear()
        XCTAssertEqual(runner.calls.count, 0)
    }
}
