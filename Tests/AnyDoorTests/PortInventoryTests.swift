import XCTest
@testable import AnyDoor

final class PortInventoryTests: XCTestCase {
    func testBuiltinItemPortManagerExists() {
        XCTAssertTrue(BuiltinItem.allCases.contains(.portManager))
        XCTAssertEqual(BuiltinItem.portManager.kind, .submenu)
        XCTAssertEqual(BuiltinItem.portManager.title, "端口管理")
        XCTAssertEqual(BuiltinItem.portManager.symbol, "network")
    }

    func testPortRecordIdComposition() {
        let r = PortRecord(
            port: 3000,
            pid: 67035,
            processName: "node",
            executablePath: nil,
            commandLine: nil,
            binds: [PortBind(address: "*", family: .ipv4)]
        )
        XCTAssertEqual(r.id, "67035-3000")
    }

    func testSignalResultEquatable() {
        XCTAssertEqual(SignalResult.success, SignalResult.success)
        XCTAssertEqual(SignalResult.failure(.EPERM), SignalResult.failure(.EPERM))
        XCTAssertNotEqual(SignalResult.success, SignalResult.failure(.EPERM))
    }

    func testSubprocessResultStruct() {
        let r = SubprocessResult(
            stdout: "out", stderr: "err", exit: 0, timedOut: false
        )
        XCTAssertEqual(r.stdout, "out")
        XCTAssertEqual(r.stderr, "err")
        XCTAssertEqual(r.exit, 0)
        XCTAssertFalse(r.timedOut)
    }

    @MainActor
    func testViewModeDefaultsToList() {
        let defaults = isolatedDefaults()
        let inventory = PortInventory(
            scanner: StubScanner(records: []),
            defaults: defaults
        )
        XCTAssertEqual(inventory.viewMode, .list)
    }

    @MainActor
    func testViewModePersistsToDefaults() {
        let defaults = isolatedDefaults()
        let inventory = PortInventory(
            scanner: StubScanner(records: []),
            defaults: defaults
        )
        inventory.viewMode = .tree

        // New instance reads back the persisted value.
        let inventory2 = PortInventory(
            scanner: StubScanner(records: []),
            defaults: defaults
        )
        XCTAssertEqual(inventory2.viewMode, .tree)
    }

    // Test helpers
    private struct StubScanner: PortScanning {
        let records: [PortRecord]
        var killBehavior: @Sendable (pid_t, Int32) -> SignalResult = { _, _ in .success }
        func scanTCPListening() async throws -> [PortRecord] { records }
        func kill(pid: pid_t, signal: Int32) -> SignalResult { killBehavior(pid, signal) }
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "PortInventoryTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }
}
