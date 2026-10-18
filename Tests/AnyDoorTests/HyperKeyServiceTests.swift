import XCTest
import AppKit
@testable import AnyDoor

@MainActor
final class HyperKeyServiceTests: XCTestCase {
    func testFlagsWhenInactive() {
        let s = HyperKeyService(defaults: makeTemporaryDefaults())
        XCTAssertEqual(s.hyperModifierFlags, 0)
        XCTAssertEqual(s.virtualKeyCode, -1)
    }

    func testIncludeShiftDefaultTrue() {
        let s = HyperKeyService(defaults: makeTemporaryDefaults())
        XCTAssertTrue(s.includeShift)
    }

    func testPersistedSettingsRoundTrip() async {
        let defaults = makeTemporaryDefaults()
        defaults.set("capsLock", forKey: "hyperKey.trigger")
        defaults.set("escape", forKey: "hyperKey.quickPress")
        defaults.set(false, forKey: "hyperKey.includeShift")
        let s = HyperKeyService(defaults: defaults)
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
        let suite = makeTemporaryDefaultsSuite()
        let controller = HyperKeyController(runner: runner, defaultsSuiteName: suite.name)
        try await controller.apply(trigger: .capsLock, virtualKey: .f19)
        XCTAssertTrue(controller.hasPersistedSignatures)

        let defaults = suite.makeDefaults()
        let service = HyperKeyService(defaults: defaults, controller: controller)

        let reload = Task { await service.reloadFromDefaults() }
        reload.cancel()
        await reload.value

        XCTAssertNil(service.lastError)
        XCTAssertFalse(controller.hasPersistedSignatures, "the owned mapping was never cleared")
        XCTAssertEqual(runner.calls.count, 4)
    }
}
