import AppKit
import SwiftUI
import XCTest
@testable import AnyDoor

final class PortManagerPopoverViewTests: XCTestCase {
    @MainActor
    func testPortManagerPopoverUsesFixedHeightAcrossContentStates() async {
        let emptyInventory = PortInventory(
            scanner: StubScanner(records: []),
            defaults: isolatedDefaults()
        )

        let populatedInventory = PortInventory(
            scanner: StubScanner(records: sampleRecords(count: 16)),
            defaults: isolatedDefaults()
        )
        await populatedInventory.refresh()

        XCTAssertEqual(
            fittingSize(for: emptyInventory).height,
            560,
            accuracy: 0.5
        )
        XCTAssertEqual(
            fittingSize(for: populatedInventory).height,
            560,
            accuracy: 0.5
        )
    }

    @MainActor
    private func fittingSize(for inventory: PortInventory) -> NSSize {
        let view = PortManagerPopoverView(
            inventory: inventory,
            onHoverChange: { _ in },
            onClose: {}
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.sizingOptions = .intrinsicContentSize
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize
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
        UserDefaults(suiteName: "PortManagerPopoverViewTests-\(UUID().uuidString)")!
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
