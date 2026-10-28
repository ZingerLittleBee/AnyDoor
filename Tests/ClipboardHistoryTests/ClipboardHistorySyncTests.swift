import AppKit
import Foundation
import XCTest
import ClipboardHistoryTestSupport
import os

@testable import ClipboardHistory

final class ClipboardHistorySyncTests: XCTestCase {
    func testCloudResetPreservesLocalHistoryAndKeyButRetiresSharedAuthority() async throws {
        let source = try await recoverySource()
        let account = try await source.cloud.account()
        let before = try await source.cloud.control(for: account)
        let page = try await source.sender.page(.init())
        let confirmation = try await source.sender.prepareCloudReset()
        try await source.sender.clearCloudDataAndStopSync(confirmation)
        let status = await source.sender.syncStatus()
        XCTAssertFalse(status.isEnabled)
        XCTAssertEqual(status.cloudReset?.stage, .completed)
        let after = try await source.cloud.control(for: account)
        XCTAssertEqual(after?.phase, "stopped")
        XCTAssertNotEqual(after?.epoch, before?.epoch)
        XCTAssertEqual(after?.keyID, before?.keyID)
        let uploads = await source.cloud.currentUploads()
        XCTAssertTrue(uploads.isEmpty)
        let keyCount = await source.keys.count()
        XCTAssertEqual(keyCount, 1)
        let retained = try await source.sender.page(.init())
        XCTAssertEqual(retained.entries.map(\.id), page.entries.map(\.id))
        await source.sender.resumeSync()
        let stillStopped = try await source.cloud.control(for: account)
        XCTAssertEqual(stillStopped, after)
    }

    func testCloudResetRequiresManualNewEpochAndTagSelectionOnBothDevices() async throws {
        let source = try await recoverySource()
        let peer = makeModule(services: .init(transport: source.cloud, keys: source.keys, pollingInterval: nil), keyByte: 0x21, time: 2_000)
        try await peer.setSyncEnabled(true)
        await peer.suspendSync()
        let account = try await source.cloud.account()
        let old = try await source.cloud.control(for: account)
        let replay = await source.cloud.currentUploads().last!
        let confirmation = try await source.sender.prepareCloudReset()
        try await source.sender.clearCloudDataAndStopSync(confirmation)
        do {
            _ = try await source.cloud.commit(replay, for: account, control: old!)
            XCTFail("A delayed writer must lose retired authority")
        } catch ClipboardSyncServiceError.missingRemoteState { }
        await peer.resumeSync()
        let peerStatus = await peer.syncStatus()
        XCTAssertFalse(peerStatus.isEnabled)
        let retained = try await peer.page(.init())
        XCTAssertEqual(retained.entries.count, 1)
        try await source.sender.setSyncEnabled(true)
        let active = try await source.cloud.control(for: account)
        XCTAssertEqual(active?.phase, "active")
        XCTAssertEqual(active?.keyID, old?.keyID)
        XCTAssertNotEqual(active?.epoch, old?.epoch)
        let empty = await source.cloud.currentUploads()
        XCTAssertTrue(empty.isEmpty)
        let tags = try await source.sender.syncTags()
        XCTAssertTrue(tags.allSatisfy { !$0.isSelected })
        try await source.sender.setSyncTagSelected(source.tag, selected: true)
        let newUploads = await source.cloud.currentUploads()
        XCTAssertEqual(newUploads.filter { $0.record.kind == .entry }.count, 1)
        XCTAssertTrue(newUploads.allSatisfy { $0.record.epoch == active?.epoch })
        await peer.resumeSync()
        let unchanged = await peer.syncStatus()
        XCTAssertFalse(unchanged.isEnabled)
    }

    func testCloudResetLostResponsesResumeAcrossReopenWithoutReplacingKey() async throws {
        for lostPhase in ["resetting", "cleanup", "stopped"] {
            let cloud = SyncTestCloud()
            let keys = SyncTestKeys()
            let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-reset-\(UUID())")
            let first = makeModule(services: services, keyByte: 0x23, time: 1_000, root: root)
            let entry = try await first.capture(.init(source: .unknown, content: .text("retained after interrupted cloud reset")))
            let tag = try await first.createTagDefinition(named: "Reset", assigningTo: entry.entryID)
            try await first.setSyncTagSelected(tag.definition.id, selected: true)
            try await first.setSyncEnabled(true)
            let confirmation = try await first.prepareCloudReset()
            await cloud.loseNextResetResponse(at: lostPhase)
            try await first.clearCloudDataAndStopSync(confirmation)
            let failed = await first.syncStatus()
            XCTAssertFalse(failed.isEnabled)
            XCTAssertNotEqual(failed.cloudReset?.stage, .completed)
            XCTAssertEqual(failed.cloudReset?.failure, .failed(.network))
            try await first.closeStoreForTesting()
            let reopened = makeModule(services: services, keyByte: 0x23, time: 2_000, root: root)
            await reopened.resumeSync()
            let completed = await reopened.syncStatus()
            XCTAssertEqual(completed.cloudReset?.stage, .completed)
            let uploads = await cloud.currentUploads()
            XCTAssertTrue(uploads.isEmpty)
            let keyCount = await keys.count()
            XCTAssertEqual(keyCount, 1)
            let local = try await reopened.page(.init())
            XCTAssertEqual(local.entries.map(\.id), [entry.entryID])
        }
    }

    func testCloudResetConfirmationCannotRetargetAnotherAccount() async throws {
        let source = try await recoverySource()
        let account = try await source.cloud.account()
        let before = try await source.cloud.control(for: account)
        let confirmation = try await source.sender.prepareCloudReset()
        await source.cloud.switchAccount(to: "other-account")
        try await source.sender.clearCloudDataAndStopSync(confirmation)
        let status = await source.sender.syncStatus()
        XCTAssertEqual(status.cloudReset?.failure, .failed(.accountChanged))
        let other = try await source.cloud.account()
        let untouched = try await source.cloud.control(for: other)
        XCTAssertNil(untouched)
        await source.cloud.switchAccount(to: account.owner)
        let unchanged = try await source.cloud.control(for: account)
        XCTAssertEqual(unchanged, before)
        await source.sender.retrySync()
        let completed = await source.sender.syncStatus()
        XCTAssertEqual(completed.cloudReset?.stage, .completed)
    }

    func testCloudResetRetryAfterDisablingRetainsThePendingClear() async throws {
        let source = try await recoverySource()
        let confirmation = try await source.sender.prepareCloudReset()
        await source.cloud.loseNextResetResponse(at: "resetting")
        try await source.sender.clearCloudDataAndStopSync(confirmation)
        try await source.sender.setSyncEnabled(false)
        await source.sender.retrySync()
        let status = await source.sender.syncStatus()
        XCTAssertEqual(status.cloudReset?.stage, .completed)
        XCTAssertFalse(status.isEnabled)
    }

    func testCloudResetAccountSwitchDuringCleanupDoesNotTouchTheNewAccount() async throws {
        let source = try await recoverySource()
        let confirmation = try await source.sender.prepareCloudReset()
        await source.cloud.holdNextClear()
        let reset = Task { try await source.sender.clearCloudDataAndStopSync(confirmation) }
        await source.cloud.waitForHeldClear()
        await source.cloud.switchAccount(to: "changed-during-clear")
        await source.cloud.releaseClear()
        try await reset.value
        let status = await source.sender.syncStatus()
        XCTAssertEqual(status.cloudReset?.failure, .failed(.accountChanged))
        let other = try await source.cloud.account()
        let otherControl = try await source.cloud.control(for: other)
        XCTAssertNil(otherControl)
        let uploads = await source.cloud.currentUploads()
        XCTAssertTrue(uploads.isEmpty)
    }

    func testCloudResetLateCleanupCannotPersistIntoAReplacementLocalStore() async throws {
        let source = try await recoverySource()
        let confirmation = try await source.sender.prepareCloudReset()
        await source.cloud.holdNextClear()
        let clearing = Task { try await source.sender.clearCloudDataAndStopSync(confirmation) }
        await source.cloud.waitForHeldClear()
        let cancellation = await source.cloud.cancellationCount()
        let localReset = Task { try await source.sender.reset(confirmation: .confirmed) }
        await source.cloud.waitForCancellation(after: cancellation)
        await source.cloud.releaseClear()
        try await clearing.value
        try await localReset.value
        let status = await source.sender.syncStatus()
        XCTAssertNil(status.cloudReset)
        XCTAssertFalse(status.isEnabled)
        let page = try await source.sender.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
        let keyCount = await source.keys.count()
        XCTAssertEqual(keyCount, 1)
        let account = try await source.cloud.account()
        let control = try await source.cloud.control(for: account)
        XCTAssertEqual(control?.phase, "resetting")
    }

    func testCloudResetFailureBeforeRetirementNeverBootstrapsMissingControl() async throws {
        let source = try await recoverySource()
        let confirmation = try await source.sender.prepareCloudReset()
        let initialAttempts = await source.cloud.controlCreationAttempts()
        await source.cloud.removeControl()
        try await source.sender.clearCloudDataAndStopSync(confirmation)
        let status = await source.sender.syncStatus()
        XCTAssertEqual(status.cloudReset?.failure, .failed(.recoveryRequired))
        XCTAssertNotEqual(status.cloudReset?.stage, .completed)
        let attempts = await source.cloud.controlCreationAttempts()
        XCTAssertEqual(attempts, initialAttempts)
        let local = try await source.sender.page(.init())
        XCTAssertEqual(local.entries.count, 1)
        let uploads = await source.cloud.currentUploads()
        XCTAssertFalse(uploads.isEmpty)
    }

    func testCloudResetRetirementPreventsNewWritesBeforeCleanupCompletes() async throws {
        let source = try await recoverySource()
        let account = try await source.cloud.account()
        let observed = try await source.cloud.control(for: account)
        let old = try XCTUnwrap(observed)
        let observedUploads = await source.cloud.currentUploads()
        let upload = try XCTUnwrap(observedUploads.last)
        let confirmation = try await source.sender.prepareCloudReset()
        await source.cloud.holdNextClear()
        let clearing = Task { try await source.sender.clearCloudDataAndStopSync(confirmation) }
        await source.cloud.waitForHeldClear()
        do {
            _ = try await source.cloud.commit(upload, for: account, control: old)
            XCTFail("An old writer cannot publish while cleanup is pending")
        } catch ClipboardSyncServiceError.missingRemoteState { }
        let inProgress = await source.sender.syncStatus()
        XCTAssertEqual(inProgress.cloudReset?.stage, .clearing)
        XCTAssertNil(inProgress.cloudReset?.failure)
        await source.cloud.releaseClear()
        try await clearing.value
        let complete = await source.sender.syncStatus()
        XCTAssertEqual(complete.cloudReset?.stage, .completed)
    }

    func testCloudResetLateRetryCannotClearANewManuallyActivatedCollection() async throws {
        let source = try await recoverySource()
        let confirmation = try await source.sender.prepareCloudReset()
        await source.cloud.loseNextResetResponse(at: "stopped")
        try await source.sender.clearCloudDataAndStopSync(confirmation)
        let peer = makeModule(services: .init(transport: source.cloud, keys: source.keys, pollingInterval: nil), keyByte: 0x26, time: 2_000)
        try await peer.setSyncEnabled(true)
        let account = try await source.cloud.account()
        let active = try await source.cloud.control(for: account)
        await source.sender.retrySync()
        let after = try await source.cloud.control(for: account)
        XCTAssertEqual(after, active)
        let stopped = await source.sender.syncStatus()
        XCTAssertFalse(stopped.isEnabled)
        XCTAssertNotEqual(stopped.cloudReset?.stage, .completed)
        try await source.sender.setSyncEnabled(true)
        let enabled = await source.sender.syncStatus()
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertEqual(enabled.phase, .upToDate)
        let uploads = await source.cloud.currentUploads()
        XCTAssertTrue(uploads.isEmpty)
    }

    func testLostSuccessfulBootstrapReopensTheSameWinnerAfterPeerProgress() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-bootstrap-receipt-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x61, time: 1_000, root: root)
        let entry = try await first.capture(.init(source: .unknown, content: .text("original pending text")))
        let tag = try await first.createTagDefinition(named: "Original tag", assigningTo: entry.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        await cloud.loseNextControlResponse()
        try await first.setSyncEnabled(true)
        let interrupted = await first.syncStatus()
        XCTAssertEqual(interrupted.phase, .failed(.network))
        let account = try await cloud.account()
        let winner = try await cloud.control(for: account)
        try await first.closeStoreForTesting()

        let peer = makeModule(services: services, keyByte: 0x62, time: 2_000)
        let peerEntry = try await peer.capture(.init(source: .unknown, content: .text("peer progression")))
        let peerTag = try await peer.createTagDefinition(named: "Peer tag", assigningTo: peerEntry.entryID)
        try await peer.setSyncTagSelected(peerTag.definition.id, selected: true)
        try await peer.setSyncEnabled(true)
        let reopened = makeModule(services: services, keyByte: 0x61, time: 3_000, root: root)
        await reopened.resumeSync()
        await reopened.retrySync()
        await peer.retrySync()
        let after = try await cloud.control(for: account)
        XCTAssertEqual(after?.keyID, winner?.keyID)
        let attempts = await cloud.controlCreationAttempts()
        XCTAssertEqual(attempts.count, 1)
        let keyCount = await keys.count()
        XCTAssertEqual(keyCount, 1)
        let firstPage = try await reopened.page(.init())
        let peerPage = try await peer.page(.init())
        XCTAssertEqual(firstPage.entries.count, 2)
        XCTAssertEqual(peerPage.entries.count, 2)
    }

    func testAccountChangeDuringKeyDeliveryRejectsTheOldResponse() async throws {
        let source = try await recoverySource()
        let held = SyncTestFaultKeys(backing: source.keys, fault: nil)
        await held.holdNextLoad()
        let receiver = makeModule(services: .init(transport: source.cloud, keys: held, pollingInterval: nil), keyByte: 0x72, time: 2_000)
        let activation = Task { try await receiver.setSyncEnabled(true) }
        await held.waitForHeldLoad()
        await source.cloud.switchAccount(to: "new-account")
        await held.releaseLoad()
        try await activation.value
        let status = await receiver.syncStatus()
        XCTAssertFalse(status.isEnabled)
        XCTAssertEqual(status.phase, .failed(.accountChanged))
        let page = try await receiver.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
        let newAccountUploads = await source.cloud.currentUploads()
        XCTAssertTrue(newAccountUploads.isEmpty)
        let keyCount = await source.keys.count()
        XCTAssertEqual(keyCount, 1)
    }

    func testDisableDuringKeyDeliveryKeepsTheSharedKeyAndPeerWorking() async throws {
        let source = try await recoverySource()
        let held = SyncTestFaultKeys(backing: source.keys, fault: nil)
        await held.holdNextLoad()
        let receiver = makeModule(services: .init(transport: source.cloud, keys: held, pollingInterval: nil), keyByte: 0x73, time: 2_000)
        let activation = Task { try await receiver.setSyncEnabled(true) }
        await held.waitForHeldLoad()
        let cancellation = await source.cloud.cancellationCount()
        let disabling = Task { try await receiver.setSyncEnabled(false) }
        await source.cloud.waitForCancellation(after: cancellation)
        await held.releaseLoad()
        try await activation.value
        try await disabling.value
        let disabled = await receiver.syncStatus()
        XCTAssertFalse(disabled.isEnabled)
        let page = try await receiver.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
        let fresh = try await source.sender.capture(.init(source: .unknown, content: .text("peer remains enabled")))
        _ = try await source.sender.apply(.setTags(fresh.entryID, [source.tag]))
        await source.sender.retrySync()
        let uploads = await source.cloud.currentUploads()
        XCTAssertEqual(uploads.filter { $0.record.kind == .entry }.count, 2)
        let keyCount = await source.keys.count()
        XCTAssertEqual(keyCount, 1)
    }

    func testLocalResetDuringKeyDeliveryCannotImportIntoTheReplacementStore() async throws {
        let source = try await recoverySource()
        let held = SyncTestFaultKeys(backing: source.keys, fault: nil)
        await held.holdNextLoad()
        let receiver = makeModule(services: .init(transport: source.cloud, keys: held, pollingInterval: nil), keyByte: 0x74, time: 2_000)
        let activation = Task { try await receiver.setSyncEnabled(true) }
        await held.waitForHeldLoad()
        let beforeReset = await source.cloud.currentUploads()
        let cancellation = await source.cloud.cancellationCount()
        let resetting = Task { try await receiver.reset(confirmation: .confirmed) }
        await source.cloud.waitForCancellation(after: cancellation)
        await held.releaseLoad()
        try await activation.value
        try await resetting.value
        let status = await receiver.syncStatus()
        XCTAssertFalse(status.isEnabled)
        let page = try await receiver.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
        let afterReset = await source.cloud.currentUploads()
        XCTAssertEqual(afterReset, beforeReset)
        let keyCount = await source.keys.count()
        XCTAssertEqual(keyCount, 1)
    }

    func testAccountChangeWhileQuitPersistsTheNeedForNewActivation() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-account-recovery-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x75, time: 1_000, root: root)
        let local = try await first.capture(.init(source: .unknown, content: .text("retained account A text")))
        let tag = try await first.createTagDefinition(named: "Account A tag", assigningTo: local.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await first.closeStoreForTesting()
        await cloud.switchAccount(to: "account-after-relaunch")
        let reopened = makeModule(services: services, keyByte: 0x75, time: 2_000, root: root)
        await reopened.resumeSync()
        try await reopened.closeStoreForTesting()
        let again = makeModule(services: services, keyByte: 0x75, time: 3_000, root: root)
        let stopped = await again.syncStatus()
        XCTAssertFalse(stopped.isEnabled)
        XCTAssertEqual(stopped.phase, .failed(.accountChanged))
        await again.resumeSync()
        let unpublished = await cloud.currentUploads()
        XCTAssertTrue(unpublished.isEmpty)
        try await again.setSyncEnabled(true)
        let afterActivation = await cloud.currentUploads()
        XCTAssertTrue(afterActivation.isEmpty)
        let retained = try await again.page(.init())
        XCTAssertEqual(retained.entries.map(\.id), [local.entryID])
    }

    func testTemporaryAccountLossResumesPendingTextWithoutChangingItsKey() async throws {
        let source = try await recoverySource()
        let fresh = try await source.sender.capture(.init(source: .unknown, content: .text("pending through account outage")))
        _ = try await source.sender.apply(.setTags(fresh.entryID, [source.tag]))
        await source.cloud.failNextAccountRead(with: .accountUnavailable)
        await source.sender.retrySync()
        let waiting = await source.sender.syncStatus()
        XCTAssertEqual(waiting.phase, .waitingForAccount)
        let local = try await source.sender.materialize(.init(entryID: fresh.entryID, purpose: .plainTextPaste))
        XCTAssertFalse(local.items.isEmpty)
        await source.sender.retrySync()
        await source.sender.retrySync()
        let uploads = await source.cloud.currentUploads()
        XCTAssertEqual(uploads.filter { $0.record.kind == .entry }.count, 2)
        let keyCount = await source.keys.count()
        XCTAssertEqual(keyCount, 1)
    }

    private func recoverySource() async throws -> (cloud: SyncTestCloud, keys: SyncTestKeys, sender: ClipboardHistoryModule, tag: String) {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let sender = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x71, time: 1_000)
        let entry = try await sender.capture(.init(source: .unknown, content: .text("account-bound source")))
        let tag = try await sender.createTagDefinition(named: "Source tag", assigningTo: entry.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        return (cloud, keys, sender, tag.definition.id)
    }

    func testLockedKeySurvivesRestartAndUnlockResumesWithoutReplacingCiphertext() async throws {
        try await assertKeyRecovery(fault: .keyLocked, expected: .keyLocked)
    }

    func testDeniedKeyAccessRemainsDistinctAndRecoveryPreservesHistory() async throws {
        try await assertKeyRecovery(fault: .accessDenied, expected: .accessDenied)
    }

    func testUnavailableKeyWaitsWithoutDiagnosingSystemSyncSettings() async throws {
        try await assertKeyRecovery(fault: .keyUnavailable, expected: .waitingForKey)
    }

    func testWrongSelectedKeyPreservesCiphertextUntilTheCorrectKeyReturns() async throws {
        try await assertKeyRecovery(fault: nil, expected: .failed(.corruptData), wrongKey: true)
    }

    private func assertKeyRecovery(fault: ClipboardSyncServiceError?, expected: ClipboardHistorySyncPhase,
                                   wrongKey: Bool = false) async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let sender = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x31, time: 1_000)
        let captured = try await sender.capture(.init(source: .unknown, content: .text("encrypted source")))
        let tag = try await sender.createTagDefinition(named: "Private tag", assigningTo: captured.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        let originalCiphertext = await cloud.currentUploads()
        let unavailable = SyncTestFaultKeys(backing: keys, fault: fault, wrongKey: wrongKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-key-recovery-\(UUID())")
        let services = ClipboardSyncServices(transport: cloud, keys: unavailable, pollingInterval: nil)
        let receiver = makeModule(services: services, keyByte: 0x32, time: 2_000, root: root)
        let local = try await receiver.capture(.init(source: .unknown, content: .text("still local")))
        try await receiver.setSyncEnabled(true)
        let failure = await receiver.syncStatus()
        XCTAssertEqual(failure.phase, expected)
        try await receiver.closeStoreForTesting()
        let reopened = makeModule(services: services, keyByte: 0x32, time: 3_000, root: root)
        let persisted = await reopened.syncStatus()
        XCTAssertEqual(persisted.phase, expected)
        await reopened.resumeSync()
        let beforeRecovery = try await reopened.page(.init())
        XCTAssertEqual(beforeRecovery.entries.map(\.id), [local.entryID])
        let preservedCiphertext = await cloud.currentUploads()
        XCTAssertEqual(preservedCiphertext, originalCiphertext)
        await unavailable.recover()
        await reopened.retrySync()
        await reopened.retrySync()
        let afterRecovery = try await reopened.page(.init())
        XCTAssertEqual(afterRecovery.entries.count, 2)
        let recovered = await reopened.syncStatus()
        XCTAssertEqual(recovered.phase, .upToDate)
        XCTAssertEqual(recovered.receivedEntryCount, 1)
        let keyCount = await keys.count()
        XCTAssertEqual(keyCount, 1)
        let finalCiphertext = await cloud.currentUploads()
        XCTAssertEqual(finalCiphertext, originalCiphertext)
    }

    func testProviderBackoffAndFailureSurviveRestartWithoutEarlyCloudAccess() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-sync-recovery-\(UUID())")
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x41, time: 1_000, root: root,
            clock: { clock.withLock { $0 } })
        try await first.setSyncEnabled(true)
        await cloud.failNextAccountRead(retryAfter: 120)
        await first.retrySync()
        try await first.closeStoreForTesting()

        let reopened = makeModule(services: services, keyByte: 0x41, time: 1_000, root: root,
            clock: { clock.withLock { $0 } })
        let restored = await reopened.syncStatus()
        XCTAssertEqual(restored.phase, .failed(.network))
        let readsBefore = await cloud.accountReadCount()
        await reopened.resumeSync()
        let readsDuringBackoff = await cloud.accountReadCount()
        XCTAssertEqual(readsDuringBackoff, readsBefore)
        clock.withLock { $0 = $0.addingTimeInterval(120) }
        await reopened.retrySync()
        let recovered = await reopened.syncStatus()
        XCTAssertEqual(recovered.phase, .upToDate)
        let keyCount = await keys.count()
        XCTAssertEqual(keyCount, 1)
    }

    func testDisableRevokesActivationDeferredByProviderBackoff() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x17,
            time: 1_000, clock: { clock.withLock { $0 } })
        try await module.setSyncEnabled(true)
        await cloud.failNextAccountRead(retryAfter: 120)
        await module.retrySync()
        await cloud.switchAccount(to: "account-B")
        try await module.setSyncEnabled(true)
        try await module.setSyncEnabled(false)
        let readsBeforeDeadline = await cloud.accountReadCount()
        clock.withLock { $0 = $0.addingTimeInterval(120) }
        await module.retrySync()
        let status = await module.syncStatus()
        let readsAfterDeadline = await cloud.accountReadCount()
        let keyCount = await keys.count()
        XCTAssertFalse(status.isEnabled)
        XCTAssertEqual(readsAfterDeadline, readsBeforeDeadline)
        XCTAssertEqual(keyCount, 1)
    }

    func testExplicitNewAccountActivationSurvivesProviderBackoff() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x16,
            time: 1_000, clock: { clock.withLock { $0 } })
        try await module.setSyncEnabled(true)
        await cloud.failNextAccountRead(retryAfter: 120)
        await module.retrySync()
        await cloud.switchAccount(to: "explicitly-enabled-account-B")
        try await module.setSyncEnabled(false)
        try await module.setSyncEnabled(true)
        clock.withLock { $0 = $0.addingTimeInterval(120) }
        await module.retrySync()
        let status = await module.syncStatus()
        let keyCount = await keys.count()
        XCTAssertTrue(status.isEnabled)
        XCTAssertEqual(status.phase, .upToDate)
        XCTAssertEqual(keyCount, 2)
    }

    func testDamagedCiphertextDoesNotImportAndRetryKeepsTheUnreadCursor() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x14, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x15, time: 2_000)
        let captured = try await first.capture(.init(source: .unknown, content: .text("authenticated history")))
        let tag = try await first.createTagDefinition(named: "Authenticated", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        await cloud.damageNextDownload()
        try await second.setSyncEnabled(true)
        let rejected = await second.syncStatus()
        let empty = try await second.page(.init())
        XCTAssertEqual(rejected.phase, .failed(.corruptData))
        XCTAssertTrue(empty.entries.isEmpty)
        await second.retrySync()
        let recovered = try await second.page(.init())
        XCTAssertEqual(recovered.entries.count, 1)
        let complete = await second.syncStatus()
        XCTAssertEqual(complete.phase, .upToDate)
    }

    func testRetryWaitsForProviderDelayBeforeConsultingCloudAgain() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x13,
            time: 1_000, clock: { clock.withLock { $0 } })
        await cloud.failNextAccountRead(retryAfter: 120)
        try await module.setSyncEnabled(true)
        let waiting = await module.syncStatus()
        XCTAssertEqual(waiting.phase, .failed(.network))
        await module.retrySync()
        let earlyReads = await cloud.accountReadCount()
        XCTAssertEqual(earlyReads, 1)
        clock.withLock { $0 = $0.addingTimeInterval(120) }
        await module.retrySync()
        let recovered = await module.syncStatus()
        XCTAssertEqual(recovered.phase, .upToDate)
    }

    func testRemoteTagInNewAccountDoesNotAuthorizeOldAccountHistory() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x11, time: 1_000)
        let captured = try await first.capture(.init(source: .unknown, content: .text("account A private text")))
        let tag = try await first.createTagDefinition(named: "Retained identity", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)

        await cloud.switchAccount(to: "account-B")
        await first.retrySync()
        let peer = makeModule(services: services, keyByte: 0x12, time: 2_000)
        _ = try await peer.replaceTagDefinitions(with: [tag.definition])
        try await peer.setSyncTagSelected(tag.definition.id, selected: true)
        try await peer.setSyncEnabled(true)
        try await first.setSyncEnabled(true)
        let beforeAuthorization = await cloud.currentUploads()
        XCTAssertTrue(beforeAuthorization.allSatisfy { $0.record.kind == .tag })

        let fresh = try await first.capture(.init(source: .unknown, content: .text("new account B text")))
        _ = try await first.apply(.setTags(fresh.entryID, [tag.definition.id]))
        await first.retrySync()
        let afterFreshCapture = await cloud.currentUploads()
        XCTAssertEqual(afterFreshCapture.filter { $0.record.kind == .entry }.count, 1)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        let afterExplicitSelection = await cloud.currentUploads()
        XCTAssertEqual(afterExplicitSelection.filter { $0.record.kind == .entry }.count, 2)
    }

    func testInterruptedBootstrapWaitsForItsJournaledCandidateKeyBeforePublishingControl() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-sync-bootstrap-\(UUID())")
        let first = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x19, time: 1_000, root: root)
        await cloud.failNextControlCreation()
        try await first.setSyncEnabled(true)
        let interrupted = await first.syncStatus()
        XCTAssertEqual(interrupted.phase, .failed(.network))
        try await first.closeStoreForTesting()

        let delayedKeys = SyncTestDelayedKeys(backing: keys)
        let reopened = makeModule(services: .init(transport: cloud, keys: delayedKeys, pollingInterval: nil), keyByte: 0x19, time: 2_000, root: root)
        await reopened.resumeSync()
        let waiting = await reopened.syncStatus()
        let account = try await cloud.account()
        let unpublished = try await cloud.control(for: account)
        let waitingAttempts = await cloud.controlCreationAttempts()
        XCTAssertEqual(waiting.phase, .waitingForKey)
        XCTAssertNil(unpublished)
        XCTAssertEqual(waitingAttempts.count, 1)

        await delayedKeys.deliver()
        await reopened.retrySync()
        let published = try await cloud.control(for: account)
        let allAttempts = await cloud.controlCreationAttempts()
        let keyCount = await keys.count()
        XCTAssertEqual(published?.keyID, waitingAttempts.first)
        XCTAssertEqual(Set(allAttempts).count, 1)
        XCTAssertEqual(keyCount, 1)
        let completed = await reopened.syncStatus()
        XCTAssertEqual(completed.phase, .upToDate)
    }

    func testLaterDisableWinsWhenEarlierEnableFinishesCancellationLate() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x18, time: 1_000)
        await cloud.holdNextCancellation()
        let enabling = Task { try await module.setSyncEnabled(true) }
        await cloud.waitForHeldCancellation()
        try await module.setSyncEnabled(false)
        await cloud.releaseCancellation()
        try await enabling.value
        let status = await module.syncStatus()
        let accountReads = await cloud.accountReadCount()
        let keyCount = await keys.count()
        XCTAssertFalse(status.isEnabled)
        XCTAssertEqual(status.phase, .disabled)
        XCTAssertEqual(accountReads, 0)
        XCTAssertEqual(keyCount, 0)
    }

    func testDisabledResumeDoesNotConsultCloudOrCreateSyncKeys() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x21, time: 1_000)
        await module.resumeSync()
        let reads = await cloud.accountReadCount()
        let keyCount = await keys.count()
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(keyCount, 0)
        let records = await cloud.currentUploads()
        XCTAssertTrue(records.isEmpty)
    }

    func testSimultaneousFirstUseSelectsOneKeyAndBothDevicesReadTheCollection() async throws {
        let cloud = SyncTestCloud()
        await cloud.rendezvousInitialControlReads()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x23, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x24, time: 2_000)
        let entry = try await first.capture(.init(source: .unknown, content: .text("one agreed key")))
        let tag = try await first.createTagDefinition(named: "Race", assigningTo: entry.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        async let enableFirst: Void = first.setSyncEnabled(true)
        async let enableSecond: Void = second.setSyncEnabled(true)
        _ = try await (enableFirst, enableSecond)
        await first.retrySync()
        await second.retrySync()
        let created = await keys.count()
        XCTAssertEqual(created, 2, "Both isolated candidates must exist before the server chooses its winner")
        let published = await cloud.currentUploads()
        XCTAssertEqual(Set(published.map(\.record.keyID)).count, 1)
        let page = try await second.page(.init())
        XCTAssertEqual(page.entries.count, 1)
        let final = await second.syncStatus()
        XCTAssertEqual(final.phase, .upToDate)
    }

    func testLargeTextUsesEncryptedChunksAndDoesNotShareAnUnselectedTag() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x25, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x26, time: 2_000)
        let value = String(repeating: "z", count: 4 * 1_024 * 1_024) + " confidential end marker"
        let entry = try await first.capture(.init(source: .unknown, content: .text(value)))
        let shared = try await first.createTagDefinition(named: "Shared secret label", assigningTo: entry.entryID)
        _ = try await first.createTagDefinition(named: "Local private label", assigningTo: entry.entryID)
        try await first.setSyncTagSelected(shared.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        let uploads = await cloud.currentUploads()
        let textUpload = try XCTUnwrap(uploads.first { $0.record.kind == .entry })
        XCTAssertGreaterThan(textUpload.chunks.count, 1)
        for upload in uploads {
            let metadata = try JSONEncoder().encode(upload.record)
            for data in [metadata] + upload.chunks {
                XCTAssertNil(data.range(of: Data("Shared secret label".utf8)))
                XCTAssertNil(data.range(of: Data("Local private label".utf8)))
                XCTAssertNil(data.range(of: Data("confidential end marker".utf8)))
            }
        }
        try await second.setSyncEnabled(true)
        let tags = try await second.tagDefinitions()
        XCTAssertEqual(tags.map(\.id), [shared.definition.id])
        let page = try await second.page(.init())
        let received = try XCTUnwrap(page.entries.first)
        let materialized = try await second.materialize(.init(entryID: received.id, purpose: .plainTextPaste))
        XCTAssertEqual(materialized.items.first?.representations, [.text(typeIdentifier: "public.utf8-plain-text", value: value)])
    }

    func testMissingPreviouslyObservedControlNeverReinitializesOrReplacesKey() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x28, time: 1_000)
        try await module.setSyncEnabled(true)
        await cloud.removeControl()
        await module.retrySync()
        let status = await module.syncStatus()
        XCTAssertEqual(status.phase, .failed(.recoveryRequired))
        let count = await keys.count()
        XCTAssertEqual(count, 1)
        let account = try await cloud.account()
        let control = try await cloud.control(for: account)
        XCTAssertNil(control)
    }

    func testLostCommitResponseAndRestartReuseFrozenOperationWithoutDuplicateImport() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-sync-restart-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x51, time: 1_000, root: root)
        let second = makeModule(services: services, keyByte: 0x52, time: 2_000)
        let captured = try await first.capture(.init(source: .unknown, content: .text("survives lost response")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        await cloud.loseNextEntryCommitResponse()
        try await first.setSyncEnabled(true)
        let interrupted = await first.syncStatus()
        XCTAssertEqual(interrupted.phase, .failed(.network))
        try await first.closeStoreForTesting()

        try await second.setSyncEnabled(true)
        let next = try await second.capture(.init(source: .unknown, content: .text("peer advances control")))
        _ = try await second.apply(.setTags(next.entryID, [tag.definition.id]))
        await second.retrySync()
        let publishedBeforeRetry = await cloud.currentUploads()
        let reopened = makeModule(services: services, keyByte: 0x51, time: 3_000, root: root)
        await reopened.resumeSync()
        await reopened.retrySync()
        await second.retrySync()
        let publishedAfterRetry = await cloud.currentUploads()
        XCTAssertEqual(publishedAfterRetry, publishedBeforeRetry)
        let received = try await second.page(.init())
        let restored = try await reopened.page(.init())
        XCTAssertEqual(received.entries.count, 2)
        XCTAssertEqual(restored.entries.count, 2)
        let restoredState = await reopened.syncStatus()
        XCTAssertEqual(restoredState.phase, .upToDate)
        XCTAssertEqual(restoredState.uploadedEntryCount, 1)
    }

    func testDelayedSharedKeyWaitsWithoutReplacingCiphertextAndResumes() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let first = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x61, time: 1_000)
        let entry = try await first.capture(.init(source: .unknown, content: .text("wait for system key delivery")))
        let tag = try await first.createTagDefinition(named: "Secret label", assigningTo: entry.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        let encryptedBefore = await cloud.currentUploads()
        let delayedKeys = SyncTestDelayedKeys(backing: keys)
        let second = makeModule(services: .init(transport: cloud, keys: delayedKeys, pollingInterval: nil), keyByte: 0x62, time: 2_000)
        try await second.setSyncEnabled(true)
        let waiting = await second.syncStatus()
        XCTAssertEqual(waiting.phase, .waitingForKey)
        let empty = try await second.page(.init())
        XCTAssertTrue(empty.entries.isEmpty)
        let encryptedAfter = await cloud.currentUploads()
        XCTAssertEqual(encryptedAfter, encryptedBefore)
        let keyCount = await keys.count()
        XCTAssertEqual(keyCount, 1)
        await delayedKeys.deliver()
        await second.retrySync()
        let page = try await second.page(.init())
        XCTAssertEqual(page.entries.count, 1)
        let complete = await second.syncStatus()
        XCTAssertEqual(complete.phase, .upToDate)
    }

    func testUnsignedNativeServicesFailBeforeAccountOrKeychainAccess() async throws {
        let module = makeModule(services: .production(), keyByte: 0x71, time: 1_000)
        let local = try await module.capture(.init(source: .unknown, content: .text("still usable")))
        try await module.setSyncEnabled(true)
        let status = await module.syncStatus()
        XCTAssertEqual(status.phase, .capabilityUnavailable)
        XCTAssertTrue(status.isEnabled)
        XCTAssertNil(status.lastCompletedAt)
        let page = try await module.page(.init())
        XCTAssertEqual(page.entries.map(\.id), [local.entryID])
    }

    func testAccountChangeDisablesDeviceAndRequiresFreshSelectionForNewAccount() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x39, time: 1_000)
        let entry = try await module.capture(.init(source: .unknown, content: .text("account A only")))
        let tag = try await module.createTagDefinition(named: "Account A", assigningTo: entry.entryID)
        try await module.setSyncTagSelected(tag.definition.id, selected: true)
        try await module.setSyncEnabled(true)
        await cloud.switchAccount(to: "second-user")
        await module.retrySync()
        let stopped = await module.syncStatus()
        XCTAssertFalse(stopped.isEnabled)
        XCTAssertEqual(stopped.phase, .failed(.accountChanged))
        try await module.setSyncEnabled(true)
        let afterManualActivation = await module.syncStatus()
        XCTAssertTrue(afterManualActivation.isEnabled)
        let choices = try await module.syncTags()
        XCTAssertTrue(choices.allSatisfy { !$0.isSelected })
        let cloudRecords = await cloud.currentUploads()
        XCTAssertTrue(cloudRecords.isEmpty)
        let local = try await module.page(.init())
        XCTAssertEqual(local.entries.map(\.id), [entry.entryID])
    }

    @MainActor
    func testSelectedTextArrivesAsHistoryWithOriginalProvenanceAndNoPasteboardWrite() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x31, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x42, time: 2_000)
        let source = ClipboardHistoryCaptureSource(bundleIdentifier: "example.editor", displayName: "Editor")
        let captured = try await first.capture(ClipboardHistoryCaptureRequest(
            source: source, content: .text("private example \t\r\n")
        ))
        let tag = try await first.createTagDefinition(named: "Shared work", assigningTo: captured.entryID)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-tests.\(UUID())"))
        pasteboard.clearContents()
        pasteboard.setString("leave this alone", forType: .string)
        let generation = pasteboard.changeCount

        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        let secondBeforeActivation = await second.syncStatus()
        XCTAssertFalse(secondBeforeActivation.isEnabled)
        try await second.setSyncEnabled(true)
        let page = try await second.page(ClipboardHistoryQuery(tagID: tag.definition.id))
        XCTAssertEqual(page.entries.count, 1)
        let received = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(received.capturedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(received.source, source)
        let materialization = try await second.materialize(.init(entryID: received.id, purpose: .normalPaste))
        XCTAssertEqual(materialization.items, [ClipboardHistoryMaterializedItem(representations: [
            .text(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, value: "private example \t\r\n")
        ])])
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.string(forType: .string), "leave this alone")
        let firstStatus = await first.syncStatus()
        let secondStatus = await second.syncStatus()
        XCTAssertEqual(firstStatus.uploadedEntryCount, 1)
        XCTAssertEqual(secondStatus.receivedEntryCount, 1)
        XCTAssertEqual(secondStatus.phase, .upToDate)
    }

    private func makeModule(
        services: ClipboardSyncServices, keyByte: UInt8, time: TimeInterval,
        root: URL? = nil, clock: (@Sendable () -> Date)? = nil
    ) -> ClipboardHistoryModule {
        let root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-sync-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        return trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: root,
            keyStore: SyncTestLocalKeyStore(byte: keyByte),
            now: clock ?? { Date(timeIntervalSince1970: time) },
            syncServices: services
        ))
    }

    func testSyncTagsShowExistingEligibleTextWithoutEnablingDevice() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-sync-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: root, keyStore: SyncTestLocalKeyStore()
        ))
        let captured = try await module.capture(ClipboardHistoryCaptureRequest(
            source: .unknown, content: .text("shared later")
        ))
        let tag = try await module.createTagDefinition(named: "Work", assigningTo: captured.entryID)
        let choices = try await module.syncTags()
        XCTAssertEqual(choices, [ClipboardHistorySyncTag(
            id: tag.definition.id, displayName: "Work", isSelected: false, eligibleEntryCount: 1
        )])
        let status = await module.syncStatus()
        XCTAssertFalse(status.isEnabled)
    }

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
    var byte: UInt8 = 0x67
    func load() -> ClipboardHistoryMasterKeyResult {
        .key(Data(repeating: byte, count: 32))
    }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

private actor SyncTestCloud: ClipboardSyncTransport {
    private var currentAccount = ClipboardSyncAccount(container: "test", environment: "test", owner: "test-user")
    private var descriptors: [String: ClipboardSyncControl] = [:]
    private var records: [String: [ClipboardSyncUpload]] = [:]
    private var revision = 0
    private var losesEntryResponse = false
    private var reads = 0
    private var rendezvous = false
    private var initialReadWaiter: CheckedContinuation<ClipboardSyncControl?, Never>?
    private var shouldHoldCancellation = false
    private var heldCancellation: CheckedContinuation<Void, Never>?
    private var cancellationObserver: CheckedContinuation<Void, Never>?
    private var failsControlCreation = false
    private var losesControlResponse = false
    private var controlAttempts: [UUID] = []
    private var accountFailureDelay: TimeInterval?
    private var damagesDownload = false
    private var accountFault: ClipboardSyncServiceError?
    private var holdsClear = false
    private var heldClear: CheckedContinuation<Void, Never>?
    private var clearObserver: CheckedContinuation<Void, Never>?
    private var lostResetPhase: String?
    private var cancellations = 0
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func account() throws -> ClipboardSyncAccount {
        reads += 1
        if let fault = accountFault {
            accountFault = nil
            throw fault
        }
        if let delay = accountFailureDelay {
            accountFailureDelay = nil
            throw ClipboardSyncServiceError.network(retryAfter: delay)
        }
        return currentAccount
    }
    func failNextAccountRead(retryAfter: TimeInterval) { accountFailureDelay = retryAfter }
    func failNextAccountRead(with fault: ClipboardSyncServiceError) { accountFault = fault }
    func control(for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl? {
        try checkAccount(account)
        if rendezvous, descriptors[account.identifier] == nil {
            if let initialReadWaiter {
                self.initialReadWaiter = nil
                rendezvous = false
                initialReadWaiter.resume(returning: nil)
                return nil
            }
            return await withCheckedContinuation { initialReadWaiter = $0 }
        }
        return descriptors[account.identifier]
    }
    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) throws -> ClipboardSyncControl {
        try checkAccount(account)
        controlAttempts.append(candidate.keyID)
        if failsControlCreation {
            failsControlCreation = false
            throw ClipboardSyncServiceError.network(retryAfter: nil)
        }
        if let descriptor = descriptors[account.identifier] { return descriptor }
        let result = advanced(candidate)
        descriptors[account.identifier] = result
        if losesControlResponse {
            losesControlResponse = false
            throw ClipboardSyncServiceError.network(retryAfter: nil)
        }
        return result
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) throws -> ClipboardSyncChanges {
        try checkAccount(account)
        let offset = cursor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let uploads = records[account.identifier] ?? []
        return ClipboardSyncChanges(records: uploads.dropFirst(offset).map(\.record),
            cursor: Data(String(uploads.count).utf8), hasMore: false)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) throws -> [Data] {
        try checkAccount(account)
        guard let upload = records[account.identifier]?.first(where: { $0.record == record }) else {
            throw ClipboardSyncServiceError.missingRemoteState
        }
        if damagesDownload {
            damagesDownload = false
            var changed = upload.chunks
            changed[0][0] ^= 1
            return changed
        }
        return upload.chunks
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount,
                control: ClipboardSyncControl) throws -> ClipboardSyncControl {
        try checkAccount(account)
        guard let descriptor = descriptors[account.identifier], descriptor.epoch == control.epoch, descriptor.phase == "active", descriptor.keyID == control.keyID else {
            throw ClipboardSyncServiceError.missingRemoteState
        }
        if let existing = records[account.identifier]?.first(where: { $0.record.recordID == upload.record.recordID }) {
            guard existing == upload else { throw ClipboardSyncServiceError.corruptData }
            return descriptor
        }
        guard descriptor.serverToken == control.serverToken else { throw ClipboardSyncServiceError.conflict }
        records[account.identifier, default: []].append(upload)
        let result = advanced(descriptor)
        descriptors[account.identifier] = result
        if losesEntryResponse, upload.record.kind == .entry {
            losesEntryResponse = false
            throw ClipboardSyncServiceError.network(retryAfter: nil)
        }
        return result
    }
    func holdNextClear() { holdsClear = true }
    func waitForHeldClear() async {
        guard heldClear == nil else { return }
        await withCheckedContinuation { clearObserver = $0 }
    }
    func releaseClear() { heldClear?.resume(); heldClear = nil }
    func loseNextResetResponse(at phase: String) { lostResetPhase = phase }
    func transition(_ control: ClipboardSyncControl, to phase: String, epoch: UUID,
                    for account: ClipboardSyncAccount) throws -> ClipboardSyncControl {
        try checkAccount(account)
        guard let current = descriptors[account.identifier], current == control else { throw ClipboardSyncServiceError.conflict }
        let result = advanced(ClipboardSyncControl(accountID: current.accountID, keyID: current.keyID,
            keyCheck: current.keyCheck, epoch: epoch, phase: phase, serverToken: current.serverToken))
        descriptors[account.identifier] = result
        if lostResetPhase == phase { lostResetPhase = nil; throw ClipboardSyncServiceError.network(retryAfter: nil) }
        return result
    }
    func clearPage(for account: ClipboardSyncAccount, control: ClipboardSyncControl,
                   cursor: Data?) async throws -> ClipboardSyncCleanupPage {
        if holdsClear {
            holdsClear = false
            await withCheckedContinuation {
                heldClear = $0
                clearObserver?.resume()
                clearObserver = nil
            }
        }
        try checkAccount(account)
        guard let current = descriptors[account.identifier], current.phase == "resetting",
              current.epoch == control.epoch, current.keyID == control.keyID else { throw ClipboardSyncServiceError.missingRemoteState }
        let count = records[account.identifier]?.count ?? 0
        records[account.identifier] = []
        let result = count > 0 ? advanced(current) : current
        descriptors[account.identifier] = result
        if lostResetPhase == "cleanup" { lostResetPhase = nil; throw ClipboardSyncServiceError.network(retryAfter: nil) }
        return .init(control: result, cursor: nil, deletedRecordCount: count, hasMore: false)
    }
    func cancel() async {
        cancellations += 1
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard shouldHoldCancellation else { return }
        shouldHoldCancellation = false
        await withCheckedContinuation {
            heldCancellation = $0
            cancellationObserver?.resume()
            cancellationObserver = nil
        }
    }
    func holdNextCancellation() { shouldHoldCancellation = true }
    func cancellationCount() -> Int { cancellations }
    func waitForCancellation(after previous: Int) async {
        guard cancellations == previous else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }
    func waitForHeldCancellation() async {
        guard heldCancellation == nil else { return }
        await withCheckedContinuation { cancellationObserver = $0 }
    }
    func releaseCancellation() { heldCancellation?.resume(); heldCancellation = nil }
    func switchAccount(to owner: String) {
        currentAccount = ClipboardSyncAccount(container: "test", environment: "test", owner: owner)
    }
    func currentUploads() -> [ClipboardSyncUpload] { records[currentAccount.identifier] ?? [] }
    func loseNextEntryCommitResponse() { losesEntryResponse = true }
    func damageNextDownload() { damagesDownload = true }
    func failNextControlCreation() { failsControlCreation = true }
    func loseNextControlResponse() { losesControlResponse = true }
    func controlCreationAttempts() -> [UUID] { controlAttempts }
    func rendezvousInitialControlReads() { rendezvous = true }
    func removeControl() { descriptors[currentAccount.identifier] = nil }
    func accountReadCount() -> Int { reads }
    private func checkAccount(_ account: ClipboardSyncAccount) throws {
        guard currentAccount == account else { throw ClipboardSyncServiceError.accountChanged }
    }
    private func advanced(_ value: ClipboardSyncControl) -> ClipboardSyncControl {
        revision += 1
        return ClipboardSyncControl(accountID: value.accountID, keyID: value.keyID,
            keyCheck: value.keyCheck, epoch: value.epoch, phase: value.phase,
            serverToken: Data(String(revision).utf8))
    }
}

private actor SyncTestKeys: ClipboardSyncKeyStoring {
    private var values: [String: Data] = [:]
    func load(account: ClipboardSyncAccount, keyID: UUID) -> Data? {
        values[account.identifier + keyID.uuidString]
    }
    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) throws -> Data {
        let id = account.identifier + keyID.uuidString
        if let existing = values[id], existing != key { throw ClipboardSyncServiceError.corruptData }
        values[id] = key
        return key
    }
    func count() -> Int { values.count }
}

private actor SyncTestDelayedKeys: ClipboardSyncKeyStoring {
    let backing: SyncTestKeys
    private var available = false
    init(backing: SyncTestKeys) { self.backing = backing }
    func deliver() { available = true }
    func load(account: ClipboardSyncAccount, keyID: UUID) async throws -> Data? {
        guard available else { return nil }
        return await backing.load(account: account, keyID: keyID)
    }
    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) async throws -> Data {
        try await backing.create(account: account, keyID: keyID, key: key)
    }
}

private actor SyncTestFaultKeys: ClipboardSyncKeyStoring {
    let backing: SyncTestKeys
    var fault: ClipboardSyncServiceError?
    var wrongKey: Bool
    private var shouldHoldLoad = false
    private var heldLoad: CheckedContinuation<Void, Never>?
    private var loadObserver: CheckedContinuation<Void, Never>?

    init(backing: SyncTestKeys, fault: ClipboardSyncServiceError?, wrongKey: Bool = false) {
        self.backing = backing
        self.fault = fault
        self.wrongKey = wrongKey
    }

    func recover() { fault = nil; wrongKey = false }
    func holdNextLoad() { shouldHoldLoad = true }
    func waitForHeldLoad() async {
        guard heldLoad == nil else { return }
        await withCheckedContinuation { loadObserver = $0 }
    }
    func releaseLoad() { heldLoad?.resume(); heldLoad = nil }

    func load(account: ClipboardSyncAccount, keyID: UUID) async throws -> Data? {
        if let fault { throw fault }
        if wrongKey { return Data(repeating: 0xFA, count: 32) }
        let value = await backing.load(account: account, keyID: keyID)
        if shouldHoldLoad {
            shouldHoldLoad = false
            await withCheckedContinuation {
                heldLoad = $0
                loadObserver?.resume()
                loadObserver = nil
            }
        }
        return value
    }

    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) async throws -> Data {
        try await backing.create(account: account, keyID: keyID, key: key)
    }
}
