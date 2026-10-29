import AppKit
import CloudKit
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testMissingNativeSegmentKeepsIndependentSharingAndRecoversExactVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-missing-segment-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0x41, count: 5_000_001)
        let large = root.appendingPathComponent("Large.bin")
        let healthy = root.appendingPathComponent("Healthy.txt")
        try bytes.write(to: large)
        try Data("healthy complete file".utf8).write(to: healthy)
        let cloud = LinkedFileCloud(account: ClipboardHistorySyncCloudKitReadTests.account)
        let keys = LinkedFileKeys()
        let records = NativeChunkRecords(cloud: cloud, root: root)
        let native = ClipboardSyncCloudKit(recordReader: { account, ids, fields in
            try await records.fetch(account: account, ids: ids, fields: fields)
        })
        let sender = makeLinkedModule(root: root.appendingPathComponent("Sender"),
            services: .init(transport: cloud, keys: keys, pollingInterval: nil), key: 0x51)
        let transport = NativeSegmentTransport(cloud: cloud, native: native)
        let services = ClipboardSyncServices(transport: transport, keys: keys, pollingInterval: nil)
        let receiver = makeLinkedModule(root: root.appendingPathComponent("Receiver"), services: services, key: 0x52)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.native-chunk.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([large as NSURL, healthy as NSURL]))
        guard case .captured(let captured) = try await sender.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected real file references")
        }
        let tag = try await sender.createTagDefinition(named: "Shared", assigningTo: captured.entryID).definition
        try await sender.setSyncTagSelected(tag.id, selected: true)
        let removed = try await sender.capture(.init(source: .unknown, content: .text("delete despite missing segment")))
        _ = try await sender.apply(.setTags(removed.entryID, [tag.id]))
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        let received = try await receiver.page(.init()).entries
        let entry = try XCTUnwrap(received.first { $0.id == captured.entryID })
        let file = try XCTUnwrap(entry.syncFiles.first { $0.displayName == "Large.bin" })
        XCTAssertEqual(entry.syncFiles.first { $0.displayName == "Healthy.txt" }?.state, .complete)
        let uploads = await cloud.uploadedRecords()
        let body = try XCTUnwrap(uploads.first { $0.record.kind == .fileBody && $0.record.chunkCount > 1 }?.record)
        await records.removeSecondSegment(of: body.operationID)
        let added = try await receiver.capture(.init(source: .unknown, content: .text("share despite missing segment")))
        _ = try await receiver.apply(.setTags(added.entryID, [tag.id]))
        _ = try await receiver.apply(.delete(removed.entryID))

        try await receiver.requestSyncFileDownload(entryID: captured.entryID, objectID: file.id, versionID: file.versionID)

        let failed = await receiver.syncStatus()
        XCTAssertEqual(failed.phase, .failed(.network), "A missing chunk must not require collection recovery")
        await sender.retrySync()
        let shared = try await sender.page(.init()).entries
        XCTAssertTrue(shared.contains { $0.id == added.entryID })
        XCTAssertFalse(shared.contains { $0.id == removed.entryID })
        let pendingEntries = try await receiver.page(.init()).entries
        let pending = try XCTUnwrap(pendingEntries.first { $0.id == captured.entryID })
        XCTAssertNil(pending.syncFiles.first { $0.id == file.id }?.availableVersionID)
        XCTAssertEqual(pending.syncFiles.first { $0.displayName == "Healthy.txt" }?.state, .complete)
        do {
            _ = try await receiver.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
            XCTFail("The missing second chunk must not expose a partial file or omit its item")
        } catch ClipboardHistoryModuleError.syncFilesPending { }

        try await receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: root.appendingPathComponent("Receiver"), services: services, key: 0x52)
        await reopened.resumeSync()
        let reopenedEntries = try await reopened.page(.init()).entries
        let stillPending = try XCTUnwrap(reopenedEntries.first { $0.id == captured.entryID })
        XCTAssertEqual(stillPending.syncFiles.first { $0.id == file.id }?.versionID, file.versionID)
        XCTAssertNil(stillPending.syncFiles.first { $0.id == file.id }?.availableVersionID)
        await records.restoreSegments()
        await reopened.retrySync()
        let recovered = try await reopened.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        guard case .file(let complete) = recovered.items.first?.representations.first else {
            return XCTFail("Expected the complete first file")
        }
        XCTAssertEqual(try Data(contentsOf: complete.currentURL), bytes)
        let currentEntries = try await reopened.page(.init()).entries
        let current = try XCTUnwrap(currentEntries.first { $0.id == captured.entryID })
        XCTAssertEqual(current.syncFiles.first { $0.id == file.id }?.availableVersionID, file.versionID)
        XCTAssertNil(current.syncFiles.first { $0.id == file.id }?.transferFailure)
    }
}

/// Supplies raw provider values to the production native adapter. Encryption,
/// publication, retry journals and local storage remain in the real modules.
private actor NativeChunkRecords {
    let cloud: LinkedFileCloud
    let root: URL
    private var missingOperation: UUID?
    init(cloud: LinkedFileCloud, root: URL) { self.cloud = cloud; self.root = root }
    func removeSecondSegment(of operation: UUID) { missingOperation = operation }
    func restoreSegments() { missingOperation = nil }

    func fetch(account: ClipboardSyncAccount, ids: [CKRecord.ID], fields: [String]) async throws
        -> [CKRecord.ID: Result<CKRecord, Error>] {
        XCTAssertEqual(account, ClipboardHistorySyncCloudKitReadTests.account)
        XCTAssertTrue(fields.contains("asset"))
        let uploads = await cloud.uploadedRecords()
        var results: [CKRecord.ID: Result<CKRecord, Error>] = [:]
        for id in ids {
            let parts = id.recordName.split(separator: ".")
            guard parts.count == 3, let operation = UUID(uuidString: String(parts[1])),
                  let index = Int(parts[2]), let upload = uploads.first(where: { $0.record.operationID == operation }),
                  upload.chunks.indices.contains(index) else {
                throw CKError(.invalidArguments)
            }
            if operation == missingOperation, index == 1 {
                results[id] = .failure(CKError(.unknownItem))
            } else {
                let url = root.appendingPathComponent("asset-\(UUID())")
                let bytes = upload.chunks[index]
                try bytes.write(to: url)
                results[id] = .success(ClipboardHistorySyncCloudKitReadTests.chunk(
                    id: id, remote: upload.record, index: index, bytes: bytes, url: url))
            }
        }
        return results
    }
}

private struct NativeSegmentTransport: ClipboardSyncTransport {
    let cloud: any ClipboardSyncTransport
    let native: ClipboardSyncCloudKit
    func account() async throws -> ClipboardSyncAccount { try await cloud.account() }
    func control(for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl? { try await cloud.control(for: account) }
    func createControl(_ control: ClipboardSyncControl, for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl {
        try await cloud.createControl(control, for: account)
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) async throws -> ClipboardSyncChanges {
        try await cloud.changes(for: account, control: control, cursor: cursor)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) async throws -> [Data] {
        try await cloud.download(record, for: account)
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) async throws -> Data {
        try await native.downloadFileSegment(record, index: index, for: account)
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl) async throws -> ClipboardSyncControl {
        try await cloud.commit(upload, for: account, control: control)
    }
    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl,
        progress: @Sendable (Int64) async throws -> Void) async throws -> ClipboardSyncControl {
        try await cloud.commitFile(upload, for: account, control: control, progress: progress)
    }
    func purge(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount, control: ClipboardSyncControl) async throws -> ClipboardSyncControl {
        try await cloud.purge(record, for: account, control: control)
    }
    func transition(_ control: ClipboardSyncControl, to phase: String, epoch: UUID, for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl {
        try await cloud.transition(control, to: phase, epoch: epoch, for: account)
    }
    func clearPage(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) async throws -> ClipboardSyncCleanupPage {
        try await cloud.clearPage(for: account, control: control, cursor: cursor)
    }
    func cancel() async { await native.cancel(); await cloud.cancel() }
}
