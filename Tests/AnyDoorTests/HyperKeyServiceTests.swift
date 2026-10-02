import XCTest
import AppKit
@testable import AnyDoor

@MainActor
final class HyperKeyServiceTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "hyperKey.trigger")
        UserDefaults.standard.removeObject(forKey: "hyperKey.quickPress")
        UserDefaults.standard.removeObject(forKey: "hyperKey.includeShift")
        UserDefaults.standard.removeObject(forKey: "hyperKey.ownedSignatures")
    }

    func testFlagsWhenInactive() {
        let s = HyperKeyService()
        XCTAssertEqual(s.hyperModifierFlags, 0)
        XCTAssertEqual(s.virtualKeyCode, -1)
    }

    func testIncludeShiftDefaultTrue() {
        let s = HyperKeyService()
        XCTAssertTrue(s.includeShift)
    }

    func testPersistedSettingsRoundTrip() async {
        UserDefaults.standard.set("capsLock", forKey: "hyperKey.trigger")
        UserDefaults.standard.set("escape", forKey: "hyperKey.quickPress")
        UserDefaults.standard.set(false, forKey: "hyperKey.includeShift")
        let s = HyperKeyService()
        XCTAssertEqual(s.trigger, .capsLock)
        XCTAssertEqual(s.quickPress, .escape)
        XCTAssertFalse(s.includeShift)
    }

    /// Config Sync reloads the settings from a periodic tick that stopping sync
    /// cancels, and the runner fails a cancelled caller instead of running
    /// hidutil. The reload must keep that cancellation away from hidutil, or
    /// drive() records it as a hidutil failure (and a set trigger is reset).
    func testCancelledReloadStillConvergesTheMapping() async throws {
        let runner = FakeSubprocessRunner()
        runner.responses = [
            // apply: GET (empty) + SET (ok), leaving an owned mapping behind
            SubprocessResult(stdout: "(null)\n", stderr: "", exit: 0, timedOut: false),
            SubprocessResult(stdout: "", stderr: "", exit: 0, timedOut: false),
            // the reload, with no trigger, clears it: GET + SET
            SubprocessResult(stdout: "(null)\n", stderr: "", exit: 0, timedOut: false),
            SubprocessResult(stdout: "", stderr: "", exit: 0, timedOut: false),
        ]
        let controller = HyperKeyController(runner: runner)
        try await controller.apply(trigger: .capsLock, virtualKey: .f19)
        XCTAssertTrue(controller.hasPersistedSignatures)

        let suite = "HyperKeyServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let service = HyperKeyService(defaults: defaults, controller: controller)

        let reload = Task { await service.reloadFromDefaults() }
        reload.cancel()
        await reload.value

        XCTAssertNil(service.lastError)
        XCTAssertFalse(controller.hasPersistedSignatures, "the owned mapping was never cleared")
        XCTAssertEqual(runner.calls.count, 4)
    }
}
