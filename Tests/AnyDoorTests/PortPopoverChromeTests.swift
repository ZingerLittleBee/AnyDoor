import XCTest
@testable import AnyDoor

final class PortPopoverChromeTests: XCTestCase {
    @MainActor
    func testPortRowsDoNotRenderAsIndividualGlassCards() async {
        let inventory = PortInventory(
            scanner: StubScanner(records: sampleRecords(count: 1)),
            defaults: isolatedDefaults()
        )
        await inventory.refresh()

        let row = PortRowView(record: inventory.filteredRecords[0], inventory: inventory)
        let bodyType = String(reflecting: type(of: row.body))

        XCTAssertFalse(bodyType.contains("GlassEffect"), bodyType)
    }

    @MainActor
    func testPortListRowsDoNotInstallSeparateDividersBetweenGlassRows() async {
        let inventory = PortInventory(
            scanner: StubScanner(records: sampleRecords(count: 2)),
            defaults: isolatedDefaults()
        )
        await inventory.refresh()

        let bodyType = String(reflecting: type(of: PortListView(inventory: inventory).body))

        XCTAssertFalse(bodyType.contains("Divider"), bodyType)
    }

    @MainActor
    func testPortTreeGroupsDoNotInstallSeparateDividersBetweenGlassRows() async {
        let inventory = PortInventory(
            scanner: StubScanner(records: sampleRecords(count: 2)),
            defaults: isolatedDefaults()
        )
        await inventory.refresh()

        let bodyType = String(reflecting: type(of: PortTreeView(inventory: inventory).body))

        XCTAssertFalse(bodyType.contains("Divider"), bodyType)
    }

    private struct StubScanner: PortScanning {
        let records: [PortRecord]

        func scanTCPListening() async throws -> [PortRecord] {
            records
        }

        func kill(pid: pid_t, signal: Int32) -> SignalResult {
            .success
        }
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "PortPopoverChromeTests-\(UUID().uuidString)")!
    }

    private func sampleRecords(count: Int) -> [PortRecord] {
        (0..<count).map { index in
            PortRecord(
                port: UInt16(3000 + index),
                pid: pid_t(100 + index),
                processName: "process-\(index)",
                executablePath: nil,
                commandLine: nil,
                binds: [PortBind(address: "*", family: .ipv4)]
            )
        }
    }
}
