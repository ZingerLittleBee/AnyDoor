import AppKit
import ClipboardHistoryTestSupport
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardSyncSettingsTransferTests: XCTestCase {
    func testTagSelectionAllowsAnotherChoiceDuringFileUpload() async throws {
        let fixture = try await makeFixture()
        try await fixture.module.setSyncEnabled(true)
        let model = ClipboardSyncSettingsModel(module: fixture.module)
        await model.refresh()
        await fixture.cloud.holdNextUpload()
        let selecting = Task { await model.selectTag(fixture.firstTag) }
        addTeardownBlock {
            await fixture.cloud.cancel()
            await selecting.value
        }
        try await waitForUpload(fixture.cloud)
        await model.refresh()

        XCTAssertTrue(model.canSelectTag)
        let nextSelection = Task { await model.selectTag(fixture.secondTag) }
        addTeardownBlock {
            await fixture.cloud.cancel()
            await nextSelection.value
        }
        for _ in 0..<100 {
            if try await fixture.module.syncTags().contains(where: { $0.id == fixture.secondTag && $0.isSelected }) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let tagsDuringUpload = try await fixture.module.syncTags()
        XCTAssertTrue(tagsDuringUpload.contains { $0.id == fixture.secondTag && $0.isSelected })

        await model.setEnabled(false)
        await selecting.value
        await nextSelection.value
        XCTAssertFalse(model.status.isEnabled)
        XCTAssertFalse(model.isPerformingAction)
        let stopped = await fixture.cloud.uploadIsHeld()
        XCTAssertFalse(stopped)
    }

    private func makeFixture() async throws -> (module: ClipboardHistoryModule, cloud: HeldFileSettingsCloud,
                                               firstTag: String, secondTag: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-transfer-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Source.txt")
        try Data(repeating: 0x64, count: 6 * 1_024 * 1_024).write(to: source)
        let cloud = HeldFileSettingsCloud()
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Store"),
            keyStore: FileConflictUILocalKey(byte: 0x67),
            syncServices: .init(transport: cloud, keys: FileConflictUIKeys(), pollingInterval: nil)),
            beforeClosing: { await cloud.cancel() })
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.settings-transfer.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(source.absoluteString, forType: .fileURL)
        guard case .captured(let capture) = try await module.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let first = try await module.createTagDefinition(named: "First", assigningTo: capture.entryID)
        let second = try await module.createTagDefinition(named: "Second", assigningTo: capture.entryID)
        return (module, cloud, first.definition.id, second.definition.id)
    }

    private func waitForUpload(_ cloud: HeldFileSettingsCloud) async throws {
        for _ in 0..<1_000 {
            if await cloud.uploadIsHeld() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("The isolated file upload did not reach its hold")
        throw ClipboardHistoryModuleError.operationUnavailable
    }
}

private actor HeldFileSettingsCloud: ClipboardSyncTransport {
    private let cloud = FileConflictUICloud()
    private var shouldHoldUpload = false
    private var heldUpload: CheckedContinuation<Void, any Error>?

    func holdNextUpload() { shouldHoldUpload = true }
    func uploadIsHeld() -> Bool { heldUpload != nil }
    func account() async throws -> ClipboardSyncAccount { await cloud.account() }
    func control(for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl? { await cloud.control(for: account) }
    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl {
        await cloud.createControl(candidate, for: account)
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) async throws -> ClipboardSyncChanges {
        await cloud.changes(for: account, control: control, cursor: cursor)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) async throws -> [Data] {
        try await cloud.download(record, for: account)
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl) async throws -> ClipboardSyncControl {
        try await cloud.commit(upload, for: account, control: control)
    }
    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl,
                    progress: @Sendable (Int64) async throws -> Void) async throws -> ClipboardSyncControl {
        if shouldHoldUpload {
            shouldHoldUpload = false
            try await withCheckedThrowingContinuation { heldUpload = $0 }
        }
        try Task.checkCancellation()
        return try await cloud.commitFile(upload, for: account, control: control, progress: progress)
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) async throws -> Data {
        try await cloud.downloadFileSegment(record, index: index, for: account)
    }
    func cancel() async {
        heldUpload?.resume(throwing: CancellationError())
        heldUpload = nil
        await cloud.cancel()
    }
}
