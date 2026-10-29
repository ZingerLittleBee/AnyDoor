import ClipboardHistoryTestSupport
import Foundation
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardMissingCollectionSettingsTests: XCTestCase {
    func testOrdinaryOffRequiresExplicitEnableToRecheckAReturnedCollection() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        await fixture.cloud.setMissing(true)
        await model.retry()
        try await waitForMissingCollection(model)
        await model.setEnabled(false)
        XCTAssertFalse(model.status.isEnabled)
        XCTAssertNil(model.status.cloudReset)
        XCTAssertTrue(model.status.canRecoverMissingCloudCollection)
        XCTAssertFalse(model.offersRetry, "Ordinary Off cannot run the core Retry operation")
        XCTAssertEqual(model.missingCollectionHelpKey, .settingsClipboardSyncMissingCollectionOff)
        await fixture.cloud.setMissing(false)
        let readsBefore = await fixture.cloud.controlReadCount()
        let writesBefore = await fixture.cloud.writeCount()

        await model.setEnabled(true)
        for _ in 0..<1_000 {
            await model.refresh()
            if model.status.phase == .upToDate && !model.status.canRecoverMissingCloudCollection { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(model.status.phase, .upToDate)
        XCTAssertFalse(model.status.canRecoverMissingCloudCollection)
        XCTAssertFalse(model.didRecoverMissingCollection)
        XCTAssertFalse(model.operationFailed)
        XCTAssertNil(model.status.cloudReset)
        let readsAfter = await fixture.cloud.controlReadCount()
        let writesAfter = await fixture.cloud.writeCount()
        XCTAssertGreaterThan(readsAfter, readsBefore, "Explicit enable must read the returned provider descriptor")
        XCTAssertEqual(writesAfter, writesBefore, "Rechecking the existing collection must not create or clear one")
        XCTAssertEqual(model.tags.count, 1)
        XCTAssertTrue(model.tags.allSatisfy(\.isSelected))
        let local = try await fixture.module.page(.init()).entries
        XCTAssertEqual(local.map(\.previewText), ["local history survives missing cloud data"])
    }

    func testChangedAuthorityAndProviderFailureDoNotReportRecoveryOrClearLocalConsent() async throws {
        for change in [RecoveryChange.returnedCollection, .account, .providerFailure] {
            let fixture = try await makeFixture()
            let model = fixture.model
            await fixture.cloud.setMissing(true)
            await model.retry()
            try await waitForMissingCollection(model)
            XCTAssertNil(model.recoveryHelpURL, "Confirmed collection absence is not a Keychain recovery problem")
            await model.setEnabled(false)
            XCTAssertTrue(model.status.canRecoverMissingCloudCollection)
            await model.prepareMissingCollectionRecovery()
            let confirmation = try XCTUnwrap(model.missingCollectionConfirmation)
            switch change {
            case .returnedCollection: await fixture.cloud.setMissing(false)
            case .account: await fixture.cloud.switchAccount()
            case .providerFailure: await fixture.cloud.failControlReads()
            }
            let before = await fixture.cloud.writeCount()
            model.cancelMissingCollectionRecovery()
            await model.confirmMissingCollectionRecovery(confirmation)

            XCTAssertTrue(model.operationFailed)
            XCTAssertFalse(model.didRecoverMissingCollection)
            XCTAssertNil(model.missingCollectionConfirmation)
            XCTAssertFalse(model.status.isEnabled)
            XCTAssertNil(model.status.cloudReset, "Rejected recovery must not manufacture a cloud-clear result")
            XCTAssertEqual(model.tags.count, 1)
            XCTAssertTrue(model.tags.allSatisfy(\.isSelected))
            let local = try await fixture.module.page(.init()).entries
            XCTAssertEqual(local.map(\.previewText), ["local history survives missing cloud data"])
            let after = await fixture.cloud.writeCount()
            XCTAssertEqual(after, before)
            await model.prepareMissingCollectionRecovery()
            XCTAssertNil(model.missingCollectionConfirmation, "Prepare must also recheck the live account and collection")
            XCTAssertFalse(model.didRecoverMissingCollection)
        }
    }

    func testInterruptedClearOffersExplicitRecoveryWhileOffAndKeepsLocalHistory() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        await model.prepareReset()
        let clear = try XCTUnwrap(model.resetConfirmation)
        await fixture.cloud.setMissing(true)
        await model.confirmReset(clear)
        XCTAssertFalse(model.status.isEnabled)
        XCTAssertTrue(model.status.canRecoverMissingCloudCollection)
        XCTAssertTrue(model.isResetPending)
        XCTAssertTrue(model.offersRetry, "Interrupted cloud clearing must retain Retry while Off")
        XCTAssertEqual(model.missingCollectionHelpKey, .settingsClipboardSyncMissingCollection)
        let writesBefore = await fixture.cloud.writeCount()

        await model.prepareMissingCollectionRecovery()
        XCTAssertNotNil(model.missingCollectionConfirmation)
        model.cancelMissingCollectionRecovery()
        XCTAssertNil(model.missingCollectionConfirmation)
        XCTAssertFalse(model.didRecoverMissingCollection)
        XCTAssertTrue(model.tags.allSatisfy(\.isSelected))
        await model.prepareMissingCollectionRecovery()
        let confirmation = try XCTUnwrap(model.missingCollectionConfirmation)
        // SwiftUI may dismiss its binding before the confirmation Task runs.
        model.cancelMissingCollectionRecovery()
        await model.confirmMissingCollectionRecovery(confirmation)

        XCTAssertFalse(model.operationFailed)
        XCTAssertTrue(model.didRecoverMissingCollection)
        XCTAssertFalse(model.status.isEnabled)
        XCTAssertTrue(model.canChangeEnabled)
        XCTAssertFalse(model.status.canRecoverMissingCloudCollection)
        XCTAssertEqual(model.status.cloudReset?.stage, .superseded)
        XCTAssertEqual(model.tags.count, 1)
        XCTAssertTrue(model.tags.allSatisfy { !$0.isSelected })
        let retained = try await fixture.module.page(.init()).entries
        XCTAssertEqual(retained.map(\.previewText), ["local history survives missing cloud data"])
        let writesAfter = await fixture.cloud.writeCount()
        XCTAssertEqual(writesAfter, writesBefore, "Recovery must not create or clear remote data")
        await fixture.module.resumeSync()
        let stillMissing = try await fixture.cloud.control(for: fixture.cloud.account())
        XCTAssertNil(stillMissing)
        let afterResume = await fixture.cloud.writeCount()
        XCTAssertEqual(afterResume, writesBefore)
    }

    private func makeFixture() async throws -> (
        module: ClipboardHistoryModule, model: ClipboardSyncSettingsModel, cloud: MissingCollectionSettingsCloud
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("missing-settings-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let cloud = MissingCollectionSettingsCloud()
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root,
            keyStore: FileConflictUILocalKey(byte: 0x66), syncServices: .init(
                transport: cloud, keys: FileConflictUIKeys(), pollingInterval: nil)))
        let entry = try await module.capture(.init(source: .unknown, content: .text("local history survives missing cloud data")))
        let tag = try await module.createTagDefinition(named: "Shared", assigningTo: entry.entryID).definition
        try await module.setSyncTagSelected(tag.id, selected: true)
        try await module.setSyncEnabled(true)
        let model = ClipboardSyncSettingsModel(module: module)
        await model.refresh()
        XCTAssertTrue(model.status.isEnabled)
        XCTAssertTrue(model.status.canClearCloudData)
        return (module, model, cloud)
    }

    private func waitForMissingCollection(_ model: ClipboardSyncSettingsModel) async throws {
        for _ in 0..<1_000 {
            await model.refresh()
            if model.status.canRecoverMissingCloudCollection && model.status.phase == .failed(.recoveryRequired) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The queued Retry did not report the missing collection")
    }
}

private enum RecoveryChange { case returnedCollection, account, providerFailure }

/// Replaces only provider calls; encrypted storage and reset state remain in
/// the real module and production Settings model, with a separate test key store.
private actor MissingCollectionSettingsCloud: ClipboardSyncTransport {
    private let backing: any ClipboardSyncTransport = FileConflictUICloud()
    private var missing = false
    private var replacementAccount: ClipboardSyncAccount?
    private var controlReadsFail = false
    private var writes = 0
    private var controlReads = 0

    func setMissing(_ value: Bool) { missing = value }
    func switchAccount() { replacementAccount = .init(container: "test", environment: "test", owner: "another-account") }
    func failControlReads() { controlReadsFail = true }
    func writeCount() -> Int { writes }
    func controlReadCount() -> Int { controlReads }
    func account() async throws -> ClipboardSyncAccount {
        if let replacementAccount { return replacementAccount }
        return try await backing.account()
    }
    func control(for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl? {
        controlReads += 1
        if controlReadsFail { throw ClipboardSyncServiceError.network(retryAfter: nil) }
        if missing { return nil }
        return try await backing.control(for: account)
    }
    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl {
        writes += 1
        return try await backing.createControl(candidate, for: account)
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) async throws -> ClipboardSyncChanges {
        try await backing.changes(for: account, control: control, cursor: cursor)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) async throws -> [Data] {
        try await backing.download(record, for: account)
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl) async throws -> ClipboardSyncControl {
        writes += 1
        return try await backing.commit(upload, for: account, control: control)
    }
    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount,
        control: ClipboardSyncControl, progress: @Sendable (Int64) async throws -> Void) async throws -> ClipboardSyncControl {
        writes += 1
        return try await backing.commitFile(upload, for: account, control: control, progress: progress)
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) async throws -> Data {
        try await backing.downloadFileSegment(record, index: index, for: account)
    }
    func transition(_ control: ClipboardSyncControl, to phase: String, epoch: UUID, for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl {
        writes += 1
        return try await backing.transition(control, to: phase, epoch: epoch, for: account)
    }
    func clearPage(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) async throws -> ClipboardSyncCleanupPage {
        writes += 1
        return try await backing.clearPage(for: account, control: control, cursor: cursor)
    }
    func cancel() async { await backing.cancel() }
}
