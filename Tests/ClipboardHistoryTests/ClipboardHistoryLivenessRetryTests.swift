import Foundation
import XCTest
import os
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testCorruptContentPollingIncreasesItsDeadlineAcrossRestartAndAllowsExplicitRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("content-retry-growth-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let provider = LinkedFileCloud()
        let cloud = LivenessRetryCloud(provider: provider)
        let keys = LinkedFileKeys()
        let sender = makeLinkedModule(root: root.appendingPathComponent("Sender"),
            services: .init(transport: provider, keys: keys, pollingInterval: nil), key: 0xB1)
        let captured = try await sender.capture(.init(source: .unknown, content: .text(String(repeating: "authenticated body ", count: 50_000))))
        let tag = try await sender.createTagDefinition(named: "Shared", assigningTo: captured.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        let uploads = await provider.uploadedRecords()
        let entry = try XCTUnwrap(uploads.first { $0.record.kind == .entry })
        await cloud.damage(entry.record.recordID)
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: .milliseconds(20))
        let receiverRoot = root.appendingPathComponent("Receiver")
        let receiver = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: receiverRoot,
            keyStore: LivenessRetryLocalKey(), now: { clock.withLock { $0 } }, syncServices: services))
        let queued = try await receiver.capture(.init(source: .unknown, content: .text("outgoing waits for unread authority")))
        let localTag = try await receiver.createTagDefinition(named: "Queued", assigningTo: queued.entryID)
        try await receiver.setSyncTagSelected(localTag.definition.id, selected: true)
        try await receiver.setSyncEnabled(true)
        let initialReads = await cloud.bodyReadCount()
        XCTAssertEqual(initialReads, 1)
        clock.withLock { $0 = $0.addingTimeInterval(30) }
        try await eventually { await cloud.bodyReadCount() == 2 }
        await receiver.resumeSync()

        // A normal production interval later must no longer retry every poll.
        clock.withLock { $0 = $0.addingTimeInterval(30) }
        let discovery = await cloud.changeReadCount()
        try await eventually { await cloud.changeReadCount() >= discovery + 2 }
        await receiver.resumeSync()
        let earlyReads = await cloud.bodyReadCount()
        XCTAssertEqual(earlyReads, 2)
        let stillBlocked = await provider.uploadedRecords()
        XCTAssertEqual(stillBlocked.filter { $0.record.kind == .entry }.count, 1)
        try await receiver.closeStoreForTesting()

        let reopened = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: receiverRoot,
            keyStore: LivenessRetryLocalKey(), now: { clock.withLock { $0 } }, syncServices: services))
        await reopened.resumeSync()
        let restartReads = await cloud.bodyReadCount()
        XCTAssertEqual(restartReads, 2, "The second failure's longer deadline must survive reopen")
        clock.withLock { $0 = $0.addingTimeInterval(30) }
        try await eventually { await cloud.bodyReadCount() == 3 }
        await reopened.resumeSync()
        clock.withLock { $0 = $0.addingTimeInterval(30) }
        let laterDiscovery = await cloud.changeReadCount()
        try await eventually { await cloud.changeReadCount() >= laterDiscovery + 2 }
        await reopened.resumeSync()
        let laterReads = await cloud.bodyReadCount()
        XCTAssertEqual(laterReads, 3)
        await cloud.damage(nil)
        let repairTime = clock.withLock { $0 }
        await reopened.retrySync()
        // A coalesced retry can still be queued, and polling can start again as
        // soon as it completes. Wait for durable completion, not an idle phase.
        try await eventually { await reopened.syncStatus().lastCompletedAt == repairTime }
        let repairedReads = await cloud.bodyReadCount()
        XCTAssertEqual(repairedReads, 4, "Explicit Retry can repair immediately despite the longer deadline")
        let repaired = try await reopened.page(.init())
        XCTAssertEqual(Set(repaired.entries.map(\.id)), [captured.entryID, queued.entryID])
        await sender.retrySync()
        let peer = try await sender.page(.init())
        XCTAssertTrue(peer.entries.contains { $0.id == queued.entryID })
    }
}

private struct LivenessRetryLocalKey: ClipboardHistoryMasterKeyStoring {
    func load() -> ClipboardHistoryMasterKeyResult { .key(Data(repeating: 0xB2, count: 32)) }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

private actor LivenessRetryCloud: ClipboardSyncTransport {
    let provider: LinkedFileCloud
    private var damagedID: String?
    private var watchedID: String?
    private var bodyReads = 0
    private var changesRead = 0

    init(provider: LinkedFileCloud) { self.provider = provider }
    func damage(_ recordID: String?) { damagedID = recordID; if let recordID { watchedID = recordID } }
    func bodyReadCount() -> Int { bodyReads }
    func changeReadCount() -> Int { changesRead }
    func account() async throws -> ClipboardSyncAccount { await provider.account() }
    func control(for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl? { await provider.control(for: account) }
    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl {
        await provider.createControl(candidate, for: account)
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) async throws -> ClipboardSyncChanges {
        changesRead += 1
        return await provider.changes(for: account, control: control, cursor: cursor)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) async throws -> [Data] {
        var chunks = try await provider.download(record, for: account)
        if record.recordID == watchedID { bodyReads += 1 }
        if record.recordID == damagedID { chunks[0][0] ^= 1 }
        return chunks
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl) async throws -> ClipboardSyncControl {
        try await provider.commit(upload, for: account, control: control)
    }
    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl,
        progress: @Sendable (Int64) async throws -> Void) async throws -> ClipboardSyncControl {
        try await provider.commitFile(upload, for: account, control: control, progress: progress)
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) async throws -> Data {
        try await provider.downloadFileSegment(record, index: index, for: account)
    }
    func purge(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount, control: ClipboardSyncControl) async throws -> ClipboardSyncControl {
        try await provider.purge(record, for: account, control: control)
    }
    func cancel() async { await provider.cancel() }
}
