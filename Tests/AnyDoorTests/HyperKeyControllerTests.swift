import XCTest
@testable import AnyDoor

final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    var responses: [CommandResult] = []
    var calls: [(path: String, args: [String])] = []

    func run(_ path: String, args: [String], timeout: TimeInterval) async throws -> CommandResult {
        calls.append((path, args))
        if responses.isEmpty {
            return CommandResult(stdout: "", stderr: "no response", exitCode: 1)
        }
        return responses.removeFirst()
    }
}

final class HyperKeyControllerTests: XCTestCase {
    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "hyperKey.ownedSignatures")
    }

    func testApplyOnEmptySystem() async throws {
        let runner = FakeCommandRunner()
        runner.responses = [
            CommandResult(stdout: "(null)\n", stderr: "", exitCode: 0),
            CommandResult(stdout: "", stderr: "", exitCode: 0),
        ]
        let controller = HyperKeyController(runner: runner)
        let sig = try await controller.apply(trigger: .capsLock, virtualKey: .f19)
        XCTAssertEqual(sig.src, 0x07_0000_0039)
        XCTAssertEqual(sig.dst, 0x07_0000_0068)
        XCTAssertTrue(controller.hasPersistedSignatures)
    }

    func testGetFailureDoesNotInvokeSet() async throws {
        let runner = FakeCommandRunner()
        runner.responses = [
            CommandResult(stdout: "", stderr: "boom", exitCode: 1),
        ]
        let controller = HyperKeyController(runner: runner)
        do {
            _ = try await controller.apply(trigger: .capsLock, virtualKey: .f19)
            XCTFail("expected throw")
        } catch HyperKeyError.hidutilFailed {
            XCTAssertEqual(runner.calls.count, 1)
        }
    }

    func testApplyPersistsOldAndNewBeforeRMW() async throws {
        let runner = FakeCommandRunner()
        runner.responses = [
            // first apply: GET (empty) + SET (ok)
            CommandResult(stdout: "(null)\n", stderr: "", exitCode: 0),
            CommandResult(stdout: "", stderr: "", exitCode: 0),
            // second apply: GET (has first sig) + SET (fails) + revert GET + revert SET
            CommandResult(stdout: "(\n  {\n    HIDKeyboardModifierMappingSrc = 30064771129;\n    HIDKeyboardModifierMappingDst = 30064771176;\n  }\n)\n", stderr: "", exitCode: 0),
            CommandResult(stdout: "", stderr: "rmw failed", exitCode: 1),
            CommandResult(stdout: "(\n  {\n    HIDKeyboardModifierMappingSrc = 30064771146;\n    HIDKeyboardModifierMappingDst = 30064771176;\n  }\n)\n", stderr: "", exitCode: 0),
            CommandResult(stdout: "", stderr: "", exitCode: 0),
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

    func testClearWithEmptyOwnedIsNoOp() async throws {
        let runner = FakeCommandRunner()
        let controller = HyperKeyController(runner: runner)
        try await controller.clear()
        XCTAssertEqual(runner.calls.count, 0)
    }
}
