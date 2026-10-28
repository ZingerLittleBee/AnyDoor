import Foundation
import XCTest
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

final class ClipboardHistorySyncTests: XCTestCase {
    func testNewDeviceStartsDisabledAndKeepsLocalHistoryUsable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-sync-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: root,
            keyStore: SyncTestLocalKeyStore()
        ))
        let captured = try await module.capture(ClipboardHistoryCaptureRequest(
            source: .unknown, content: .text("local only")
        ))
        let status = await module.syncStatus()
        XCTAssertEqual(status.phase, .disabled)
        XCTAssertFalse(status.isEnabled)
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.map(\.id), [captured.entryID])
    }
}

private struct SyncTestLocalKeyStore: ClipboardHistoryMasterKeyStoring {
    func load() -> ClipboardHistoryMasterKeyResult {
        .key(Data(repeating: 0x67, count: 32))
    }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}
