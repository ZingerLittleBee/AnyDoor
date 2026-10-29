import CloudKit
import ClipboardHistoryTestSupport
import Foundation
import XCTest

@testable import ClipboardHistory

final class ClipboardHistoryMissingCollectionJoinTests: XCTestCase {
    func testRecoveredDeviceJoinsFreshCollectionWithoutRepublishingRetainedHistory() async throws {
        for racesCreation in [false, true] {
            let fixture = try await replacementCollection()
            if racesCreation { await fixture.cloud.hideNextControlRead() }
            let retainedRecords = await fixture.cloud.uploadedRecords()
            try await fixture.old.setSyncEnabled(true)
            let status = await fixture.old.syncStatus()
            XCTAssertEqual(status.phase, .upToDate)
            let entries = try await fixture.old.page(.init()).entries
            XCTAssertEqual(Set(entries.compactMap(\.previewText)), ["retained old history", "fresh collection history"])
            let tags = try await fixture.old.syncTags()
            XCTAssertEqual(tags.first { $0.id == fixture.oldTagID }?.isSelected, false)
            let control = await fixture.cloud.authoritativeControl()
            XCTAssertEqual(control?.keyID, fixture.replacement.keyID)
            XCTAssertEqual(control?.epoch, fixture.replacement.epoch)
            let records = await fixture.cloud.uploadedRecords()
            XCTAssertTrue(Set(retainedRecords.map(\.record.recordID)).isSubset(of: Set(records.map(\.record.recordID))))
            await fixture.fresh.retrySync()
            let beforeSelection = try await fixture.fresh.page(.init()).entries
            XCTAssertEqual(beforeSelection.map(\.previewText), ["fresh collection history"])

            try await fixture.old.setSyncTagSelected(fixture.oldTagID, selected: true)
            await fixture.fresh.retrySync()
            let shared = try await fixture.fresh.page(.init()).entries
            XCTAssertEqual(Set(shared.compactMap(\.previewText)), ["retained old history", "fresh collection history"])
        }
    }

    func testRecoveredDeviceWaitsForReplacementKeyAcrossRestart() async throws {
        let fixture = try await replacementCollection()
        await fixture.keys.withhold(fixture.replacement.keyID)
        try await fixture.old.setSyncEnabled(true)
        let waiting = await fixture.old.syncStatus()
        XCTAssertEqual(waiting.phase, .waitingForKey)
        XCTAssertFalse(waiting.canClearCloudData, "An unverified replacement must not become local authority")
        let unchanged = await fixture.cloud.authoritativeControl()
        XCTAssertEqual(unchanged, fixture.replacement)
        let retained = try await fixture.old.page(.init()).entries
        XCTAssertEqual(retained.map(\.previewText), ["retained old history"])

        try await fixture.old.closeStoreForTesting()
        let reopened = makeModule(root: fixture.oldRoot, services: fixture.services, key: 0xA1)
        await reopened.resumeSync()
        let stillWaiting = await reopened.syncStatus()
        XCTAssertEqual(stillWaiting.phase, .waitingForKey)
        await fixture.keys.withhold(nil)
        await reopened.retrySync()
        let joined = await reopened.syncStatus()
        XCTAssertEqual(joined.phase, .upToDate)
        let entries = try await reopened.page(.init()).entries
        XCTAssertEqual(Set(entries.compactMap(\.previewText)), ["retained old history", "fresh collection history"])
        let tags = try await reopened.syncTags()
        XCTAssertEqual(tags.first { $0.id == fixture.oldTagID }?.isSelected, false)
    }

    func testRecoveredDeviceRejectsWrongReplacementKeyWithoutPinningItsControl() async throws {
        let fixture = try await replacementCollection()
        await fixture.keys.corrupt(fixture.replacement.keyID)
        try await fixture.old.setSyncEnabled(true)
        let rejected = await fixture.old.syncStatus()
        XCTAssertEqual(rejected.phase, .failed(.corruptData))
        XCTAssertFalse(rejected.canClearCloudData)
        let retained = try await fixture.old.page(.init()).entries
        XCTAssertEqual(retained.map(\.previewText), ["retained old history"])
        let unchanged = await fixture.cloud.authoritativeControl()
        XCTAssertEqual(unchanged, fixture.replacement)

        await fixture.keys.corrupt(nil)
        await fixture.old.retrySync()
        let accepted = await fixture.old.syncStatus()
        XCTAssertEqual(accepted.phase, .upToDate)
    }

    func testRecoveredDeviceRejectsReturningRetiredEpoch() async throws {
        let fixture = try await replacementCollection()
        await fixture.cloud.returnControl(fixture.previous)
        try await fixture.old.setSyncEnabled(true)
        let rejected = await fixture.old.syncStatus()
        XCTAssertEqual(rejected.phase, .failed(.recoveryRequired))
        XCTAssertFalse(rejected.canClearCloudData)
        let retained = try await fixture.old.page(.init()).entries
        XCTAssertEqual(retained.map(\.previewText), ["retained old history"])
        await fixture.cloud.returnControl(nil)
        await fixture.old.retrySync()
        let accepted = await fixture.old.syncStatus()
        XCTAssertEqual(accepted.phase, .upToDate)
    }

    func testRecoveredDeviceRevalidatesAccountAfterReplacementKeyLoad() async throws {
        let fixture = try await replacementCollection()
        await fixture.keys.changeAccountOnNextLoad(using: fixture.cloud)
        try await fixture.old.setSyncEnabled(true)
        let rejected = await fixture.old.syncStatus()
        XCTAssertEqual(rejected.phase, .failed(.accountChanged))
        XCTAssertFalse(rejected.isEnabled)
        XCTAssertFalse(rejected.canClearCloudData)
        let retained = try await fixture.old.page(.init()).entries
        XCTAssertEqual(retained.map(\.previewText), ["retained old history"])
    }

    func testEstablishedDeviceDoesNotAdoptDifferentCollectionKey() async throws {
        let fixture = try await replacementCollection(recover: false)
        try await fixture.old.setSyncEnabled(true)
        let rejected = await fixture.old.syncStatus()
        XCTAssertEqual(rejected.phase, .failed(.corruptData))
        let retained = try await fixture.old.page(.init()).entries
        XCTAssertEqual(retained.map(\.previewText), ["retained old history"])
        let unchanged = await fixture.cloud.authoritativeControl()
        XCTAssertEqual(unchanged, fixture.replacement)
    }

    private struct Fixture {
        let old: ClipboardHistoryModule
        let fresh: ClipboardHistoryModule
        let oldRoot: URL
        let oldTagID: String
        let cloud: RecoveryJoinCloud
        let keys: RecoveryJoinKeys
        let services: ClipboardSyncServices
        let previous: ClipboardSyncControl
        let replacement: ClipboardSyncControl
    }

    private func replacementCollection(recover: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovered-collection-join-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let cloud = RecoveryJoinCloud()
        let backingKeys = LinkedFileKeys()
        let keys = RecoveryJoinKeys(backing: backingKeys)
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let oldRoot = root.appendingPathComponent("Old")
        let original = makeModule(root: oldRoot, services: services, key: 0xA1)
        let local = try await original.capture(.init(source: .unknown, content: .text("retained old history")))
        let tag = try await original.createTagDefinition(named: "Old", assigningTo: local.entryID).definition
        try await original.setSyncTagSelected(tag.id, selected: true)
        try await original.setSyncEnabled(true)
        let initial = await cloud.authoritativeControl()
        let previous = try XCTUnwrap(initial)
        await original.suspendSync()
        await cloud.deleteZone()
        if recover {
            await original.resumeSync()
            let missing = await original.syncStatus()
            XCTAssertTrue(missing.canRecoverMissingCloudCollection)
            let confirmation = try await original.prepareMissingCloudCollectionRecovery()
            try await original.recoverMissingCloudCollection(confirmation)
        }
        try await original.closeStoreForTesting()
        let old = makeModule(root: oldRoot, services: services, key: 0xA1)

        // A genuinely new store chooses its own key through production bootstrap,
        // even though the same external Keychain already contains the old key.
        let fresh = makeModule(root: root.appendingPathComponent("Fresh"),
            services: .init(transport: cloud, keys: backingKeys, pollingInterval: nil), key: 0xA2)
        let entry = try await fresh.capture(.init(source: .unknown, content: .text("fresh collection history")))
        let freshTag = try await fresh.createTagDefinition(named: "Fresh", assigningTo: entry.entryID).definition
        try await fresh.setSyncTagSelected(freshTag.id, selected: true)
        try await fresh.setSyncEnabled(true)
        let freshStatus = await fresh.syncStatus()
        XCTAssertEqual(freshStatus.phase, .upToDate)
        let current = await cloud.authoritativeControl()
        let replacement = try XCTUnwrap(current)
        XCTAssertNotEqual(replacement.keyID, previous.keyID)
        XCTAssertNotEqual(replacement.epoch, previous.epoch)
        return Fixture(old: old, fresh: fresh, oldRoot: oldRoot, oldTagID: tag.id,
            cloud: cloud, keys: keys, services: services, previous: previous, replacement: replacement)
    }

    private func makeModule(root: URL, services: ClipboardSyncServices, key: UInt8) -> ClipboardHistoryModule {
        trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root,
            keyStore: RecoveryJoinLocalKey(byte: key), syncServices: services))
    }
}

private struct RecoveryJoinLocalKey: ClipboardHistoryMasterKeyStoring {
    let byte: UInt8
    func load() -> ClipboardHistoryMasterKeyResult { .key(Data(repeating: byte, count: 32)) }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

private actor RecoveryJoinKeys: ClipboardSyncKeyStoring {
    private let backing: LinkedFileKeys
    private var withheld: UUID?
    private var corrupted: UUID?
    private var accountChange: RecoveryJoinCloud?

    init(backing: LinkedFileKeys) { self.backing = backing }
    func withhold(_ keyID: UUID?) { withheld = keyID }
    func corrupt(_ keyID: UUID?) { corrupted = keyID }
    func changeAccountOnNextLoad(using cloud: RecoveryJoinCloud) { accountChange = cloud }

    func load(account: ClipboardSyncAccount, keyID: UUID) async -> Data? {
        if let cloud = accountChange {
            accountChange = nil
            await cloud.switchAccount()
        }
        if keyID == withheld { return nil }
        if keyID == corrupted { return Data(repeating: 0xEF, count: 32) }
        return await backing.load(account: account, keyID: keyID)
    }

    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) async throws -> Data {
        try await backing.create(account: account, keyID: keyID, key: key)
    }
}

/// Faults and delayed responses are confined to the external provider boundary.
private actor RecoveryJoinCloud: ClipboardSyncTransport {
    private let backing = LinkedFileCloud(account: ClipboardHistorySyncCloudKitReadTests.account)
    private let absent = ClipboardSyncCloudKit(recordReader: { _, _, _ in throw CKError(.userDeletedZone) })
    private var deleted = false
    private var hiddenRead = false
    private var returnedControl: ClipboardSyncControl?

    func deleteZone() async { deleted = true; await backing.removeControl() }
    func hideNextControlRead() { hiddenRead = true }
    func returnControl(_ control: ClipboardSyncControl?) { returnedControl = control }
    func switchAccount() async { await backing.switchAccount(to: "another-recovery-account") }
    func account() async -> ClipboardSyncAccount { await backing.account() }
    func authoritativeControl() async -> ClipboardSyncControl? {
        let account = await backing.account()
        return await backing.control(for: account)
    }
    func uploadedRecords() async -> [ClipboardSyncUpload] { await backing.uploadedRecords() }

    func control(for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl? {
        if let returnedControl { return returnedControl }
        if hiddenRead { hiddenRead = false; return nil }
        let current = await backing.control(for: account)
        if current == nil, deleted { return try await absent.control(for: account) }
        return current
    }

    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) async -> ClipboardSyncControl {
        deleted = false
        return await backing.createControl(candidate, for: account)
    }

    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) async -> ClipboardSyncChanges {
        await backing.changes(for: account, control: control, cursor: cursor)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) async throws -> [Data] {
        try await backing.download(record, for: account)
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl) async throws -> ClipboardSyncControl {
        try await backing.commit(upload, for: account, control: control)
    }
    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl,
        progress: @Sendable (Int64) async throws -> Void) async throws -> ClipboardSyncControl {
        try await backing.commitFile(upload, for: account, control: control, progress: progress)
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) async throws -> Data {
        try await backing.downloadFileSegment(record, index: index, for: account)
    }
    func purge(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount, control: ClipboardSyncControl) async throws -> ClipboardSyncControl {
        try await backing.purge(record, for: account, control: control)
    }
    func cancel() async { await backing.cancel() }
}
