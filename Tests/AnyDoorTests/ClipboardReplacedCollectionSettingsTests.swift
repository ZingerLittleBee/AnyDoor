import ClipboardHistoryTestSupport
import Foundation
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardReplacedCollectionSettingsTests: XCTestCase {
    func testReplacementRecoveryIsVisibleWhileOffAndCancelDoesNotRetireParticipation() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        XCTAssertTrue(model.status.canRecoverReplacedCloudCollection)
        XCTAssertFalse(model.status.canRecoverMissingCloudCollection)
        XCTAssertNil(model.recoveryHelpURL, "A replaced collection has a local recovery action")
        await model.setEnabled(false)
        XCTAssertTrue(model.status.canRecoverReplacedCloudCollection)
        await model.prepareReplacedCollectionRecovery()
        XCTAssertNotNil(model.replacedCollectionConfirmation)
        model.cancelReplacedCollectionRecovery()
        XCTAssertNil(model.replacedCollectionConfirmation)
        XCTAssertFalse(model.didRecoverReplacedCollection)
        XCTAssertTrue(model.tags.allSatisfy(\.isSelected))
        let before = await fixture.cloud.writeCount()

        await model.prepareReplacedCollectionRecovery()
        let confirmation = try XCTUnwrap(model.replacedCollectionConfirmation)
        // A dismissed SwiftUI binding must not discard the captured confirmation.
        model.cancelReplacedCollectionRecovery()
        await model.confirmReplacedCollectionRecovery(confirmation)

        XCTAssertFalse(model.operationFailed)
        XCTAssertTrue(model.didRecoverReplacedCollection)
        XCTAssertFalse(model.status.isEnabled)
        XCTAssertFalse(model.status.canRecoverReplacedCloudCollection)
        XCTAssertNil(model.status.cloudReset)
        XCTAssertTrue(model.tags.allSatisfy { !$0.isSelected })
        let local = try await fixture.module.page(.init()).entries
        XCTAssertEqual(local.map(\.previewText), ["retained local history"])
        let after = await fixture.cloud.writeCount()
        XCTAssertEqual(after, before, "Local recovery cannot modify the replacement cloud collection")
        let remote = try await fixture.fresh.page(.init()).entries
        XCTAssertEqual(remote.map(\.previewText), ["replacement history"])
    }

    func testStaleReplacementConfirmationDoesNotClaimRecoveryOrRevokeTags() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        await model.setEnabled(false)
        await model.prepareReplacedCollectionRecovery()
        let confirmation = try XCTUnwrap(model.replacedCollectionConfirmation)
        await fixture.cloud.recreateCollection()
        let before = await fixture.cloud.writeCount()

        await model.confirmReplacedCollectionRecovery(confirmation)

        XCTAssertTrue(model.operationFailed)
        XCTAssertFalse(model.didRecoverReplacedCollection)
        XCTAssertFalse(model.status.isEnabled)
        XCTAssertTrue(model.tags.allSatisfy(\.isSelected))
        XCTAssertNil(model.status.cloudReset)
        let after = await fixture.cloud.writeCount()
        XCTAssertEqual(after, before)
        let local = try await fixture.module.page(.init()).entries
        XCTAssertEqual(local.map(\.previewText), ["retained local history"])
    }

    private func makeFixture() async throws -> (
        module: ClipboardHistoryModule, fresh: ClipboardHistoryModule,
        model: ClipboardSyncSettingsModel, cloud: ReplacedCollectionSettingsCloud
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("replacement-settings-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let cloud = ReplacedCollectionSettingsCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: FileConflictUIKeys(), pollingInterval: nil)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Old"),
            keyStore: FileConflictUILocalKey(byte: 0x64), syncServices: services))
        let entry = try await module.capture(.init(source: .unknown, content: .text("retained local history")))
        let tag = try await module.createTagDefinition(named: "Old", assigningTo: entry.entryID).definition
        try await module.setSyncTagSelected(tag.id, selected: true)
        try await module.setSyncEnabled(true)
        await module.suspendSync()
        await cloud.recreateCollection()
        let fresh = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Fresh"),
            keyStore: FileConflictUILocalKey(byte: 0x65), syncServices: services))
        let remote = try await fresh.capture(.init(source: .unknown, content: .text("replacement history")))
        let remoteTag = try await fresh.createTagDefinition(named: "New", assigningTo: remote.entryID).definition
        try await fresh.setSyncTagSelected(remoteTag.id, selected: true)
        try await fresh.setSyncEnabled(true)
        await fresh.suspendSync()
        await module.resumeSync()
        let model = ClipboardSyncSettingsModel(module: module)
        await model.refresh()
        return (module, fresh, model, cloud)
    }
}

/// Only the provider is replaced. Both devices use the production module/store.
private actor ReplacedCollectionSettingsCloud: ClipboardSyncTransport {
    private var backing = FileConflictUICloud()
    private var writes = 0
    func recreateCollection() { backing = FileConflictUICloud() }
    func writeCount() -> Int { writes }
    func account() async -> ClipboardSyncAccount { await backing.account() }
    func control(for account: ClipboardSyncAccount) async -> ClipboardSyncControl? { await backing.control(for: account) }
    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) async -> ClipboardSyncControl {
        writes += 1
        return await backing.createControl(candidate, for: account)
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) async -> ClipboardSyncChanges {
        await backing.changes(for: account, control: control, cursor: cursor)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) async throws -> [Data] {
        try await backing.download(record, for: account)
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl) async throws -> ClipboardSyncControl {
        writes += 1
        return try await backing.commit(upload, for: account, control: control)
    }
    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl,
        progress: @Sendable (Int64) async throws -> Void) async throws -> ClipboardSyncControl {
        writes += 1
        return try await backing.commitFile(upload, for: account, control: control, progress: progress)
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) async throws -> Data {
        try await backing.downloadFileSegment(record, index: index, for: account)
    }
    func cancel() async { await backing.cancel() }
}
