import AppKit
import Darwin
import Foundation
import GRDB
import XCTest
import ClipboardHistoryTestSupport
import os

@testable import ClipboardHistory

final class ClipboardHistorySyncTests: XCTestCase {
    @MainActor
    func testPersistentFileFailureAllowsIndependentSharingAndBacksOffAcrossRestart() async throws {
        let fixture = try await fileFixture(names: ["Damaged.txt", "Healthy.txt"],
            contents: [Data("damaged body".utf8), Data("healthy body".utf8)])
        let tags = try await fixture.sender.syncTags()
        let tag = try XCTUnwrap(tags.first)
        let removed = try await fixture.sender.capture(.init(source: .unknown, content: .text("delete independently")))
        _ = try await fixture.sender.apply(.setTags(removed.entryID, [tag.id]))
        await fixture.sender.retrySync()
        await fixture.cloud.persistentlyDamageNextFileBody()
        try await fixture.receiver.setSyncEnabled(true)

        _ = try await fixture.receiver.apply(.delete(removed.entryID))
        let added = try await fixture.receiver.capture(.init(source: .unknown, content: .text("share despite unavailable file")))
        _ = try await fixture.receiver.apply(.setTags(added.entryID, [tag.id]))
        await fixture.receiver.retrySync()
        await fixture.sender.retrySync()
        let sent = try await fixture.sender.page(.init()).entries
        XCTAssertFalse(sent.contains { $0.id == removed.entryID })
        XCTAssertTrue(sent.contains { $0.id == added.entryID })
        let received = try await fixture.receiver.page(.init()).entries
        let fileEntry = try XCTUnwrap(received.first { !$0.syncFiles.isEmpty })
        XCTAssertEqual(fileEntry.syncFiles.filter { $0.state == .complete }.count, 1)
        let failed = try XCTUnwrap(fileEntry.syncFiles.first { $0.transferFailure == .corruptData })
        do {
            _ = try await fixture.receiver.materialize(.init(entryID: fileEntry.id, purpose: .normalPaste))
            XCTFail("A failed member must never be omitted from materialization")
        } catch ClipboardHistoryModuleError.syncFilesPending {}

        let attempts = await fixture.cloud.fileBodyDownloadCount()
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeModule(services: fixture.services, keyByte: 0x72, time: 2_000, root: fixture.receiverRoot)
        await reopened.resumeSync()
        let afterResume = await fixture.cloud.fileBodyDownloadCount()
        XCTAssertEqual(afterResume, attempts, "Restart must retain the failed object's automatic retry deadline")
        await fixture.cloud.repairFileBodies()
        try await reopened.requestSyncFileDownload(entryID: fileEntry.id, objectID: failed.id, versionID: failed.versionID)
        let repaired = try await reopened.page(.init()).entries
        XCTAssertEqual(repaired.first { $0.id == fileEntry.id }?.syncFiles.map(\.state), [.complete, .complete])
    }

    func testDeletingPendingRejoinDoesNotBlockDeletionOrUnrelatedSharing() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = makeModule(services: services, keyByte: 0xDB, time: 1_000, root: root)
        let peer = makeModule(services: services, keyByte: 0xDC, time: 2_000)
        let original = try await first.capture(.init(source: .unknown, content: .text("delete the pending rejoin")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: original.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        try await peer.setSyncEnabled(true)

        try await first.setSyncEnabled(false)
        try await first.setSyncTagSelected(tag.id, selected: false)
        try await first.setSyncTagSelected(tag.id, selected: true)
        _ = try await first.apply(.delete(original.entryID))
        let unrelated = try await first.capture(.init(source: .unknown, content: .text("independent sharing must continue")))
        _ = try await first.apply(.setTags(unrelated.entryID, [tag.id]))
        try await first.setSyncEnabled(true)
        await peer.retrySync()

        let status = await first.syncStatus()
        let received = try await peer.page(.init()).entries
        XCTAssertEqual(status.phase, .upToDate)
        XCTAssertEqual(received.map(\.id), [unrelated.entryID])
        XCTAssertEqual(received.first?.previewText, "independent sharing must continue")

        try await first.closeStoreForTesting()
        let reopened = makeModule(services: services, keyByte: 0xDB, time: 3_000, root: root)
        await reopened.resumeSync()
        let fresh = makeModule(services: services, keyByte: 0xDD, time: 4_000)
        try await fresh.setSyncEnabled(true)
        let afterRestart = try await fresh.page(.init()).entries
        XCTAssertEqual(afterRestart.map(\.id), [unrelated.entryID])
    }

    func testFreshRejoinRetainsTheOriginalRootWithoutRepeatingMigrationReplay() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xD9, time: 1_000)
        let capture = try await first.capture(.init(source: .unknown, content: .text("keep the original root provenance")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        try await first.setSyncTagSelected(tag.id, selected: false)
        try await first.setSyncTagSelected(tag.id, selected: true)
        let fresh = makeModule(services: services, keyByte: 0xDA, time: 2_000)
        try await fresh.setSyncEnabled(true)
        await cloud.clearObservedChangeCursors()
        await fresh.retrySync()
        let cursors = await cloud.observedChangeCursors()
        XCTAssertEqual(cursors.count, 1)
        XCTAssertTrue(cursors.allSatisfy { $0 != nil }, "A complete rejoin checkpoint must not repeatedly request migration replay")
    }

    func testRejoinDuringPendingWithdrawalCleanupPublishesBeforeTheSyncPassCompletes() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xD7, time: 1_000)
        let capture = try await first.capture(.init(source: .unknown, content: .text("rejoin during cleanup")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        _ = try await first.apply(.setTags(capture.entryID, []))
        await cloud.holdNextPurge()
        let cleanup = Task { await first.retrySync() }
        addTeardownBlock { await cloud.releasePurge(); await cleanup.value }
        await cloud.waitForHeldPurge()
        _ = try await first.apply(.setTags(capture.entryID, [tag.id]))
        await cloud.releasePurge()
        await cleanup.value
        let fresh = makeModule(services: services, keyByte: 0xD8, time: 2_000)
        try await fresh.setSyncEnabled(true)
        let restored = try await fresh.page(.init()).entries
        XCTAssertEqual(restored.map(\.id), [capture.entryID])
    }

    func testOfflineRenameCannotReactivateWithdrawnContentEvenWithALaterTagRevision() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xD2, time: 1_000)
        let second = makeModule(services: services, keyByte: 0xD3, time: 2_000)
        let capture = try await first.capture(.init(source: .unknown, content: .text("rename is not consent")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        await second.suspendSync()
        let unrelated = ClipboardHistoryTagDefinition(id: "unrelated", displayName: "Unrelated")
        _ = try await second.replaceTagDefinitions(with: [tag, unrelated])
        for _ in 0..<5 { try await second.setSyncTagSelected(unrelated.id, selected: true) }
        _ = try await second.renameTagDefinition(id: tag.id, to: "Renamed while offline")
        try await first.setSyncTagSelected(tag.id, selected: false)
        await second.resumeSync()
        await first.retrySync()
        let published = await cloud.publishedUploads()
        XCTAssertEqual(published.filter { $0.record.kind == .entry }.count, 1)
        let fresh = makeModule(services: services, keyByte: 0xD4, time: 3_000)
        try await fresh.setSyncEnabled(true)
        let entries = try await fresh.page(.init()).entries
        XCTAssertTrue(entries.isEmpty)
    }

    func testWithdrawalCleanupResumesAfterLostResponseAndRejectsLateCiphertextAfterRestart() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = makeModule(services: services, keyByte: 0xD5, time: 1_000, root: root)
        let capture = try await first.capture(.init(source: .unknown, content: .text("cleanup withdrawal")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        await cloud.loseNextPurgeResponse()
        try await first.setSyncTagSelected(tag.id, selected: false)
        let failed = await first.syncStatus()
        XCTAssertEqual(failed.phase, .failed(.network))
        try await first.closeStoreForTesting()
        let reopened = makeModule(services: services, keyByte: 0xD5, time: 2_000, root: root)
        await reopened.resumeSync()
        await cloud.redeliverPurgedContent()
        let fresh = makeModule(services: services, keyByte: 0xD6, time: 3_000)
        try await fresh.setSyncEnabled(true)
        let freshEntries = try await fresh.page(.init()).entries
        XCTAssertTrue(freshEntries.isEmpty)
        let retained = try await reopened.page(.init()).entries
        XCTAssertEqual(retained.map(\.id), [capture.entryID])
        let current = await cloud.currentUploads()
        XCTAssertTrue(current.filter { $0.record.kind == .entry }.isEmpty)
    }

    func testSharingScopeCountsExcludeOverlapAndWithdrawalRetainsTagProtection() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let module = makeModule(services: services, keyByte: 0xD1, time: 1_000)
        let only = try await module.capture(.init(source: .unknown, content: .text("only work")))
        let overlap = try await module.capture(.init(source: .unknown, content: .text("work and other")))
        let work = try await module.createTagDefinition(named: "Work", assigningTo: only.entryID).definition
        let other = try await module.createTagDefinition(named: "Other", assigningTo: overlap.entryID).definition
        _ = try await module.apply(.setTags(overlap.entryID, [work.id, other.id]))
        try await module.setSyncTagSelected(work.id, selected: true)
        try await module.setSyncTagSelected(other.id, selected: true)
        try await module.setSyncEnabled(true)
        let before = try await module.syncTags()
        XCTAssertEqual(before.first { $0.id == work.id }?.withdrawalEntryCount, 1)
        XCTAssertEqual(before.first { $0.id == other.id }?.withdrawalEntryCount, 0)
        try await module.setSyncTagSelected(work.id, selected: false)
        let withdrawn = await module.syncStatus()
        let after = try await module.syncTags()
        XCTAssertEqual(withdrawn.withdrawnEntryCount, 1)
        XCTAssertEqual(after.first { $0.id == work.id }?.rejoinEntryCount, 1)
        let unprotected = try await module.previewClearHistory(scope: .unprotectedOnly)
        XCTAssertEqual(unprotected.affectedCount, 0)
        let remaining = await cloud.currentUploads()
        XCTAssertEqual(remaining.filter { $0.record.kind == .entry }.count, 1)
        try await module.setSyncTagSelected(work.id, selected: true)
        let rejoined = await module.syncStatus()
        XCTAssertEqual(rejoined.withdrawnEntryCount, 0)
    }

    func testConfirmedTagMergeExplicitlyRejoinsWithdrawnHistory() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xCE, time: 1_000)
        let capture = try await first.capture(.init(source: .unknown, content: .text("merge the retained collection")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        try await first.setSyncTagSelected(tag.id, selected: false)
        let other = ClipboardHistoryTagDefinition(id: UUID().uuidString.lowercased(), displayName: tag.displayName)
        _ = try await first.replaceTagDefinitions(with: [tag, other])
        try await first.setSyncTagSelected(other.id, selected: true)
        let preview = try await first.prepareSyncTagMerge(sourceID: tag.id, targetID: other.id)
        XCTAssertEqual(preview.newlyEligibleEntryCount, 1)
        try await first.mergeSyncTags(preview)
        let fresh = makeModule(services: services, keyByte: 0xCF, time: 2_000)
        try await fresh.setSyncEnabled(true)
        let restored = try await fresh.page(.init()).entries
        XCTAssertEqual(restored.map(\.id), [capture.entryID])
        XCTAssertEqual(restored.first?.tagIDs, [preview.canonicalTagID])
    }

    func testWithdrawalCancelsAnOfflineUploadWithoutLosingItsLaterDeletionSalvage() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xCC, time: 1_000)
        let second = makeModule(services: services, keyByte: 0xCD, time: 2_000)
        let capture = try await first.capture(.init(source: .unknown, content: .text("shared root")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        _ = try await second.apply(.editText(capture.entryID, "keep this unpublished edit"))
        await cloud.holdNextEntryCommit()
        let upload = Task { await second.retrySync() }
        addTeardownBlock { await cloud.releaseEntryCommit(); await upload.value }
        await cloud.waitForHeldEntryCommit()
        try await first.setSyncTagSelected(tag.id, selected: false)
        await cloud.releaseEntryCommit()
        await upload.value
        let published = await cloud.publishedUploads()
        XCTAssertEqual(published.filter { $0.record.kind == .entry }.count, 1)
        _ = try await first.apply(.delete(capture.entryID))
        await first.retrySync()
        await second.retrySync()
        let retained = try await second.page(.init()).entries
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.previewText, "keep this unpublished edit")
        XCTAssertNotEqual(retained.first?.id, capture.entryID)
        let notice = try await second.preservedSyncEdits()
        XCTAssertEqual(notice.count, 1)
    }

    func testFinalTagRemovalDuringAnInFlightUploadFinishesWithOnlyRetainedLocalContent() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xCA, time: 1_000)
        let capture = try await first.capture(.init(source: .unknown, content: .text("in flight initial copy")))
        let tag = try await first.createTagDefinition(named: "Remove", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        await cloud.holdNextEntryCommit()
        let upload = Task { try await first.setSyncEnabled(true) }
        addTeardownBlock { await cloud.releaseEntryCommit(); _ = await upload.result }
        await cloud.waitForHeldEntryCommit()
        _ = try await first.deleteTagDefinition(id: tag.id)
        await cloud.releaseEntryCommit()
        try await upload.value
        let remaining = await cloud.currentUploads()
        XCTAssertTrue(remaining.filter { $0.record.kind == .entry }.isEmpty)
        let local = try await first.page(.init()).entries
        XCTAssertEqual(local.map(\.id), [capture.entryID])
        XCTAssertEqual(local.first?.tagIDs, [])
        let fresh = makeModule(services: services, keyByte: 0xCB, time: 2_000)
        try await fresh.setSyncEnabled(true)
        let imported = try await fresh.page(.init()).entries
        XCTAssertTrue(imported.isEmpty)
    }

    func testExplicitRetaggingRestoresTheWithdrawnIdentityAndMembership() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xC7, time: 1_000)
        let second = makeModule(services: services, keyByte: 0xC8, time: 2_000)
        let capture = try await first.capture(.init(source: .unknown, content: .text("retag to resume")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        _ = try await first.apply(.setTags(capture.entryID, []))
        await first.retrySync()
        await second.retrySync()
        _ = try await first.apply(.setTags(capture.entryID, [tag.id]))
        await first.retrySync()
        let rejoinStatus = await first.syncStatus()
        XCTAssertEqual(rejoinStatus.phase, .upToDate)
        let localRetag = try await first.page(.init()).entries
        XCTAssertEqual(localRetag.first?.tagIDs, [tag.id])
        await cloud.reverseDelivery()
        await second.retrySync()
        let fresh = makeModule(services: services, keyByte: 0xC9, time: 3_000)
        try await fresh.setSyncEnabled(true)
        let restored = try await fresh.page(.init()).entries
        let retained = try await second.page(.init()).entries
        XCTAssertEqual(restored.map(\.id), [capture.entryID])
        XCTAssertEqual(retained.first?.tagIDs, [tag.id])
    }

    func testRejoinCheckpointPreservesMetadataRevisionAgainstLateOldContent() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xC5, time: 1_000)
        let capture = try await first.capture(.init(source: .unknown, content: .text("current favorite wins")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        _ = try await first.apply(.setFavorite(capture.entryID, true))
        await first.retrySync()
        let afterFavorite = await cloud.currentUploads()
        let oldFavorite = try XCTUnwrap(afterFavorite.last { $0.record.kind == .entry })
        _ = try await first.apply(.setFavorite(capture.entryID, false))
        await first.retrySync()
        try await first.setSyncTagSelected(tag.id, selected: false)
        try await first.setSyncTagSelected(tag.id, selected: true)
        let fresh = makeModule(services: services, keyByte: 0xC6, time: 2_000)
        try await fresh.setSyncEnabled(true)
        await cloud.redeliverPurgedRecord(oldFavorite.record.recordID)
        await fresh.retrySync()
        let restored = try await fresh.page(.init()).entries
        XCTAssertEqual(restored.map(\.id), [capture.entryID])
        XCTAssertFalse(try XCTUnwrap(restored.first).isFavorite)
    }

    func testOfflineWithdrawnEditsRejoinAsConflictsAcrossRestartAndPreserveMetadata() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let firstRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let secondRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = makeModule(services: services, keyByte: 0xC2, time: 1_000, root: firstRoot)
        let second = makeModule(services: services, keyByte: 0xC3, time: 2_000, root: secondRoot)
        let capture = try await first.capture(.init(source: .unknown, content: .text("original shared text")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        try await first.setSyncTagSelected(tag.id, selected: false)
        await second.retrySync()
        _ = try await first.apply(.editText(capture.entryID, "first retained edit"))
        _ = try await second.apply(.editText(capture.entryID, "second retained edit"))
        _ = try await second.apply(.setFavorite(capture.entryID, true))
        try await first.closeStoreForTesting()
        try await second.closeStoreForTesting()
        let a = makeModule(services: services, keyByte: 0xC2, time: 3_000, root: firstRoot)
        let b = makeModule(services: services, keyByte: 0xC3, time: 4_000, root: secondRoot)
        await a.resumeSync()
        await b.resumeSync()
        let before = await cloud.currentUploads()
        XCTAssertTrue(before.filter { $0.record.kind == .entry }.isEmpty)
        try await a.setSyncTagSelected(tag.id, selected: true)
        await b.retrySync()
        await a.retrySync()
        let aPlan = try await a.textEditPlan(for: capture.entryID)
        let bPlan = try await b.textEditPlan(for: capture.entryID)
        XCTAssertEqual(aPlan.text, "first retained edit")
        XCTAssertEqual(bPlan.text, "second retained edit")
        XCTAssertEqual(Set(aPlan.versions.map(\.text)), ["first retained edit", "second retained edit"])
        XCTAssertEqual(Set(bPlan.versions.map(\.id)), Set(aPlan.versions.map(\.id)))
        let fresh = makeModule(services: services, keyByte: 0xC4, time: 5_000)
        try await fresh.setSyncEnabled(true)
        let freshEntries = try await fresh.page(.init()).entries
        XCTAssertEqual(freshEntries.map(\.id), [capture.entryID])
        let freshPlan = try await fresh.textEditPlan(for: capture.entryID)
        XCTAssertEqual(Set(freshPlan.versions.map(\.text)), ["first retained edit", "second retained edit"])
        let chosen = try XCTUnwrap(aPlan.versions.first { $0.text == "second retained edit" })
        _ = try await a.resolveTextConflict(.init(plan: aPlan, versionID: chosen.id))
        await a.retrySync()
        await b.retrySync()
        let resolved = try await b.textEditPlan(for: capture.entryID)
        XCTAssertEqual(resolved.versions.count, 1)
        XCTAssertEqual(resolved.text, "second retained edit")
        let final = try await a.page(.init()).entries
        XCTAssertTrue(try XCTUnwrap(final.first).isFavorite)
        XCTAssertEqual(final.first?.capturedAt, Date(timeIntervalSince1970: 1_000))
    }

    func testExplicitSharedSelectionRejoinsRetainedCopiesOnAnotherMac() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xBF, time: 1_000)
        let capture = try await first.capture(.init(source: .unknown, content: .text("retained on the other Mac")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        try await first.setSyncTagSelected(tag.id, selected: false)
        let selector = makeModule(services: services, keyByte: 0xC1, time: 2_000)
        try await selector.setSyncEnabled(true)
        let before = try await selector.page(.init()).entries
        XCTAssertTrue(before.isEmpty)
        try await selector.setSyncTagSelected(tag.id, selected: true)
        await first.retrySync()
        await selector.retrySync()
        let restored = try await selector.page(.init()).entries
        XCTAssertEqual(restored.map(\.id), [capture.entryID])
        XCTAssertEqual(restored.first?.previewText, "retained on the other Mac")
    }

    func testExplicitReselectionRestoresOneSharedIdentityWithoutInventingATextRoot() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xBC, time: 1_000)
        let second = makeModule(services: services, keyByte: 0xBD, time: 2_000)
        let capture = try await first.capture(.init(source: .unknown, content: .text("same shared collection")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let original = try await first.textEditPlan(for: capture.entryID)
        try await first.setSyncTagSelected(tag.id, selected: false)
        await second.retrySync()
        try await first.setSyncTagSelected(tag.id, selected: true)
        await second.retrySync()
        let fresh = makeModule(services: services, keyByte: 0xBE, time: 3_000)
        try await fresh.setSyncEnabled(true)
        let imported = try await fresh.page(.init()).entries
        XCTAssertEqual(imported.map(\.id), [capture.entryID])
        XCTAssertEqual(imported.first?.tagIDs, [tag.id])
        let firstPlan = try await first.textEditPlan(for: capture.entryID)
        let secondPlan = try await second.textEditPlan(for: capture.entryID)
        XCTAssertEqual(firstPlan.versions.map(\.id), original.versions.map(\.id))
        XCTAssertEqual(secondPlan.versions.map(\.id), original.versions.map(\.id))
        if let received = imported.first {
            let freshPlan = try await fresh.textEditPlan(for: received.id)
            XCTAssertEqual(freshPlan.versions.map(\.id), original.versions.map(\.id))
        }
    }

    func testFinalSharedMembershipRemovalPreservesOnlyUnrelatedPeerTags() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xBA, time: 1_000)
        let second = makeModule(services: services, keyByte: 0xBB, time: 2_000)
        let capture = try await first.capture(.init(source: .unknown, content: .text("keep the private organization")))
        let shared = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(shared.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let privateTag = try await second.createTagDefinition(named: "Private", assigningTo: capture.entryID).definition
        _ = try await first.apply(.setTags(capture.entryID, []))
        await first.retrySync()
        await cloud.reverseDelivery()
        await second.retrySync()
        let local = try await second.page(.init()).entries
        XCTAssertEqual(local.map(\.id), [capture.entryID])
        XCTAssertEqual(local.first?.tagIDs, [privateTag.id])
        let state = await second.syncStatus()
        XCTAssertEqual(state.phase, .upToDate)
    }

    func testRetainedPeerMetadataCannotRepublishAfterWithdrawal() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xB8, time: 1_000)
        let second = makeModule(services: services, keyByte: 0xB9, time: 2_000)
        let capture = try await first.capture(.init(source: .unknown, content: .text("local metadata only")))
        let work = try await first.createTagDefinition(named: "Work", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(work.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        _ = try await first.apply(.setTags(capture.entryID, []))
        await first.retrySync()
        await second.retrySync()
        _ = try await second.apply(.setFavorite(capture.entryID, true))
        await second.retrySync()
        let operations = await cloud.publishedUploads()
        XCTAssertEqual(operations.filter { $0.record.kind == .entry }.count, 1)
        let local = try await second.page(.init()).entries
        XCTAssertTrue(try XCTUnwrap(local.first).isFavorite)
        let remote = try await first.page(.init()).entries
        XCTAssertFalse(try XCTUnwrap(remote.first).isFavorite)
    }

    func testUntaggedRetainedEditsStayLocalWhileAnotherCollectionContinuesSyncing() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xB6, time: 1_000)
        let second = makeModule(services: services, keyByte: 0xB7, time: 2_000)
        let withdrawn = try await first.capture(.init(source: .unknown, content: .text("original local note")))
        let active = try await first.capture(.init(source: .unknown, content: .text("still shared note")))
        let work = try await first.createTagDefinition(named: "Work", assigningTo: withdrawn.entryID).definition
        let keep = try await first.createTagDefinition(named: "Keep", assigningTo: active.entryID).definition
        let privateTag = try await first.createTagDefinition(named: "Private", assigningTo: withdrawn.entryID).definition
        try await first.setSyncTagSelected(work.id, selected: true)
        try await first.setSyncTagSelected(keep.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        _ = try await first.apply(.setTags(withdrawn.entryID, [privateTag.id]))
        _ = try await first.apply(.editText(withdrawn.entryID, "private edit after untagging"))
        await first.retrySync()
        await second.retrySync()
        let publicOperations = await cloud.publishedUploads()
        XCTAssertEqual(publicOperations.filter { $0.record.kind == .entry }.count, 2,
            "The private edit must never be published, even if cleanup would later purge it")
        let remaining = await cloud.currentUploads()
        XCTAssertEqual(remaining.filter { $0.record.kind == .entry }.count, 1)
        let localPage = try await first.page(.init()).entries
        let peerPage = try await second.page(.init()).entries
        XCTAssertEqual(localPage.first { $0.id == withdrawn.entryID }?.previewText, "private edit after untagging")
        XCTAssertEqual(peerPage.first { $0.id == withdrawn.entryID }?.previewText, "original local note")
        XCTAssertNotNil(peerPage.first { $0.id == active.entryID })
    }

    func testWithdrawalMarkerSurvivesRestartWithoutBreakingPeerSynchronization() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = makeModule(services: services, keyByte: 0xB4, time: 1_000, root: root)
        let second = makeModule(services: services, keyByte: 0xB5, time: 2_000)
        let capture = try await first.capture(.init(source: .unknown, content: .text("retained through restart")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        try await first.setSyncTagSelected(tag.id, selected: false)
        try await first.closeStoreForTesting()
        let restarted = makeModule(services: services, keyByte: 0xB4, time: 3_000, root: root)
        await restarted.resumeSync()
        await second.retrySync()
        let restartedStatus = await restarted.syncStatus()
        let peerStatus = await second.syncStatus()
        XCTAssertEqual(restartedStatus.phase, .upToDate)
        XCTAssertEqual(peerStatus.phase, .upToDate)
        let peerTags = try await second.syncTags()
        XCTAssertFalse(try XCTUnwrap(peerTags.first { $0.id == tag.id }).isSelected)
        let peerEntries = try await second.page(.init()).entries
        XCTAssertEqual(peerEntries.map(\.id), [capture.entryID])
        let uploads = await cloud.currentUploads()
        XCTAssertTrue(uploads.filter { $0.record.kind == .entry }.isEmpty)
    }

    func testFinalTagDeselectionWithdrawsCloudContentButRetainsDownloadedCopies() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xB1, time: 1_000)
        let second = makeModule(services: services, keyByte: 0xB2, time: 2_000)
        let capture = try await first.capture(.init(source: .unknown, content: .text("retained after withdrawal")))
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let privateTag = try await second.createTagDefinition(named: "Private", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(tag.id, selected: false)
        await second.retrySync()
        let firstPage = try await first.page(.init()).entries
        let secondPage = try await second.page(.init()).entries
        XCTAssertEqual(firstPage.map(\.id), [capture.entryID])
        XCTAssertEqual(secondPage.map(\.id), [capture.entryID])
        XCTAssertEqual(Set(secondPage[0].tagIDs), [tag.id, privateTag.id])
        let remaining = await cloud.currentUploads()
        XCTAssertTrue(remaining.filter { $0.record.kind == .entry }.isEmpty,
            "Withdrawal must remove cloud content, not merely hide it")
        let fresh = makeModule(services: services, keyByte: 0xB3, time: 3_000)
        try await fresh.setSyncEnabled(true)
        let freshPage = try await fresh.page(.init())
        XCTAssertTrue(freshPage.entries.isEmpty)
    }

    func testCloudResetStillCompletesWhenLocalHistoryWasAlreadyDeleted() async throws {
        let source = try await recoverySource()
        let page = try await source.sender.page(.init())
        let id = try XCTUnwrap(page.entries.first?.id)
        _ = try await source.sender.apply(.delete(id))
        let confirmation = try await source.sender.prepareCloudReset()
        try await source.sender.clearCloudDataAndStopSync(confirmation)
        let status = await source.sender.syncStatus()
        XCTAssertEqual(status.cloudReset?.stage, .completed)
        let uploads = await source.cloud.currentUploads()
        XCTAssertTrue(uploads.isEmpty)
    }

    func testCloudResetDiscardsAQueuedTagMergeWithoutChangingLocalTags() async throws {
        let source = try await recoverySource()
        let peer = makeModule(services: .init(transport: source.cloud, keys: source.keys, pollingInterval: nil), keyByte: 0x29, time: 2_000)
        let sourceTag = try await source.sender.syncTags().first { $0.id == source.tag }
        let local = try await peer.capture(.init(source: .unknown, content: .text("locally merged before reset")))
        let localTag = try await peer.createTagDefinition(named: try XCTUnwrap(sourceTag).displayName, assigningTo: local.entryID).definition
        try await peer.setSyncEnabled(true)
        await peer.suspendSync()
        let preview = try await peer.prepareSyncTagMerge(sourceID: localTag.id, targetID: source.tag)
        try await peer.mergeSyncTags(preview)
        let before = try await peer.syncTags().map { ($0.id, $0.displayName) }
        let confirmation = try await peer.prepareCloudReset()
        try await peer.clearCloudDataAndStopSync(confirmation)
        try await peer.setSyncEnabled(true)
        let uploads = await source.cloud.currentUploads()
        XCTAssertTrue(uploads.isEmpty)
        let after = try await peer.syncTags().map { ($0.id, $0.displayName) }
        XCTAssertEqual(after.map(\.0), before.map(\.0))
        XCTAssertEqual(after.map(\.1), before.map(\.1))
    }

    func testNewRemoteTagSelectionCannotRepublishRetainedPreResetCopies() async throws {
        let source = try await recoverySource()
        let peer = makeModule(services: .init(transport: source.cloud, keys: source.keys, pollingInterval: nil), keyByte: 0x28, time: 2_000)
        try await peer.setSyncEnabled(true)
        await peer.suspendSync()
        let confirmation = try await source.sender.prepareCloudReset()
        try await source.sender.clearCloudDataAndStopSync(confirmation)
        await peer.resumeSync()
        try await source.sender.setSyncEnabled(true)
        try await source.sender.setSyncTagSelected(source.tag, selected: true)
        let before = await source.cloud.currentUploads()
        XCTAssertEqual(before.filter { $0.record.kind == .entry }.count, 1)
        try await peer.setSyncEnabled(true)
        let after = await source.cloud.currentUploads()
        let peerStatus = await peer.syncStatus()
        XCTAssertEqual(peerStatus.phase, .upToDate)
        XCTAssertEqual(after.filter { $0.record.kind == .entry }.count, 1)
        let fresh = try await peer.capture(.init(source: .unknown, content: .text("new local text after reset")))
        _ = try await peer.apply(.setTags(fresh.entryID, [source.tag]))
        await peer.retrySync()
        let withFresh = await source.cloud.currentUploads()
        XCTAssertEqual(withFresh.filter { $0.record.kind == .entry }.count, 2)
        try await peer.setSyncTagSelected(source.tag, selected: true)
        let explicitlyShared = await source.cloud.currentUploads()
        XCTAssertEqual(explicitlyShared.filter { $0.record.kind == .entry }.count, 3)
    }

    func testInterruptedCloudClearsRemainIndependentAcrossAccountSwitches() async throws {
        let source = try await recoverySource()
        let accountA = try await source.cloud.account()
        let confirmationA = try await source.sender.prepareCloudReset()
        await source.cloud.loseNextResetResponse(at: "resetting")
        try await source.sender.clearCloudDataAndStopSync(confirmationA)
        await source.cloud.switchAccount(to: "account-b")
        try await source.sender.setSyncEnabled(true)
        let enabledB = await source.sender.syncStatus()
        XCTAssertTrue(enabledB.isEnabled)
        XCTAssertNil(enabledB.cloudReset)
        let localB = try await source.sender.capture(.init(source: .unknown, content: .text("only account B")))
        let tagB = try await source.sender.createTagDefinition(named: "Account B", assigningTo: localB.entryID)
        try await source.sender.setSyncTagSelected(tagB.definition.id, selected: true)
        let beforeB = await source.cloud.currentUploads()
        XCTAssertFalse(beforeB.isEmpty)
        let confirmationB = try await source.sender.prepareCloudReset()
        await source.cloud.loseNextResetResponse(at: "resetting")
        try await source.sender.clearCloudDataAndStopSync(confirmationB)
        await source.cloud.switchAccount(to: accountA.owner)
        await source.sender.resumeSync()
        let completedA = await source.sender.syncStatus()
        XCTAssertEqual(completedA.cloudReset?.stage, .completed)
        let clearedA = await source.cloud.currentUploads()
        XCTAssertTrue(clearedA.isEmpty)
        await source.cloud.switchAccount(to: "account-b")
        let unchangedB = await source.cloud.currentUploads()
        XCTAssertEqual(unchangedB, beforeB)
        await source.sender.retrySync()
        let completedB = await source.sender.syncStatus()
        XCTAssertEqual(completedB.cloudReset?.stage, .completed)
        let clearedB = await source.cloud.currentUploads()
        XCTAssertTrue(clearedB.isEmpty)
        let local = try await source.sender.page(.init())
        XCTAssertEqual(local.entries.count, 2)
    }

    func testClearConfirmationRefreshesWhenLocalHistoryBecomesShared() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let module = makeModule(services: services, keyByte: 0x9F, time: 1_000)
        let captured = try await module.capture(.init(source: .unknown, content: .text("share after preview")))
        let tag = try await module.createTagDefinition(named: "Scope change", assigningTo: captured.entryID)
        try await module.setSyncTagSelected(tag.definition.id, selected: true)
        let localPreview = try await module.previewClearHistory(scope: .includingProtected)
        XCTAssertEqual(localPreview.sharedAffectedCount, 0)
        try await module.setSyncEnabled(true)
        let outcome = try await module.confirm(localPreview.token)
        guard case .stale(let updated) = outcome else { return XCTFail("Sharing changes the disclosed deletion scope") }
        XCTAssertEqual(updated.sharedAffectedCount, 1)
        let page = try await module.page(.init())
        XCTAssertEqual(page.entries.map(\.id), [captured.entryID])
    }

    func testDeletionCleanupResumesAfterLostProviderResponseAndRestart() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-purge-retry-\(UUID())")
        let module = makeModule(services: services, keyByte: 0x9C, time: 1_000, root: root)
        let shared = try await module.capture(.init(source: .unknown, content: .text("purge after restart")))
        let tag = try await module.createTagDefinition(named: "Cleanup", assigningTo: shared.entryID)
        try await module.setSyncTagSelected(tag.definition.id, selected: true)
        try await module.setSyncEnabled(true)
        _ = try await module.apply(.editText(shared.entryID, "published version"))
        await module.retrySync()
        await cloud.loseNextPurgeResponse()
        _ = try await module.apply(.delete(shared.entryID))
        await module.retrySync()
        let failed = await module.syncStatus()
        XCTAssertEqual(failed.phase, .failed(.network))
        try await module.closeStoreForTesting()
        let reopened = makeModule(services: services, keyByte: 0x9C, time: 2_000, root: root)
        await reopened.resumeSync()
        let status = await reopened.syncStatus()
        XCTAssertEqual(status.phase, .upToDate)
        let remaining = await cloud.currentUploads()
        XCTAssertEqual(remaining.filter { $0.record.kind == .entry }.count, 1)
        let page = try await reopened.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
    }

    func testInterruptedDeletionRollsBackPreservationAndRetriesExactlyOnce() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-delete-rollback-\(UUID())")
        let shouldFail = OSAllocatedUnfairLock(initialState: false)
        let first = makeModule(services: services, keyByte: 0x9D, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x9E, time: 2_000, root: root,
            faults: .init(shouldFail: { point in point == .databaseTransaction && shouldFail.withLock { $0 } }))
        let shared = try await first.capture(.init(source: .unknown, content: .text("rollback root")))
        let tag = try await first.createTagDefinition(named: "Rollback", assigningTo: shared.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        await second.suspendSync()
        _ = try await second.apply(.editText(shared.entryID, "transactional offline edit"))
        _ = try await first.apply(.delete(shared.entryID))
        await first.retrySync()
        shouldFail.withLock { $0 = true }
        await second.resumeSync()
        let unchanged = try await second.page(.init())
        XCTAssertEqual(unchanged.entries.map(\.id), [shared.entryID])
        XCTAssertEqual(unchanged.entries.first?.previewText, "transactional offline edit")
        let failedNotices = try await second.preservedSyncEdits()
        XCTAssertTrue(failedNotices.isEmpty)
        try await second.closeStoreForTesting()
        let reopened = makeModule(services: services, keyByte: 0x9E, time: 3_000, root: root)
        await reopened.resumeSync()
        let saved = try await reopened.page(.init())
        XCTAssertEqual(saved.entries.count, 1)
        XCTAssertNotEqual(saved.entries.first?.id, shared.entryID)
        XCTAssertEqual(saved.entries.first?.previewText, "transactional offline edit")
        await cloud.replayAllChangesInReverseOrder()
        await reopened.retrySync()
        let replay = try await reopened.page(.init())
        XCTAssertEqual(replay.entries.map(\.id), saved.entries.map(\.id))
    }

    func testDeletionReclaimsPublishedRootAndEditCiphertextButKeepsReplayFence() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let module = makeModule(services: services, keyByte: 0x9A, time: 1_000)
        let shared = try await module.capture(.init(source: .unknown, content: .text("cloud secret")))
        let tag = try await module.createTagDefinition(named: "Purge", assigningTo: shared.entryID)
        try await module.setSyncTagSelected(tag.definition.id, selected: true)
        try await module.setSyncEnabled(true)
        _ = try await module.apply(.editText(shared.entryID, "updated cloud secret"))
        await module.retrySync()
        let contentRecords = await cloud.currentUploads().filter { $0.record.kind == .entry }.map(\.record.recordID)
        XCTAssertEqual(contentRecords.count, 2)
        _ = try await module.apply(.delete(shared.entryID))
        await module.retrySync()
        let remaining = await cloud.currentUploads()
        XCTAssertTrue(Set(contentRecords).isDisjoint(with: remaining.map(\.record.recordID)))
        XCTAssertEqual(remaining.filter { $0.record.kind == .entry }.count, 1)
        await cloud.redeliverPurgedContent()
        let peer = makeModule(services: services, keyByte: 0x9B, time: 2_000)
        try await peer.setSyncEnabled(true)
        let page = try await peer.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
        let cleanedAgain = await cloud.currentUploads()
        XCTAssertTrue(Set(contentRecords).isDisjoint(with: cleanedAgain.map(\.record.recordID)))
    }

    func testDeletionWinsWhenAnOfflineUploadLosesItsControlRace() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x98, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x99, time: 2_000)
        let shared = try await first.capture(.init(source: .unknown, content: .text("race original")))
        let tag = try await first.createTagDefinition(named: "Race", assigningTo: shared.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        await second.suspendSync()
        _ = try await second.apply(.editText(shared.entryID, "save this offline draft"))
        await cloud.holdNextEntryCommit()
        let upload = Task { await second.resumeSync() }
        addTeardownBlock { await cloud.releaseEntryCommit(); await upload.value }
        await cloud.waitForHeldEntryCommit()
        _ = try await first.apply(.delete(shared.entryID))
        await first.retrySync()
        await cloud.releaseEntryCommit()
        await upload.value
        let after = try await second.page(.init())
        XCTAssertEqual(after.entries.count, 1)
        XCTAssertNotEqual(after.entries.first?.id, shared.entryID)
        XCTAssertEqual(after.entries.first?.previewText, "save this offline draft")
        let notice = try await second.preservedSyncEdits()
        XCTAssertEqual(notice.count, 1)
    }

    func testBulkClearPreservesProtectedEntriesUntilExplicitlyIncludedAndDeletesOnPeers() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x96, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x97, time: 2_000)
        let shared = try await first.capture(.init(source: .unknown, content: .text("protected shared")))
        let tag = try await first.createTagDefinition(named: "Clear scope", assigningTo: shared.entryID)
        _ = try await first.capture(.init(source: .unknown, content: .text("unprotected local")))
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let local = try await first.previewClearHistory(scope: .unprotectedOnly)
        XCTAssertEqual(local.affectedCount, 1)
        XCTAssertEqual(local.sharedAffectedCount, 0)
        _ = try await first.confirm(local.token)
        await first.retrySync()
        await second.retrySync()
        let retained = try await second.page(.init())
        XCTAssertEqual(retained.entries.count, 1)
        let all = try await first.previewClearHistory(scope: .includingProtected)
        XCTAssertEqual(all.affectedCount, 1)
        XCTAssertEqual(all.sharedAffectedCount, 1)
        _ = try await first.confirm(all.token)
        await first.retrySync()
        await second.retrySync()
        let deleted = try await second.page(.init())
        XCTAssertTrue(deleted.entries.isEmpty)
    }

    func testOfflineEditBecomesOneLocalCopyAcrossDeletionReplayAndRestart() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-salvage-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x94, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x95, time: 2_000, root: root)
        let captured = try await first.capture(.init(source: .unknown, content: .text("shared original")))
        let tag = try await first.createTagDefinition(named: "Preserved work", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        await second.suspendSync()
        _ = try await second.apply(.setFavorite(captured.entryID, true))
        _ = try await second.apply(.editText(captured.entryID, "precise offline work"))
        try await second.closeStoreForTesting()
        _ = try await first.apply(.delete(captured.entryID))
        await first.retrySync()
        let reopened = makeModule(services: services, keyByte: 0x95, time: 3_000, root: root)
        await reopened.resumeSync()
        let saved = try await reopened.page(.init())
        XCTAssertEqual(saved.entries.count, 1)
        guard let copy = saved.entries.first else { return }
        let notices = try await reopened.preservedSyncEdits()
        XCTAssertEqual(notices.map(\.id), [copy.id])
        XCTAssertEqual(notices.map(\.previewText), ["precise offline work"])
        XCTAssertNotEqual(copy.id, captured.entryID)
        XCTAssertEqual(copy.previewText, "precise offline work")
        XCTAssertTrue(copy.isFavorite)
        XCTAssertEqual(copy.tagIDs, [tag.definition.id])
        try await reopened.closeStoreForTesting()
        await cloud.replayAllChangesInReverseOrder()
        let again = makeModule(services: services, keyByte: 0x95, time: 4_000, root: root)
        await again.resumeSync()
        try await again.setSyncTagSelected(tag.definition.id, selected: true)
        await again.retrySync()
        let repeated = try await again.page(.init())
        XCTAssertEqual(repeated.entries.map(\.id), [copy.id])
        let noticesAgain = try await again.preservedSyncEdits()
        XCTAssertEqual(noticesAgain.map(\.id), [copy.id])
        try await again.dismissPreservedSyncEdits([copy.id])
        let dismissed = try await again.preservedSyncEdits()
        XCTAssertTrue(dismissed.isEmpty)
        await again.retrySync()
        await first.retrySync()
        let peer = try await first.page(.init())
        XCTAssertTrue(peer.entries.isEmpty)
    }

    func testExplicitSharedDeletionSurvivesReverseReplayOnANewDevice() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x91, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x92, time: 2_000)
        let captured = try await first.capture(.init(source: .unknown, content: .text("delete everywhere")))
        let tag = try await first.createTagDefinition(named: "Shared deletion", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let before = try await second.page(.init())
        XCTAssertEqual(before.entries.count, 1)
        _ = try await first.apply(.delete(captured.entryID))
        await first.retrySync()
        await second.retrySync()
        let after = try await second.page(.init())
        XCTAssertTrue(after.entries.isEmpty)
        _ = try await first.renameTagDefinition(id: tag.definition.id, to: "Renamed after deletion")
        await first.retrySync()
        await second.retrySync()
        let status = await second.syncStatus()
        XCTAssertEqual(status.phase, .upToDate)
        await cloud.replayAllChangesInReverseOrder()
        let late = makeModule(services: services, keyByte: 0x93, time: 3_000)
        try await late.setSyncEnabled(true)
        let replayed = try await late.page(.init())
        XCTAssertTrue(replayed.entries.isEmpty)
    }

    @MainActor
    func testMixedRichAndFileItemsRemainOneCompleteEntryAcrossBodyRetry() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xA5, time: 1_000)
        let second = makeModule(services: services, keyByte: 0xA6, time: 2_000)
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sync-mixed-file-source-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(sourceRoot)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("Attachment.txt")
        let bytes = Data("ordered attachment bytes".utf8)
        try bytes.write(to: source)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-rich-file.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let rich = NSPasteboardItem()
        let html = Data("<b>first rich item</b>".utf8)
        rich.setString("first rich item", forType: .string)
        rich.setData(html, forType: .html)
        let file = NSPasteboardItem()
        file.setString(source.absoluteString, forType: .fileURL)
        XCTAssertTrue(pasteboard.writeObjects([rich, file]))
        guard case .captured(let captured) = try await first.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected a complete rich/file entry")
        }
        let tag = try await first.createTagDefinition(named: "Mixed", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        pasteboard.clearContents()
        pasteboard.setString("unchanged during pending paste", forType: .string)
        let generation = pasteboard.changeCount
        await cloud.damageNextFileBodyDownload()
        try await second.setSyncEnabled(true)
        let pending = try await second.page(.init())
        XCTAssertEqual(pending.entries.map(\.id), [captured.entryID])
        XCTAssertEqual(pending.entries.first?.syncFiles.map(\.state), [.waitingForDownload])
        do {
            _ = try await second.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
            XCTFail("The rich member cannot paste without its file member")
        } catch ClipboardHistoryModuleError.syncFilesPending {}
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.string(forType: .string), "unchanged during pending paste")
        await second.retrySync()
        let complete = try await second.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertEqual(complete.items.count, 2)
        XCTAssertEqual(complete.items[0].representations, [
            .text(typeIdentifier: "public.utf8-plain-text", value: "first rich item"), .data(typeIdentifier: "public.html", html),
        ])
        guard case .file(let receivedFile) = complete.items[1].representations.first else {
            return XCTFail("The second item must remain a complete file")
        }
        XCTAssertEqual(try Data(contentsOf: receivedFile.currentURL), bytes)
        do {
            _ = try await second.materialize(.init(entryID: captured.entryID, purpose: .plainTextPaste))
            XCTFail("The file-only item cannot be dropped from a plain-text paste")
        } catch ClipboardHistoryModuleError.operationUnavailable {}
        let final = try await second.page(.init())
        XCTAssertEqual(final.entries.map(\.id), [captured.entryID])
    }

    @MainActor
    func testMultipleOwnedImagesKeepOrderAndOnlyPublishTheReferencedEntryPreview() async throws {
        let services = ClipboardSyncServices(transport: SyncTestCloud(), keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0xA3, time: 1_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-multiple-images-\(UUID())")
        let second = makeModule(services: services, keyByte: 0xA4, time: 2_000, root: root)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-multiple-images.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let firstItem = NSPasteboardItem()
        firstItem.setData(try makeSyncBitmap(), forType: .png)
        let secondItem = NSPasteboardItem()
        secondItem.setData(try makeSyncBitmap(color: NSColor(deviceRed: 0, green: 0.7, blue: 0.2, alpha: 1)), forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([firstItem, secondItem]))
        guard case .captured(let captured) = try await first.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected two image members")
        }
        let tag = try await first.createTagDefinition(named: "Images", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let original = try await first.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        let received = try await second.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertEqual(received, original)
        XCTAssertEqual(received.items.count, 2)
        let firstPreview = try await first.materialize(.init(entryID: captured.entryID, purpose: .preview))
        let secondPreview = try await second.materialize(.init(entryID: captured.entryID, purpose: .preview))
        XCTAssertEqual(firstPreview, secondPreview)
        let payloads = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("payloads"), includingPropertiesForKeys: nil)
        XCTAssertEqual(payloads.count, 3, "Two owned images and the one entry preview must have durable owners")
    }

    @MainActor
    func testCorruptOwnedAssetAndDuplicateFileMembersRejectTheEntireEnvelope() async throws {
        let validPNG = try makeSyncBitmap()
        let file = ClipboardSyncFileDescriptor(objectID: UUID(), versionID: UUID(), displayName: "pending.txt",
            originalByteCount: nil, contentDigest: nil, body: nil, state: .sourceUnavailable)
        let cases: [[ClipboardSyncRepresentationContent]] = [
            [.bitmap(png: Data(validPNG.prefix(24)), thumbnail: validPNG)],
            [.bitmap(png: validPNG, thumbnail: Data([0x89, 0x50, 0x4E, 0x47]))],
            [.file(file), .file(file)],
        ]
        for (index, representations) in cases.enumerated() {
            let cloud = SyncTestCloud()
            let keys = SyncTestKeys()
            let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil),
                keyByte: UInt8(0xA0 + index), time: 1_000)
            try await module.setSyncEnabled(true)
            try await Self.publishFixture(.entry(.init(id: UUID(), capturedAt: Date(timeIntervalSince1970: 500),
                sourceBundleID: nil, sourceDisplayName: nil, sourceProvenance: "unknown", favorite: false,
                tags: [.init(id: "shared", name: "Shared")],
                items: [.init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: "do not import alone")]),
                        .init(representations: representations)], facets: ["text", "image"], recognition: .init())), cloud: cloud, keys: keys)
            await module.retrySync()
            let page = try await module.page(.init())
            let status = await module.syncStatus()
            XCTAssertEqual(page.entries, [], "Malformed member \(index) must reject the complete entry")
            XCTAssertEqual(status.phase, .failed(.corruptData))
        }
    }

    @MainActor
    func testOwnedAssetPublicationFailureDoesNotPublishAPartialMixedEntry() async throws {
        let services = ClipboardSyncServices(transport: SyncTestCloud(), keys: SyncTestKeys(), pollingInterval: nil)
        let failure = OSAllocatedUnfairLock(initialState: true)
        let first = makeModule(services: services, keyByte: 0x98, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x99, time: 2_000,
            faults: .init { point in point == .payloadPublication && failure.withLock { $0 } })
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-partial-image.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let image = NSPasteboardItem()
        image.setData(try makeSyncBitmap(), forType: .png)
        let text = NSPasteboardItem()
        text.setString("second complete item", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([image, text]))
        guard case .captured(let captured) = try await first.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected a complete mixed capture")
        }
        let tag = try await first.createTagDefinition(named: "Mixed", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        pasteboard.clearContents()
        pasteboard.setString("keep current clipboard", forType: .string)
        let generation = pasteboard.changeCount
        try await second.setSyncEnabled(true)
        let failedPage = try await second.page(.init())
        XCTAssertEqual(failedPage.entries, [])
        let failedStatus = await second.syncStatus()
        XCTAssertEqual(failedStatus.phase, .failed(.localStorage))
        failure.withLock { $0 = false }
        await second.retrySync()
        let page = try await second.page(.init())
        XCTAssertEqual(page.entries.count, 1)
        let original = try await first.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        let received = try await second.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertEqual(received, original)
        do {
            _ = try await second.materialize(.init(entryID: captured.entryID, purpose: .plainTextPaste))
            XCTFail("An image-only item must not disappear from a plain-text paste")
        } catch { XCTAssertEqual(error as? ClipboardHistoryModuleError, .operationUnavailable) }
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep current clipboard")
        await second.retrySync()
        let repeated = try await second.page(.init())
        XCTAssertEqual(repeated.entries.count, 1)
    }

    @MainActor
    func testResolvedTextConflictKeepsIndependentMetadataAndRejectsLateRecognition() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let recognizer = SyncTestRecognizer(results: [.ocr: ["obsolete composition image"], .qr: ["anydoor://obsolete/composition"]], held: true)
        let first = makeModule(services: services, keyByte: 0xDB, time: 1_000, recognizer: recognizer)
        let second = makeModule(services: services, keyByte: 0xDC, time: 2_000)
        addTeardownBlock { await recognizer.release() }
        try await first.setAutomaticImageTextIndexingEnabled(true)
        let board = NSPasteboard(name: .init("dev.bybee.AnyDoor.conflict-metadata.\(UUID())"))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("original editable image", forType: .string)
        item.setData(try makeSyncBitmap(), forType: .png)
        XCTAssertTrue(board.writeObjects([item]))
        let source = ClipboardHistoryCaptureSource(bundleIdentifier: "test.composition.editor", displayName: "Composition Editor")
        guard case .captured(let capture) = try await first.capture(.init(pasteboard: board), source: source) else {
            return XCTFail("Expected editable bitmap content")
        }
        let shared = try await first.createTagDefinition(named: "Shared composition", assigningTo: capture.entryID).definition
        let removed = try await first.createTagDefinition(named: "Earlier membership", assigningTo: capture.entryID).definition
        try await first.setSyncTagSelected(shared.id, selected: true)
        try await first.setSyncTagSelected(removed.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        for _ in 0..<100 where await recognizer.callCount() == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let recognitionCalls = await recognizer.callCount()
        XCTAssertGreaterThan(recognitionCalls, 0, "The obsolete recognition must actually be in flight")
        let privateTag = try await second.createTagDefinition(named: "Private composition", assigningTo: capture.entryID).definition
        let recent = try await second.capture(.init(source: .unknown, content: .text("newer local-only history")))
        await first.suspendSync()
        await second.suspendSync()
        _ = try await first.apply(.editText(capture.entryID, "first independent draft"))
        _ = try await second.apply(.editText(capture.entryID, "chosen second draft"))
        _ = try await second.apply(.setFavorite(capture.entryID, true))
        _ = try await second.apply(.setTags(capture.entryID, [shared.id, privateTag.id]))
        await first.resumeSync()
        await second.resumeSync()
        await first.retrySync()
        let plan = try await first.textEditPlan(for: capture.entryID)
        XCTAssertEqual(Set(plan.versions.map(\.text)), ["first independent draft", "chosen second draft"])
        let choice = try XCTUnwrap(plan.versions.first { $0.text == "chosen second draft" })
        _ = try await first.resolveTextConflict(.init(plan: plan, versionID: choice.id))
        await first.retrySync()
        await second.retrySync()
        await recognizer.release()
        await first.awaitDerivedJobsForTesting()
        await first.retrySync()
        await second.retrySync()

        let expected = ClipboardHistoryMaterialization(items: [.init(representations: [
            .text(typeIdentifier: "public.utf8-plain-text", value: "chosen second draft")
        ])])
        let received = try await second.materialize(.init(entryID: capture.entryID, purpose: .normalPaste))
        XCTAssertEqual(received, expected)
        let page = try await second.page(.init())
        let entry = try XCTUnwrap(page.entries.first { $0.id == capture.entryID })
        XCTAssertEqual(page.entries.first?.id, recent.entryID, "Resolution and metadata do not invent recent use")
        XCTAssertTrue(entry.isFavorite)
        XCTAssertEqual(entry.tagIDs, [shared.id, privateTag.id])
        XCTAssertEqual(entry.source, source)
        XCTAssertEqual(entry.capturedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertFalse(entry.hasTextConflict)
        let obsolete = try await second.page(.init(text: "obsolete composition"))
        let qr = try await second.page(.init(facet: .qrCode))
        XCTAssertTrue(obsolete.entries.isEmpty)
        XCTAssertTrue(qr.entries.isEmpty)

        await cloud.replayAllChangesInReverseOrder()
        let late = makeModule(services: services, keyByte: 0xDD, time: 3_000)
        try await late.setSyncEnabled(true)
        let replay = try await late.materialize(.init(entryID: capture.entryID, purpose: .normalPaste))
        XCTAssertEqual(replay, expected)
        let latePage = try await late.page(.init())
        let lateEntry = try XCTUnwrap(latePage.entries.first)
        XCTAssertEqual(latePage.entries.count, 1)
        XCTAssertTrue(lateEntry.isFavorite)
        XCTAssertEqual(lateEntry.tagIDs, [shared.id])
        XCTAssertEqual(lateEntry.source, source)
        XCTAssertEqual(lateEntry.capturedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertFalse(lateEntry.hasTextConflict)
        let definitions = try await late.tagDefinitions()
        XCTAssertFalse(definitions.contains { $0.id == privateTag.id })
        let lateObsolete = try await late.page(.init(text: "obsolete composition"))
        XCTAssertTrue(lateObsolete.entries.isEmpty)
    }

    @MainActor
    func testLateRecognitionCannotRestoreResultsAfterTextEditRemovesBitmap() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let recognizer = SyncTestRecognizer(results: [.ocr: ["obsolete image words"], .qr: ["anydoor://obsolete/image"]], held: true)
        let first = makeModule(services: services, keyByte: 0x9A, time: 1_000, recognizer: recognizer)
        let second = makeModule(services: services, keyByte: 0x9B, time: 2_000)
        addTeardownBlock { await recognizer.release() }
        try await first.setAutomaticImageTextIndexingEnabled(true)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-edited-image.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("editable original", forType: .string)
        item.setData(try makeSyncBitmap(), forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        guard case .captured(let captured) = try await first.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected an editable bitmap entry")
        }
        let tag = try await first.createTagDefinition(named: "Edited", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        _ = try await second.apply(.editText(captured.entryID, "current exact text"))
        await second.retrySync()
        await recognizer.release()
        await first.awaitDerivedJobsForTesting()
        await first.retrySync()
        await second.retrySync()
        let obsolete = try await second.page(.init(text: "obsolete"))
        let qr = try await second.page(.init(facet: .qrCode))
        XCTAssertEqual(obsolete.entries, [])
        XCTAssertEqual(qr.entries, [])
        let materialized = try await second.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertEqual(materialized.items, [.init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: "current exact text")])])
        await cloud.reverseDelivery()
        let third = makeModule(services: services, keyByte: 0x9C, time: 3_000)
        try await third.setSyncEnabled(true)
        let replayed = try await third.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertEqual(replayed, materialized)
        let stale = try await third.page(.init(text: "obsolete"))
        XCTAssertEqual(stale.entries, [])
    }

    func testAuthenticatedEntryWithDuplicateStandardTypesFailsAsAWhole() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x97, time: 1_000)
        try await module.setSyncEnabled(true)
        try await Self.publishFixture(.entry(.init(id: UUID(), capturedAt: Date(timeIntervalSince1970: 500),
            sourceBundleID: nil, sourceDisplayName: nil, sourceProvenance: "unknown", favorite: false,
            tags: [.init(id: "shared", name: "Shared")],
            items: [.init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: "first"),
                                           .text(typeIdentifier: "public.utf8-plain-text", value: "second")])],
            facets: ["text"], recognition: .init())), cloud: cloud, keys: keys)
        await module.retrySync()
        let page = try await module.page(.init())
        let status = await module.syncStatus()
        XCTAssertEqual(page.entries, [])
        XCTAssertEqual(status.phase, .failed(.corruptData))
    }

    func testLegacyTextSnapshotAppliesEarlierFavoriteMetadata() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let module = makeModule(services: services, keyByte: 0x96, time: 1_000)
        try await module.setSyncEnabled(true)
        let id = UUID()
        let operationID = UUID()
        try await Self.publishFixture(.metadata(.init(id: id,
            revision: .init(counter: 1, operationID: operationID.uuidString.lowercased()), value: .favorite(true))),
            operationID: operationID, cloud: cloud, keys: keys)
        try await Self.publishFixture(.text(.init(id: id, text: "legacy text", capturedAt: Date(timeIntervalSince1970: 500),
            sourceBundleID: nil, sourceDisplayName: nil, sourceProvenance: "unknown", favorite: false,
            tags: [.init(id: "legacy-shared", name: "Legacy")])), cloud: cloud, keys: keys)
        await module.retrySync()
        let page = try await module.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertTrue(entry.isFavorite)
        XCTAssertEqual(page.entries.count, 1)
        let content = try await module.materialize(.init(entryID: entry.id, purpose: .plainTextPaste))
        XCTAssertEqual(content.items, [.init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: "legacy text")])])
    }

    @MainActor
    func testLaterRecognitionResultsSurviveRestartAndReverseDeliveryWithoutReprocessing() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let recognizer = SyncTestRecognizer(results: [.ocr: ["late invoice 9913"], .qr: ["anydoor://late/qr"]], held: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-late-recognition-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x93, time: 1_000, root: root, recognizer: recognizer)
        let second = makeModule(services: services, keyByte: 0x94, time: 2_000)
        addTeardownBlock { await recognizer.release() }
        try await first.setAutomaticImageTextIndexingEnabled(true)
        let captured = try await first.capture(.init(source: .unknown, content: .bitmap(try makeSyncBitmap(), provenance: .image)))
        let tag = try await first.createTagDefinition(named: "Images", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        try await first.setSyncEnabled(false)
        await recognizer.release()
        await first.awaitDerivedJobsForTesting()
        _ = try await first.apply(.setFavorite(captured.entryID, true))
        try await first.closeStoreForTesting()
        let reopened = makeModule(services: services, keyByte: 0x93, time: 3_000, root: root)
        try await reopened.setSyncEnabled(true)
        await second.retrySync()
        let ocr = try await second.page(.init(text: "invoice 9913"))
        let qr = try await second.page(.init(text: "late/qr", facet: .qrCode))
        XCTAssertEqual(ocr.entries.map(\.id), [captured.entryID])
        XCTAssertEqual(qr.entries.map(\.id), [captured.entryID])
        XCTAssertTrue(qr.entries.first?.isFavorite == true)
        let status = await reopened.syncStatus()
        XCTAssertEqual(status.uploadedEntryCount, 1)
        await cloud.reverseDelivery()
        let receiverRecognizer = SyncTestRecognizer()
        let third = makeModule(services: services, keyByte: 0x95, time: 4_000, recognizer: receiverRecognizer)
        try await third.setSyncEnabled(true)
        let reverseOCR = try await third.page(.init(text: "invoice 9913"))
        let reverseQR = try await third.page(.init(text: "late/qr", facet: .qrCode))
        XCTAssertEqual(reverseOCR.entries.map(\.id), [captured.entryID])
        XCTAssertEqual(reverseQR.entries.map(\.id), [captured.entryID])
        XCTAssertTrue(reverseQR.entries.first?.isFavorite == true)
        let calls = await receiverRecognizer.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testCompletedImageRecognitionTransfersAsSearchableResultsWithoutEnablingReceiverRecognition() async throws {
        let services = ClipboardSyncServices(transport: SyncTestCloud(), keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x91, time: 1_000,
            recognizer: SyncTestRecognizer(results: [.ocr: ["recognized invoice 4721"], .qr: ["anydoor://recognized/qr"]]))
        let receiverRecognizer = SyncTestRecognizer()
        let second = makeModule(services: services, keyByte: 0x92, time: 2_000, recognizer: receiverRecognizer)
        try await first.setAutomaticImageTextIndexingEnabled(true)
        let captured = try await first.capture(.init(source: .unknown, content: .bitmap(try makeSyncBitmap(), provenance: .image)))
        await first.awaitDerivedJobsForTesting()
        let tag = try await first.createTagDefinition(named: "Images", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let ocr = try await second.page(.init(text: "invoice 4721"))
        let qr = try await second.page(.init(text: "recognized/qr", facet: .qrCode))
        XCTAssertEqual(ocr.entries.map(\.id), [captured.entryID])
        XCTAssertEqual(qr.entries.map(\.id), [captured.entryID])
        XCTAssertEqual(qr.entries.first?.facets, [.image, .qrCode])
        let recognitionEnabled = try await second.isAutomaticImageTextIndexingEnabled()
        XCTAssertFalse(recognitionEnabled)
        let calls = await receiverRecognizer.callCount()
        XCTAssertEqual(calls, 0)
        let original = try await first.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        let received = try await second.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertEqual(received, original)
    }

    @MainActor
    func testFavoriteUpdatesSurviveRestartAndReorderingWithoutReplacingRichContentOrPrivateTags() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-favorite-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x87, time: 1_000, root: root)
        let second = makeModule(services: services, keyByte: 0x88, time: 2_000)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-favorite.\(UUID())"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let html = Data("<b>keep rich content</b>".utf8)
        item.setString("keep rich content", forType: .string)
        item.setData(html, forType: .html)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        guard case .captured(let capture) = try await first.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected rich history")
        }
        let tag = try await first.createTagDefinition(named: "Shared", assigningTo: capture.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let privateTag = try await second.createTagDefinition(named: "Receiver private", assigningTo: capture.entryID)
        let recentLocal = try await second.capture(.init(source: .unknown, content: .text("recent receiver-only history")))
        try await first.setSyncEnabled(false)
        _ = try await first.apply(.setFavorite(capture.entryID, true))
        try await first.closeStoreForTesting()
        let reopened = makeModule(services: services, keyByte: 0x87, time: 3_000, root: root)
        try await reopened.setSyncEnabled(true)
        await second.retrySync()
        let page = try await second.page(.init())
        let received = try XCTUnwrap(page.entries.first { $0.id == capture.entryID })
        XCTAssertEqual(page.entries.first?.id, recentLocal.entryID)
        XCTAssertTrue(received.isFavorite)
        XCTAssertEqual(received.tagIDs, [tag.definition.id, privateTag.definition.id])
        let content = try await second.materialize(.init(entryID: received.id, purpose: .normalPaste))
        XCTAssertEqual(content.items, [.init(representations: [
            .text(typeIdentifier: "public.utf8-plain-text", value: "keep rich content"), .data(typeIdentifier: "public.html", html),
        ])])
        let uploaded = await reopened.syncStatus()
        XCTAssertEqual(uploaded.uploadedEntryCount, 1)
        await cloud.reverseDelivery()
        let third = makeModule(services: services, keyByte: 0x89, time: 4_000)
        try await third.setSyncEnabled(true)
        let reversed = try await third.page(.init())
        XCTAssertEqual(reversed.entries.count, 1)
        XCTAssertTrue(try XCTUnwrap(reversed.entries.first).isFavorite)
        XCTAssertEqual(reversed.entries.first?.capturedAt, Date(timeIntervalSince1970: 1_000))
        _ = try await reopened.apply(.setFavorite(capture.entryID, false))
        await reopened.retrySync()
        await second.retrySync()
        await third.retrySync()
        let secondAfterToggle = try await second.page(.init())
        let thirdAfterToggle = try await third.page(.init())
        XCTAssertFalse(try XCTUnwrap(secondAfterToggle.entries.first { $0.id == capture.entryID }).isFavorite)
        XCTAssertFalse(try XCTUnwrap(thirdAfterToggle.entries.first).isFavorite)
        XCTAssertEqual(secondAfterToggle.entries.first?.id, recentLocal.entryID)
    }

    @MainActor
    func testRemoteTextVersionArrivingBeforeFileRootDoesNotDownloadRemovedFile() async throws {
        let fixture = try await fileFixture(names: ["Original attachment.txt"], contents: [Data("old attachment".utf8)],
            exactText: "original file label")
        let initial = try await fixture.sender.page(.init())
        let entryID = try XCTUnwrap(initial.entries.first?.id)
        _ = try await fixture.sender.apply(.editText(entryID, "replacement text"))
        await fixture.sender.retrySync()
        await fixture.cloud.replayAllChangesInReverseOrder()

        try await fixture.receiver.setSyncEnabled(true)
        await fixture.receiver.retrySync()

        let received = try await fixture.receiver.page(.init())
        XCTAssertEqual(received.entries.map(\.id), [entryID])
        XCTAssertEqual(received.entries.first?.syncFiles, [])
        let content = try await fixture.receiver.materialize(.init(entryID: entryID, purpose: .normalPaste))
        XCTAssertEqual(content.items, [.init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: "replacement text")])])
        let downloads = await fixture.cloud.fileBodyDownloadCount()
        XCTAssertEqual(downloads, 0)
        let plan = try await fixture.receiver.textEditPlan(for: entryID)
        XCTAssertFalse(plan.hasConflict)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receiverRoot.appendingPathComponent("Linked Working Copies").path))
    }

    @MainActor
    func testEditingFileBearingTextDoesNotReviveItsPendingFile() async throws {
        let fixture = try await fileFixture(names: ["Obsolete.txt"], contents: [Data("obsolete bytes".utf8)],
            receiverFaults: .init(points: [.syncFileBeforePublication]), exactText: "original label")
        try await fixture.receiver.setSyncEnabled(true)
        let page = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        _ = try await fixture.receiver.apply(.editText(entry.id, "edited text"))
        let downloadsBefore = await fixture.cloud.fileBodyDownloadCount()
        await fixture.receiver.retrySync()
        let edited = try await fixture.receiver.page(.init())
        XCTAssertEqual(edited.entries.first?.syncFiles, [])
        let downloadsAfter = await fixture.cloud.fileBodyDownloadCount()
        XCTAssertEqual(downloadsAfter, downloadsBefore)
        let materialized = try await fixture.receiver.materialize(.init(entryID: entry.id, purpose: .normalPaste))
        XCTAssertEqual(materialized.items, [.init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: "edited text")])])
    }

    @MainActor
    func testOrderedFileNamesAndBytesAreEncryptedOutsideVisibleWorkingCopies() async throws {
        let names = ["Confidential first.txt", "Confidential second.txt"]
        let bytes = [Data("first confidential file body".utf8), Data("second confidential file body".utf8)]
        let fixture = try await fileFixture(names: names, contents: bytes)
        try await fixture.receiver.setSyncEnabled(true)
        let page = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        let materialized = try await fixture.receiver.materialize(.init(entryID: entry.id, purpose: .normalPaste))
        let files = materialized.items.flatMap(\.representations).compactMap { representation -> ClipboardHistoryMaterializedFileReference? in
            if case .file(let file) = representation { return file }
            return nil
        }
        XCTAssertEqual(files.map(\.displayName), names)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0.currentURL) }, bytes)
        let secrets = bytes + names.map { Data($0.utf8) } + fixture.sourceURLs.map { Data($0.path.utf8) }
        for upload in await fixture.cloud.currentUploads() {
            for artifact in upload.chunks + [try JSONEncoder().encode(upload.record)] {
                for secret in secrets { XCTAssertNil(artifact.range(of: secret)) }
            }
        }
        let workingRoot = fixture.receiverRoot.appendingPathComponent("Linked Working Copies").resolvingSymlinksInPath().pathComponents
        XCTAssertTrue(files.allSatisfy { $0.currentURL.resolvingSymlinksInPath().pathComponents.starts(with: workingRoot) })
        let persisted = try XCTUnwrap(FileManager.default.enumerator(at: fixture.receiverRoot, includingPropertiesForKeys: [.isRegularFileKey]))
        for url in persisted.allObjects.compactMap({ $0 as? URL })
            where !url.resolvingSymlinksInPath().pathComponents.starts(with: workingRoot) {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let artifact = try Data(contentsOf: url)
            for secret in secrets { XCTAssertNil(artifact.range(of: secret)) }
        }
    }

    @MainActor
    func testWorkingRootSymlinkCannotRedirectFilePublication() async throws {
        let fixture = try await fileFixture(names: ["Safe.txt"], contents: [Data("must stay confined".utf8)])
        let outside = fixture.root.appendingPathComponent("Unrelated")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.receiverRoot.appendingPathComponent("Linked Working Copies"), withDestinationURL: outside)
        try await fixture.receiver.setSyncEnabled(true)
        let page = try await fixture.receiver.page(.init())
        XCTAssertEqual(page.entries.first?.syncFiles.map(\.state), [.waitingForDownload])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    @MainActor
    func testUnavailableInitialSourceRecoversAfterReopeningWithoutAdoptingAReplacement() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission denial requires an unprivileged test process") }
        let bytes = Data("the original identity returns".utf8)
        let fixture = try await fileFixture(names: ["Recover.txt", "Replaced.txt"], contents: [bytes, Data("old identity".utf8)],
            beforeEnable: { urls in
                for url in urls { XCTAssertEqual(chmod(url.path, 0o000), 0) }
            })
        defer { for url in fixture.sourceURLs { _ = chmod(url.path, 0o600) } }
        try await fixture.receiver.setSyncEnabled(true)
        let initial = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(initial.entries.first)
        XCTAssertEqual(entry.syncFiles.map(\.state), [.sourceUnavailable, .sourceUnavailable])
        try await fixture.sender.closeStoreForTesting()
        XCTAssertEqual(chmod(fixture.sourceURLs[0].path, 0o600), 0)
        try FileManager.default.removeItem(at: fixture.sourceURLs[1])
        try Data("unrelated replacement".utf8).write(to: fixture.sourceURLs[1])
        let reopened = makeModule(services: fixture.services, keyByte: 0x71, time: 3_000, root: fixture.senderRoot)

        await reopened.resumeSync()
        await fixture.receiver.retrySync()

        let result = try await fixture.receiver.page(.init())
        let files = try XCTUnwrap(result.entries.first).syncFiles
        XCTAssertEqual(files.map(\.id), entry.syncFiles.map(\.id))
        XCTAssertEqual(files.map(\.state), [.complete, .sourceUnavailable])
        XCTAssertNotEqual(files[0].versionID, entry.syncFiles[0].versionID)
        XCTAssertEqual(files[1].versionID, entry.syncFiles[1].versionID)
        XCTAssertFalse(files[0].hasConflict)
        let locations = try await fixture.receiver.linkedFileLocations(for: entry.id)
        let recovered = try XCTUnwrap(locations.first { $0.objectID == files[0].id })
        XCTAssertEqual(try Data(contentsOf: recovered.url), bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURLs[1]), Data("unrelated replacement".utf8))
    }

    @MainActor
    func testFileBackfillReadsCurrentBytesAndKeepsUnavailableMembersInOrder() async throws {
        let fixture = try await fileFixture(names: ["Edited.txt", "Gone.txt"],
            contents: [Data("old capture".utf8), Data("gone".utf8)], beforeEnable: { urls in
                try Data("current file version".utf8).write(to: urls[0])
                try FileManager.default.removeItem(at: urls[1])
            })
        try await fixture.receiver.setSyncEnabled(true)
        let page = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(entry.syncFiles.map(\.displayName), ["Edited.txt", "Gone.txt"])
        XCTAssertEqual(entry.syncFiles.map(\.state), [.complete, .sourceUnavailable])
        do {
            _ = try await fixture.receiver.materialize(.init(entryID: entry.id, purpose: .normalPaste))
            XCTFail("One unavailable member must block the whole entry")
        } catch ClipboardHistoryModuleError.syncFilesPending(let id, let count) {
            XCTAssertEqual(id, entry.id)
            XCTAssertEqual(count, 1)
        }
        let workingRoot = fixture.receiverRoot.appendingPathComponent("Linked Working Copies")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: workingRoot, includingPropertiesForKeys: nil))
            .allObjects.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "Edited.txt" }
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), Data("current file version".utf8))
    }

    @MainActor
    func testCorruptFileBodyStaysPendingAndNeverPublishesPlaintext() async throws {
        let fixture = try await fileFixture(names: ["Confidential.txt"], contents: [Data("secret file content".utf8)])
        await fixture.cloud.damageNextFileBodyDownload()
        try await fixture.receiver.setSyncEnabled(true)
        let status = await fixture.receiver.syncStatus()
        XCTAssertEqual(status.phase, .failed(.corruptData))
        let page = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(entry.syncFiles.map(\.state), [.waitingForDownload])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receiverRoot.appendingPathComponent("Linked Working Copies").path))
        do {
            _ = try await fixture.receiver.materialize(.init(entryID: entry.id, purpose: .normalPaste))
            XCTFail("Unverified content must not materialize")
        } catch ClipboardHistoryModuleError.syncFilesPending {}
        await fixture.receiver.retrySync()
        let repaired = try await fixture.receiver.page(.init())
        XCTAssertEqual(repaired.entries[0].syncFiles.map(\.state), [.complete])
        XCTAssertEqual(repaired.entries.count, 1)
    }

    @MainActor
    func testFilePublicationInterruptionsRecoverAfterReopenWithoutDuplicateEntries() async throws {
        for point in [ClipboardHistoryFaultPoint.syncFileBeforePublication, .syncFileAfterPublication] {
            let fixture = try await fileFixture(names: ["Recovered.txt"], contents: [Data("recoverable".utf8)],
                receiverFaults: .init(points: [point]))
            try await fixture.receiver.setSyncEnabled(true)
            let pending = try await fixture.receiver.page(.init())
            XCTAssertEqual(pending.entries.count, 1)
            XCTAssertEqual(pending.entries[0].syncFiles.map(\.state), [.waitingForDownload])
            try await fixture.receiver.closeStoreForTesting()
            let reopened = makeModule(services: fixture.services, keyByte: 0x72, time: 3_000, root: fixture.receiverRoot)
            await reopened.resumeSync()
            let recovered = try await reopened.page(.init())
            XCTAssertEqual(recovered.entries.map(\.id), pending.entries.map(\.id))
            XCTAssertEqual(recovered.entries[0].syncFiles.map(\.state), [.complete])
            let content = try await reopened.materialize(.init(entryID: recovered.entries[0].id, purpose: .normalPaste))
            guard case .file(let file) = content.items[0].representations[0] else { return XCTFail("Missing recovered file") }
            XCTAssertEqual(try Data(contentsOf: file.currentURL), Data("recoverable".utf8))
        }
    }

    @MainActor
    func testLargeFileMetadataRemainsPendingWithoutImplicitBodyDownload() async throws {
        let fixture = try await fileFixture(names: ["Large.bin"], contents: [Data(repeating: 0x48, count: 5_000_001)])
        try await fixture.receiver.setSyncEnabled(true)
        let page = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(entry.syncFiles.map(\.originalByteCount), [5_000_001])
        XCTAssertEqual(entry.syncFiles.map(\.state), [.waitingForDownload])
        let uploads = await fixture.cloud.currentUploads()
        XCTAssertTrue(uploads.contains { $0.record.kind == .fileBody }, "Large eligible files must upload automatically")
        do {
            _ = try await fixture.receiver.materialize(.init(entryID: entry.id, purpose: .hostAction))
            XCTFail("Preview or copy must not implicitly download a pending file")
        } catch ClipboardHistoryModuleError.syncFilesPending {}
        let downloads = await fixture.cloud.fileBodyDownloadCount()
        XCTAssertEqual(downloads, 0)
    }

    @MainActor
    func testExplicitLargeFileDownloadPublishesTheCompleteVersion() async throws {
        let bytes = Data(repeating: 0x5D, count: 5_000_001)
        let fixture = try await fileFixture(names: ["Manual.bin"], contents: [bytes])
        try await fixture.receiver.setSyncEnabled(true)
        let pending = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(pending.entries.first)
        let file = try XCTUnwrap(entry.syncFiles.first)

        try await fixture.receiver.requestSyncFileDownload(entryID: entry.id, objectID: file.id, versionID: file.versionID)

        let page = try await fixture.receiver.page(.init())
        XCTAssertEqual(page.entries.first?.syncFiles.map(\.state), [.complete])
        let content = try await fixture.receiver.materialize(.init(entryID: entry.id, purpose: .normalPaste))
        guard case .file(let reference) = content.items[0].representations[0] else { return XCTFail("Missing complete file") }
        XCTAssertEqual(try Data(contentsOf: reference.currentURL), bytes)
    }

    @MainActor
    func testEachLargeVersionRequiresItsOwnDownloadAndKeepsTheOldFileUntilReplacementReady() async throws {
        let firstBytes = Data(repeating: 0x35, count: 5_000_001)
        let fixture = try await fileFixture(names: ["Versioned.bin"], contents: [firstBytes])
        try await fixture.receiver.setSyncEnabled(true)
        let originalPage = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(originalPage.entries.first)
        let first = try XCTUnwrap(entry.syncFiles.first)
        try await fixture.receiver.requestSyncFileDownload(entryID: entry.id, objectID: first.id, versionID: first.versionID)
        let newer = Data(repeating: 0x62, count: 5_000_002)
        try newer.write(to: fixture.sourceURLs[0])
        try await fixture.sender.refreshSyncFile(entryID: entry.id, objectID: first.id)
        await fixture.receiver.retrySync()

        let updated = try await fixture.receiver.page(.init())
        let second = try XCTUnwrap(updated.entries.first?.syncFiles.first)
        XCTAssertNotEqual(second.versionID, first.versionID)
        XCTAssertEqual(second.availableVersionID, first.versionID)
        let linkedBeforeDownload = try await fixture.receiver.linkedFileLocations(for: entry.id)
        XCTAssertEqual(linkedBeforeDownload.first?.state, .current, "Old linked version must remain available")
        let old = try await fixture.receiver.materialize(.init(entryID: entry.id, purpose: .normalPaste))
        guard case .file(let oldFile) = old.items[0].representations[0] else { return XCTFail("Old file was lost") }
        XCTAssertEqual(try Data(contentsOf: oldFile.currentURL), firstBytes)
        let independent = fixture.receiverRoot.appendingPathComponent("Independent previous version.bin")
        _ = try await fixture.receiver.exportFiles(entry.id, to: [independent])

        try await fixture.receiver.requestSyncFileDownload(entryID: entry.id, objectID: first.id, versionID: second.versionID)
        let linkedAfterDownload = try await fixture.receiver.linkedFileLocations(for: entry.id)
        XCTAssertEqual(linkedAfterDownload.first?.state, .current, "New verified version must apply to the linked location")
        let latest = try await fixture.receiver.materialize(.init(entryID: entry.id, purpose: .normalPaste))
        guard case .file(let latestFile) = latest.items[0].representations[0] else { return XCTFail("Missing update") }
        XCTAssertEqual(try Data(contentsOf: latestFile.currentURL), newer)
        XCTAssertEqual(latestFile.currentURL, oldFile.currentURL, "The linked working location stays stable")
        XCTAssertEqual(try Data(contentsOf: independent), firstBytes)
    }

    @MainActor
    func testThresholdIsPerOriginalFileAndPendingMemberPreventsSubsetPaste() async throws {
        let fixture = try await fileFixture(names: ["Below.bin", "At.bin", "Above.bin"], contents: [
            Data(repeating: 0x41, count: 4_999_999), Data(repeating: 0x42, count: 5_000_000), Data(repeating: 0x43, count: 5_000_001)])
        try await fixture.receiver.setSyncEnabled(true)
        let page = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(entry.syncFiles.map(\.state), [.complete, .complete, .waitingForDownload])
        XCTAssertEqual(entry.syncFiles.map(\.originalByteCount), [4_999_999, 5_000_000, 5_000_001])
        do {
            _ = try await fixture.receiver.materialize(.init(entryID: entry.id, purpose: .normalPaste))
            XCTFail("The pending third member must prevent a partial paste")
        } catch ClipboardHistoryModuleError.syncFilesPending {}
        let file = entry.syncFiles[2]
        try await fixture.receiver.requestSyncFileDownload(entryID: entry.id, objectID: file.id, versionID: file.versionID)
        let ready = try await fixture.receiver.materialize(.init(entryID: entry.id, purpose: .normalPaste))
        XCTAssertEqual(ready.items.count, 3)
    }

    @MainActor
    func testGrowthPastThresholdKeepsSmallVersionAndRejectsStaleDownloadAction() async throws {
        let fixture = try await fileFixture(names: ["Growing.bin"], contents: [Data("small".utf8)])
        try await fixture.receiver.setSyncEnabled(true)
        let initial = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(initial.entries.first)
        let file = try XCTUnwrap(entry.syncFiles.first)
        try Data(repeating: 0x51, count: 5_000_001).write(to: fixture.sourceURLs[0])
        try await fixture.sender.refreshSyncFile(entryID: entry.id, objectID: file.id)
        await fixture.receiver.retrySync()
        let updated = try await fixture.receiver.page(.init())
        let newer = try XCTUnwrap(updated.entries.first?.syncFiles.first)
        XCTAssertEqual(newer.state, .updateAvailable)
        XCTAssertEqual(newer.availableVersionID, file.versionID)
        do {
            try await fixture.receiver.requestSyncFileDownload(entryID: entry.id, objectID: file.id, versionID: file.versionID)
            XCTFail("A stale button must not authorize the new version")
        } catch ClipboardHistoryModuleError.operationUnavailable {}
        let old = try await fixture.receiver.materialize(.init(entryID: entry.id, purpose: .normalPaste))
        guard case .file(let reference) = old.items[0].representations[0] else { return XCTFail("Missing old version") }
        XCTAssertEqual(try Data(contentsOf: reference.currentURL), Data("small".utf8))
        let segments = await fixture.cloud.requestedFileSegments()
        XCTAssertTrue(segments.isEmpty)
    }

    @MainActor
    func testCorruptLargeSegmentFailsWithoutPublishingAndRetrySucceeds() async throws {
        let fixture = try await fileFixture(names: ["Authenticated.bin"], contents: [Data(repeating: 0x38, count: 5_000_001)])
        try await fixture.receiver.setSyncEnabled(true)
        let page = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        let file = try XCTUnwrap(entry.syncFiles.first)
        await fixture.cloud.damageNextFileBodyDownload()
        try await fixture.receiver.requestSyncFileDownload(entryID: entry.id, objectID: file.id, versionID: file.versionID)
        let damaged = try await fixture.receiver.page(.init())
        XCTAssertEqual(damaged.entries.first?.syncFiles.first?.transferFailure, .corruptData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receiverRoot.appendingPathComponent("Linked Working Copies").path))
        try await fixture.receiver.requestSyncFileDownload(entryID: entry.id, objectID: file.id, versionID: file.versionID)
        let repaired = try await fixture.receiver.page(.init())
        XCTAssertEqual(repaired.entries.first?.syncFiles.first?.state, .complete)
    }

    @MainActor
    func testOversizedLegacyFileEnvelopeIsRejectedBeforeDownload() async throws {
        for size in [Int64(5_000_001), Int64.max] {
            let fixture = try await fileFixture(names: ["Legacy.bin"], contents: [Data("small".utf8)])
            let page = try await fixture.sender.page(.init())
            let file = try XCTUnwrap(page.entries.first?.syncFiles.first)
            let account = try await fixture.cloud.account()
            let observed = try await fixture.cloud.control(for: account)
            let control = try XCTUnwrap(observed)
            let loaded = try await fixture.services.keys.load(account: account, keyID: control.keyID)
            let key = try XCTUnwrap(loaded)
            let version = UUID()
            let descriptor = ClipboardSyncFileDescriptor(objectID: file.id, versionID: version,
                displayName: "Legacy.bin", originalByteCount: size, contentDigest: Data(repeating: 0, count: 32),
                body: .init(recordID: "v1-\(version.uuidString.lowercased())", operationID: version,
                    epoch: control.epoch, keyID: control.keyID, kind: .fileBody, chunkCount: 1,
                    encryptedByteCount: 100, digest: Data(repeating: 0, count: 32)), state: .available)
            let upload = try ClipboardSyncCodec.seal(.fileVersion(.init(descriptor: descriptor, parents: [file.versionID])),
                account: account, control: control, key: key)
            _ = try await fixture.cloud.commit(upload, for: account, control: control)
            try await fixture.receiver.setSyncEnabled(true)
            let status = await fixture.receiver.syncStatus()
            XCTAssertEqual(status.phase, .failed(.corruptData))
            let received = try await fixture.receiver.page(.init())
            XCTAssertEqual(received.entries.first?.syncFiles.first?.versionID, file.versionID)
        }
    }

    @MainActor
    func testDamagedRetainedCiphertextIsFetchedAgainAfterReopen() async throws {
        let fixture = try await fileFixture(names: ["Cache.bin"], contents: [Data(repeating: 0x61, count: 5_000_001)])
        try await fixture.receiver.setSyncEnabled(true)
        let page = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        let file = try XCTUnwrap(entry.syncFiles.first)
        await fixture.cloud.failFileSegmentOnce(at: 1)
        try await fixture.receiver.requestSyncFileDownload(entryID: entry.id, objectID: file.id, versionID: file.versionID)
        try await fixture.receiver.closeStoreForTesting()
        let files = FileManager.default.enumerator(at: fixture.receiverRoot.appendingPathComponent("SyncTransfers/Downloads"),
            includingPropertiesForKeys: nil)
        let encrypted = try XCTUnwrap(files?.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == "0.ciphertext" })
        try Data([0x01]).write(to: encrypted)
        let reopened = makeModule(services: fixture.services, keyByte: 0x72, time: 3_000, root: fixture.receiverRoot)
        await reopened.resumeSync()
        let complete = try await reopened.page(.init())
        XCTAssertEqual(complete.entries.first?.syncFiles.first?.state, .complete)
        let requests = await fixture.cloud.requestedFileSegments()
        XCTAssertEqual(requests, [0, 1, 0, 1])
    }

    @MainActor
    func testInterruptedLargeUploadResumesTheSameVersionAfterReopen() async throws {
        let fixture = try await fileFixture(names: ["Upload.bin"], contents: [Data("first".utf8)])
        let initial = try await fixture.sender.page(.init())
        let entry = try XCTUnwrap(initial.entries.first)
        let file = try XCTUnwrap(entry.syncFiles.first)
        await fixture.cloud.failFileUploadOnce(after: 0)
        try Data(repeating: 0x32, count: 9_000_001).write(to: fixture.sourceURLs[0])
        try await fixture.sender.refreshSyncFile(entryID: entry.id, objectID: file.id)
        let failed = try await fixture.sender.page(.init())
        let version = try XCTUnwrap(failed.entries.first?.syncFiles.first)
        XCTAssertTrue(version.uploadPending)
        XCTAssertEqual(version.transferFailure, .network)
        XCTAssertEqual(version.transferredByteCount, 4_194_304)
        try await fixture.sender.closeStoreForTesting()
        let reopened = makeModule(services: fixture.services, keyByte: 0x71, time: 3_000, root: fixture.senderRoot)
        let retained = try await reopened.page(.init())
        XCTAssertEqual(retained.entries.first?.syncFiles.first?.versionID, version.versionID)
        XCTAssertEqual(retained.entries.first?.syncFiles.first?.transferFailure, .network)
        await reopened.resumeSync()
        let resumed = try await reopened.page(.init())
        XCTAssertFalse(try XCTUnwrap(resumed.entries.first?.syncFiles.first).uploadPending)
        let committed = try await reopened.syncFileVersionIsCommitted(objectID: file.id, versionID: version.versionID)
        XCTAssertTrue(committed)
        let attempts = await fixture.cloud.fileUploadAttempts()
        XCTAssertEqual(attempts, [version.versionID, version.versionID])
    }

    @MainActor
    func testWorkingCopyPermissionFailuresRemainDistinctAndRecoverAfterAccessIsRestored() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission denial requires an unprivileged test process") }
        for byteCount in [12, 5_000_001] {
            for (existingWorkingRoot, immutable) in [(false, false), (true, false), (false, true), (true, true)] {
                let permissionRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sync-permission-\(UUID())")
                removeClipboardHistoryDirectoryAfterTest(permissionRoot)
                let parent = permissionRoot.appendingPathComponent("Folder")
                let workingRoot = parent.appendingPathComponent("Working Copies")
                try FileManager.default.createDirectory(at: existingWorkingRoot ? workingRoot : parent,
                    withIntermediateDirectories: true)
                let denied = existingWorkingRoot ? workingRoot : parent
                if immutable { XCTAssertEqual(chflags(denied.path, UInt32(UF_IMMUTABLE)), 0) }
                else { XCTAssertEqual(chmod(denied.path, 0o500), 0) }
                defer {
                    _ = chflags(denied.path, 0)
                    _ = chmod(denied.path, 0o700)
                }
                let probe = denied.appendingPathComponent("Denied creation")
                let descriptor = open(probe.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                let deniedErrno = errno
                if descriptor >= 0 { close(descriptor) }
                XCTAssertEqual(descriptor, -1)
                XCTAssertEqual(deniedErrno, immutable ? EPERM : EACCES)
                let bytes = Data(repeating: 0x61, count: byteCount)
                let fixture = try await fileFixture(names: ["Protected.bin"], contents: [bytes],
                    receiverWorkingRoot: workingRoot)
                var receiver = fixture.receiver
                try await receiver.setSyncEnabled(true)
                let initialPage = try await receiver.page(.init())
                let entry = try XCTUnwrap(initialPage.entries.first)
                let file = try XCTUnwrap(entry.syncFiles.first)
                if byteCount > 5_000_000 {
                    try await receiver.requestSyncFileDownload(entryID: entry.id, objectID: file.id, versionID: file.versionID)
                }

                let failed = try await receiver.page(.init())
                XCTAssertEqual(failed.entries.first?.syncFiles.first?.transferFailure?.rawValue, "localFileAccessDenied")
                let status = await receiver.syncStatus()
                if case .failed(let failure) = status.phase {
                    XCTAssertEqual(failure.rawValue, "localFileAccessDenied")
                } else { XCTFail("Expected a distinct local file access failure, got \(status.phase)") }
                XCTAssertTrue(status.isEnabled)

                let reopen = byteCount == 12 && !existingWorkingRoot && !immutable
                if reopen {
                    try await receiver.closeStoreForTesting()
                    receiver = makeModule(services: fixture.services, keyByte: 0x72, time: 3_000,
                        root: fixture.receiverRoot, workingRoot: workingRoot)
                    let retained = try await receiver.page(.init())
                    XCTAssertEqual(retained.entries.first?.syncFiles.first?.transferFailure, .localFileAccessDenied)
                    let retainedStatus = await receiver.syncStatus()
                    XCTAssertEqual(retainedStatus.phase, .failed(.localFileAccessDenied))
                }
                XCTAssertEqual(chflags(denied.path, 0), 0)
                XCTAssertEqual(chmod(denied.path, 0o700), 0)
                if reopen { await receiver.resumeSync() } else { await receiver.retrySync() }
                let recovered = try await receiver.page(.init())
                XCTAssertEqual(recovered.entries.first?.syncFiles.first?.state, .complete)
                XCTAssertNil(recovered.entries.first?.syncFiles.first?.transferFailure)
                let materialized = try await receiver.materialize(.init(entryID: entry.id, purpose: .normalPaste))
                guard case .file(let reference) = materialized.items[0].representations[0] else {
                    return XCTFail("Missing recovered working copy")
                }
                XCTAssertEqual(try Data(contentsOf: reference.currentURL), bytes)
            }
        }
    }

    @MainActor
    func testDeniedCiphertextReadReportsLocalFileAccessAndResumesTheSameUpload() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission denial requires an unprivileged test process") }
        let fixture = try await fileFixture(names: ["Upload.bin"], contents: [Data("initial".utf8)])
        let initialPage = try await fixture.sender.page(.init())
        let entry = try XCTUnwrap(initialPage.entries.first)
        let original = try XCTUnwrap(entry.syncFiles.first)
        await fixture.cloud.failFileUploadOnce(after: 0)
        try Data(repeating: 0x52, count: 5_000_001).write(to: fixture.sourceURLs[0])
        try await fixture.sender.refreshSyncFile(entryID: entry.id, objectID: original.id)
        let pendingPage = try await fixture.sender.page(.init())
        let pending = try XCTUnwrap(pendingPage.entries.first?.syncFiles.first)
        XCTAssertTrue(pending.uploadPending)
        let directory = fixture.senderRoot.appendingPathComponent("SyncTransfers/Uploads/\(pending.versionID.uuidString)")
        let segment = directory.appendingPathComponent("0.ciphertext")
        XCTAssertEqual(chmod(segment.path, 0), 0)
        defer { _ = chmod(segment.path, 0o600) }

        await fixture.sender.retrySync()

        let failed = try await fixture.sender.page(.init())
        XCTAssertEqual(failed.entries.first?.syncFiles.first?.transferFailure, .localFileAccessDenied)
        let failedStatus = await fixture.sender.syncStatus()
        XCTAssertEqual(failedStatus.phase, .failed(.localFileAccessDenied))
        XCTAssertEqual(chmod(segment.path, 0o600), 0)
        await fixture.sender.retrySync()
        let complete = try await fixture.sender.page(.init())
        XCTAssertEqual(complete.entries.first?.syncFiles.first?.versionID, pending.versionID)
        XCTAssertFalse(try XCTUnwrap(complete.entries.first?.syncFiles.first).uploadPending)
        XCTAssertNil(complete.entries.first?.syncFiles.first?.transferFailure)
    }

    @MainActor
    func testLargeDownloadStorageAndQuotaFailuresKeepPreviousVersionUsable() async throws {
        let faults: [(ClipboardSyncServiceError, ClipboardHistorySyncFileFailure)] = [
            (.quota, .quota), (.localStorage, .localStorage), (.accessDenied, .accessDenied)]
        for (fault, expected) in faults {
            let fixture = try await fileFixture(names: ["Retained.bin"], contents: [Data("old complete".utf8)])
            try await fixture.receiver.setSyncEnabled(true)
            let initial = try await fixture.receiver.page(.init())
            let entry = try XCTUnwrap(initial.entries.first)
            let file = try XCTUnwrap(entry.syncFiles.first)
            try Data(repeating: 0x71, count: 5_000_001).write(to: fixture.sourceURLs[0])
            try await fixture.sender.refreshSyncFile(entryID: entry.id, objectID: file.id)
            await fixture.receiver.retrySync()
            let updated = try await fixture.receiver.page(.init())
            let newVersion = try XCTUnwrap(updated.entries.first?.syncFiles.first)
            await fixture.cloud.failFileSegmentOnce(at: 1, with: fault)
            try await fixture.receiver.requestSyncFileDownload(entryID: entry.id, objectID: file.id, versionID: newVersion.versionID)
            let failed = try await fixture.receiver.page(.init())
            XCTAssertEqual(failed.entries.first?.syncFiles.first?.transferFailure, expected)
            let content = try await fixture.receiver.materialize(.init(entryID: entry.id, purpose: .normalPaste))
            guard case .file(let old) = content.items[0].representations[0] else { return XCTFail("Missing previous version") }
            XCTAssertEqual(try Data(contentsOf: old.currentURL), Data("old complete".utf8))
            try await fixture.receiver.requestSyncFileDownload(entryID: entry.id, objectID: file.id, versionID: newVersion.versionID)
            let complete = try await fixture.receiver.page(.init())
            XCTAssertEqual(complete.entries.first?.syncFiles.first?.state, .complete)
        }
    }

    @MainActor
    func testDisablingDuringLargeDownloadRejectsLateSegmentCompletion() async throws {
        let fixture = try await fileFixture(names: ["Late.bin"], contents: [Data(repeating: 0x44, count: 5_000_001)])
        try await fixture.receiver.setSyncEnabled(true)
        let page = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        let file = try XCTUnwrap(entry.syncFiles.first)
        await fixture.cloud.holdNextFileSegment()
        let request = Task { try await fixture.receiver.requestSyncFileDownload(entryID: entry.id, objectID: file.id, versionID: file.versionID) }
        await fixture.cloud.waitForHeldFileSegment()
        try await fixture.receiver.setSyncEnabled(false)
        try await request.value
        let disabled = try await fixture.receiver.page(.init())
        XCTAssertEqual(disabled.entries.first?.syncFiles.first?.state, .waitingForDownload)
        XCTAssertEqual(disabled.entries.first?.syncFiles.first?.transferredByteCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receiverRoot.appendingPathComponent("Linked Working Copies").path))
        try await fixture.receiver.setSyncEnabled(true)
        let resumed = try await fixture.receiver.page(.init())
        XCTAssertEqual(resumed.entries.first?.syncFiles.first?.state, .complete)
    }

    @MainActor
    func testInterruptedLargeDownloadRetainsProgressAndRetriesOnlyMissingSegmentsAfterReopen() async throws {
        let bytes = Data(repeating: 0x68, count: 9_000_001)
        let fixture = try await fileFixture(names: ["Resume.bin"], contents: [bytes])
        try await fixture.receiver.setSyncEnabled(true)
        let initialPage = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(initialPage.entries.first)
        let file = try XCTUnwrap(entry.syncFiles.first)
        await fixture.cloud.failFileSegmentOnce(at: 1)
        try await fixture.receiver.requestSyncFileDownload(entryID: entry.id, objectID: file.id, versionID: file.versionID)
        let interruptedPage = try await fixture.receiver.page(.init())
        let interrupted = try XCTUnwrap(interruptedPage.entries.first?.syncFiles.first)
        XCTAssertEqual(interrupted.transferredByteCount, 4_194_304)
        XCTAssertEqual(interrupted.transferFailure, .network)
        XCTAssertEqual(interrupted.state, .waitingForDownload)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeModule(services: fixture.services, keyByte: 0x72, time: 3_000, root: fixture.receiverRoot)
        let persistedPage = try await reopened.page(.init())
        let persisted = try XCTUnwrap(persistedPage.entries.first?.syncFiles.first)
        XCTAssertEqual(persisted.transferredByteCount, 4_194_304)
        XCTAssertEqual(persisted.transferFailure, .network)
        await reopened.resumeSync()
        let completedPage = try await reopened.page(.init())
        let completed = try XCTUnwrap(completedPage.entries.first?.syncFiles.first)
        XCTAssertEqual(completed.state, .complete)
        XCTAssertNil(completed.transferFailure)
        let indices = await fixture.cloud.requestedFileSegments()
        XCTAssertEqual(indices, [0, 1, 1, 2])
        let maximum = await fixture.cloud.largestFileSegment()
        XCTAssertEqual(maximum, 4_194_332)
        let content = try await reopened.materialize(.init(entryID: entry.id, purpose: .normalPaste))
        guard case .file(let reference) = content.items[0].representations[0] else { return XCTFail("Missing complete file") }
        XCTAssertEqual(try Data(contentsOf: reference.currentURL), bytes)
    }

    @MainActor
    func testReopeningAfterWorkingFileRemovalDoesNotClaimACompleteFile() async throws {
        let fixture = try await fileFixture(names: ["Removable.txt"], contents: [Data("complete bytes".utf8)])
        try await fixture.receiver.setSyncEnabled(true)
        let page = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        let content = try await fixture.receiver.materialize(.init(entryID: entry.id, purpose: .normalPaste))
        guard case .file(let file) = content.items[0].representations[0] else { return XCTFail("Missing working file") }
        try FileManager.default.removeItem(at: file.currentURL)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeModule(services: fixture.services, keyByte: 0x72, time: 3_000, root: fixture.receiverRoot)
        let reopenedPage = try await reopened.page(.init())
        XCTAssertEqual(reopenedPage.entries.count, 1)
        XCTAssertFalse(reopenedPage.entries[0].syncFiles.allSatisfy { $0.state == .complete })
        do {
            _ = try await reopened.materialize(.init(entryID: entry.id, purpose: .normalPaste))
            XCTFail("A removed working file must not materialize")
        } catch ClipboardHistoryModuleError.fileReferencesUnavailable(let id, let count) {
            XCTAssertEqual(id, entry.id)
            XCTAssertEqual(count, 1)
        }
    }

    @MainActor
    func testSavingSyncedFileCreatesIndependentCopyAndRefusesCollision() async throws {
        let fixture = try await fileFixture(names: ["Notes.txt"], contents: [Data("original version".utf8)])
        try await fixture.receiver.setSyncEnabled(true)
        let page = try await fixture.receiver.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        let destination = fixture.root.appendingPathComponent("Saved notes.txt")

        let saved = try await fixture.receiver.exportFiles(entry.id, to: [destination])

        XCTAssertEqual(saved, [destination])
        XCTAssertEqual(try Data(contentsOf: destination), Data("original version".utf8))
        try Data("independent edit".utf8).write(to: destination)
        do {
            _ = try await fixture.receiver.exportFiles(entry.id, to: [destination])
            XCTFail("An existing destination must not be overwritten")
        } catch {}
        let materialized = try await fixture.receiver.materialize(.init(entryID: entry.id, purpose: .normalPaste))
        guard case .file(let file) = materialized.items[0].representations[0] else { return XCTFail("Missing working file") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL), Data("original version".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("independent edit".utf8))
        let uploadsBefore = await fixture.cloud.currentUploads().count
        await fixture.receiver.retrySync()
        let uploadsAfter = await fixture.cloud.currentUploads().count
        XCTAssertEqual(uploadsAfter, uploadsBefore)
    }

    @MainActor
    private func fileFixture(names: [String], contents: [Data],
        receiverFaults: ClipboardHistoryFaultInjector = .init(),
        receiverWorkingRoot: URL? = nil,
        exactText: String? = nil,
        beforeEnable: ([URL]) throws -> Void = { _ in }
    ) async throws -> (
        sender: ClipboardHistoryModule, receiver: ClipboardHistoryModule, cloud: SyncTestCloud,
        services: ClipboardSyncServices, root: URL, receiverRoot: URL, sourceURLs: [URL], senderRoot: URL
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-files-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let senderRoot = root.appendingPathComponent("Sender")
        let sender = makeModule(services: services, keyByte: 0x71, time: 1_000, root: senderRoot)
        let receiverRoot = root.appendingPathComponent("Receiver")
        let receiver = makeModule(services: services, keyByte: 0x72, time: 2_000, root: receiverRoot,
            faults: receiverFaults, workingRoot: receiverWorkingRoot)
        let urls = try zip(names, contents).map { name, data in
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-file-fixture.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let items = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if let exactText { item.setString(exactText, forType: .string) }
            return item
        }
        XCTAssertTrue(pasteboard.writeObjects(items))
        let result = try await sender.capture(.init(pasteboard: pasteboard), source: .unknown)
        guard case .captured(let captured) = result else { throw ClipboardHistoryModuleError.operationUnavailable }
        let tag = try await sender.createTagDefinition(named: "Files", assigningTo: captured.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try beforeEnable(urls)
        try await sender.setSyncEnabled(true)
        return (sender, receiver, cloud, services, root, receiverRoot, urls, senderRoot)
    }

    @MainActor
    func testSharedRichTextEditKeepsMetadataAndLateInitialContentCannotRestoreOldFormats() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x5A, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x5B, time: 2_000)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-rich-edit.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let attributed = NSAttributedString(string: "formatted original")
        let rtf = try attributed.data(from: .init(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let item = NSPasteboardItem()
        item.setString("formatted original", forType: .string)
        item.setData(rtf, forType: .rtf)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let source = ClipboardHistoryCaptureSource(bundleIdentifier: "test.editor", displayName: "Editor")
        guard case .captured(let captured) = try await first.capture(.init(pasteboard: pasteboard), source: source) else {
            return XCTFail("Expected rich text capture")
        }
        let tag = try await first.createTagDefinition(named: "Rich edits", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let initial = try await second.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertTrue(initial.items[0].representations.contains(.data(typeIdentifier: "public.rtf", rtf)))
        let privateTag = try await second.createTagDefinition(named: "Private context", assigningTo: captured.entryID)
        _ = try await second.apply(.setFavorite(captured.entryID, true))

        _ = try await first.apply(.editText(captured.entryID, "edited exact text"))
        await first.retrySync()
        await second.retrySync()
        let expected = ClipboardHistoryMaterialization(items: [.init(representations: [
            .text(typeIdentifier: "public.utf8-plain-text", value: "edited exact text")
        ])])
        let edited = try await second.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertEqual(edited, expected)
        let page = try await second.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertTrue(entry.isFavorite)
        XCTAssertEqual(entry.tagIDs, [tag.definition.id, privateTag.definition.id])
        XCTAssertEqual(entry.source, source)
        XCTAssertEqual(entry.capturedAt, Date(timeIntervalSince1970: 1_000))

        await cloud.replayAllChangesInReverseOrder()
        let late = makeModule(services: services, keyByte: 0x5C, time: 3_000)
        try await late.setSyncEnabled(true)
        await late.retrySync()
        let replayed = try await late.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        XCTAssertEqual(replayed, expected)
        let plan = try await late.textEditPlan(for: captured.entryID)
        XCTAssertFalse(plan.hasConflict)
    }

    func testEditorRetainsItsDisplayedAncestryWhenRemoteTextChangesBeforeSave() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x57, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x58, time: 2_000)
        let captured = try await first.capture(.init(source: .unknown, content: .text("editor basis")))
        let tag = try await first.createTagDefinition(named: "Editor", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let secondPage = try await second.page(.init())
        let remote = try XCTUnwrap(secondPage.entries.first)
        let opened = try await first.textEditPlan(for: captured.entryID)
        _ = try await second.apply(.editText(remote.id, "remote edit"))
        await second.retrySync()
        await first.retrySync()

        let saved = try await first.saveTextEdit("draft from old basis", using: opened)
        guard case .updated(let entry) = saved else { return XCTFail("Expected saved draft") }
        XCTAssertTrue(entry.hasTextConflict)
        let conflict = try await first.textEditPlan(for: captured.entryID)
        XCTAssertEqual(Set(conflict.versions.map(\.text)), ["remote edit", "draft from old basis"])
        let choice = try XCTUnwrap(conflict.versions.first { $0.text == "draft from old basis" })
        _ = try await first.apply(.editText(captured.entryID, "continued draft"))
        do {
            _ = try await first.resolveTextConflict(.init(plan: conflict, versionID: choice.id))
            XCTFail("A stale choice must not discard a newer branch")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryModuleError, .operationUnavailable)
        }
        let refreshed = try await first.textEditPlan(for: captured.entryID)
        XCTAssertEqual(Set(refreshed.versions.map(\.text)), ["remote edit", "continued draft"])
        let currentChoice = try XCTUnwrap(refreshed.versions.first { $0.text == "continued draft" })
        let resolved = try await first.resolveTextConflict(.init(plan: refreshed, versionID: currentChoice.id))
        guard case .updated(let updated) = resolved else { return XCTFail("Expected resolved entry") }
        XCTAssertFalse(updated.hasTextConflict)
    }

    func testUpgradeFromV14PreservesAnEditWhoseInitialCiphertextWasReclaimed() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-v14-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x55, time: 1_000, root: root)
        let second = makeModule(services: services, keyByte: 0x56, time: 2_000)
        let captured = try await first.capture(.init(source: .unknown, content: .text("v14 original")))
        let tag = try await first.createTagDefinition(named: "Upgrade", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        await first.retrySync()
        try await second.setSyncEnabled(true)
        await first.suspendSync()
        _ = try await first.apply(.editText(captured.entryID, "v14 unsent edit"))
        try await first.makeV14SyncFixtureForTesting()
        try await first.closeStoreForTesting()

        let upgraded = makeModule(services: services, keyByte: 0x55, time: 3_000, root: root)
        await upgraded.resumeSync()
        await second.retrySync()
        let local = try await upgraded.textEditPlan(for: captured.entryID)
        let page = try await second.page(.init())
        let remote = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(local.text, "v14 unsent edit")
        XCTAssertEqual(remote.previewText, "v14 unsent edit")
        XCTAssertEqual(local.versions.count, 1)
    }

    func testOfflineTextBranchesSurviveRestartAndExplicitResolutionConverges() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let firstRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sync-branches-A-\(UUID())")
        let secondRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sync-branches-B-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x53, time: 1_000, root: firstRoot)
        let second = makeModule(services: services, keyByte: 0x54, time: 2_000, root: secondRoot)
        let captured = try await first.capture(.init(source: .unknown, content: .text("shared root")))
        let tag = try await first.createTagDefinition(named: "Branches", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let initial = try await second.page(.init())
        let received = try XCTUnwrap(initial.entries.first)
        await first.suspendSync()
        await second.suspendSync()
        _ = try await first.apply(.editText(captured.entryID, "offline A"))
        _ = try await second.apply(.editText(received.id, "offline B"))
        try await first.closeStoreForTesting()
        try await second.closeStoreForTesting()

        let reopenedA = makeModule(services: services, keyByte: 0x53, time: 3_000, root: firstRoot)
        let reopenedB = makeModule(services: services, keyByte: 0x54, time: 4_000, root: secondRoot)
        await reopenedA.resumeSync()
        await reopenedB.resumeSync()
        await reopenedA.retrySync()
        let conflictA = try await reopenedA.textEditPlan(for: captured.entryID)
        let conflictB = try await reopenedB.textEditPlan(for: received.id)
        XCTAssertEqual(Set(conflictA.versions.map(\.text)), ["offline A", "offline B"])
        XCTAssertEqual(Set(conflictB.versions.map(\.text)), ["offline A", "offline B"])
        XCTAssertEqual(conflictA.text, "offline A")
        XCTAssertEqual(conflictB.text, "offline B")
        let choice = try XCTUnwrap(conflictA.versions.first { $0.text == "offline B" })
        _ = try await reopenedA.resolveTextConflict(.init(plan: conflictA, versionID: choice.id))
        await reopenedA.retrySync()
        await reopenedB.retrySync()
        let resolvedA = try await reopenedA.textEditPlan(for: captured.entryID)
        let resolvedB = try await reopenedB.textEditPlan(for: received.id)
        XCTAssertEqual(resolvedA.text, "offline B")
        XCTAssertEqual(resolvedB.text, "offline B")
        XCTAssertFalse(resolvedA.hasConflict)
        XCTAssertFalse(resolvedB.hasConflict)
        try await reopenedB.closeStoreForTesting()
        let finalB = makeModule(services: services, keyByte: 0x54, time: 5_000, root: secondRoot)
        await finalB.resumeSync()
        let afterRestart = try await finalB.textEditPlan(for: received.id)
        XCTAssertEqual(afterRestart.text, "offline B")
        XCTAssertFalse(afterRestart.hasConflict)

        // A newly joining device receives the resolution before either branch
        // and the root. Durable pending versions must still converge; replaying
        // every record again must not restore the resolved conflict.
        await cloud.replayAllChangesInReverseOrder()
        let reordered = makeModule(services: services, keyByte: 0x59, time: 6_000)
        try await reordered.setSyncEnabled(true)
        await reordered.retrySync()
        let reorderedPage = try await reordered.page(.init())
        XCTAssertEqual(reorderedPage.entries.count, 1)
        let reorderedEntry = try XCTUnwrap(reorderedPage.entries.first)
        let reorderedPlan = try await reordered.textEditPlan(for: reorderedEntry.id)
        XCTAssertEqual(reorderedPlan.text, "offline B")
        XCTAssertFalse(reorderedPlan.hasConflict)
    }

    func testSharedTextEditUpdatesExistingEntryWithoutMovingLocalOrder() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x51, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x52, time: 2_000)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-edit-tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("current clipboard", forType: .string)
        let pasteboardGeneration = pasteboard.changeCount
        let captured = try await first.capture(.init(source: .unknown, content: .text("original")))
        let tag = try await first.createTagDefinition(named: "Edits", assigningTo: captured.entryID)
        _ = try await first.apply(.setFavorite(captured.entryID, true))
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let before = try await second.page(.init())
        let received = try XCTUnwrap(before.entries.first)
        let privateTag = try await second.createTagDefinition(named: "Private", assigningTo: received.id)
        _ = try await second.apply(.setFavorite(received.id, false))
        let later = try await second.capture(.init(source: .unknown, content: .text("local newer")))

        _ = try await first.apply(.editText(captured.entryID, "revised"))
        await first.retrySync()
        await second.retrySync()

        let after = try await second.page(.init())
        XCTAssertEqual(after.entries.map(\.id), [later.entryID, received.id])
        let updated = try XCTUnwrap(after.entries.last)
        XCTAssertEqual(updated.previewText, "revised")
        XCTAssertEqual(updated.capturedAt, received.capturedAt)
        XCTAssertEqual(updated.source, received.source)
        XCTAssertFalse(updated.isFavorite)
        XCTAssertEqual(updated.tagIDs, [tag.definition.id, privateTag.definition.id])
        let content = try await second.materialize(.init(entryID: received.id, purpose: .normalPaste))
        XCTAssertEqual(content.items, [.init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: "revised")])])
        XCTAssertEqual(pasteboard.changeCount, pasteboardGeneration)
        XCTAssertEqual(pasteboard.string(forType: .string), "current clipboard")
    }

    @MainActor
    func testStandardColorAndExplicitRecognitionTextKeepTheirRepresentationsAndFacets() async throws {
        let services = ClipboardSyncServices(transport: SyncTestCloud(), keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x85, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x86, time: 2_000)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-color.\(UUID())"))
        pasteboard.clearContents()
        let color = NSColor(displayP3Red: 0.25, green: 0.5, blue: 0.75, alpha: 0.5)
        let bytes = try XCTUnwrap(color.pasteboardPropertyList(forType: .color) as? Data)
        let item = NSPasteboardItem()
        item.setData(bytes, forType: .color)
        item.setString("original color label", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        guard case .captured(let colored) = try await first.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected a captured color")
        }
        let ocr = try await first.capture(.init(source: .unknown, content: .ocr("https://example.com/recognized")))
        let qr = try await first.capture(.init(source: .unknown, content: .qrCode("qr result")))
        let tag = try await first.createTagDefinition(named: "Content", assigningTo: colored.entryID)
        _ = try await first.apply(.setTags(ocr.entryID, [tag.definition.id]))
        _ = try await first.apply(.setTags(qr.entryID, [tag.definition.id]))
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let page = try await second.page(.init())
        XCTAssertEqual(page.entries.count, 3)
        let restoredColor = try XCTUnwrap(page.entries.first { $0.id == colored.entryID })
        XCTAssertEqual(restoredColor.facets, [.text, .color])
        let normal = try await second.materialize(.init(entryID: restoredColor.id, purpose: .normalPaste))
        XCTAssertEqual(normal.items, [.init(representations: [
            .text(typeIdentifier: "public.utf8-plain-text", value: "original color label"),
            .data(typeIdentifier: NSPasteboard.PasteboardType.color.rawValue, bytes),
        ])])
        XCTAssertEqual(page.entries.first { $0.id == ocr.entryID }?.facets, [.text, .ocr])
        XCTAssertEqual(page.entries.first { $0.id == qr.entryID }?.facets, [.text, .qrCode])
        let ocrSearch = try await second.page(.init(text: "recognized", facet: .ocr))
        XCTAssertEqual(ocrSearch.entries.map(\.id), [ocr.entryID])
    }

    @MainActor
    func testScreenshotTransfersOwnedPixelsAndThumbnailWithoutStartingReceiverRecognition() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x83, time: 1_000)
        let receiverRecognizer = SyncTestRecognizer()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-owned-image-\(UUID())")
        let second = makeModule(services: services, keyByte: 0x84, time: 2_000, root: root, recognizer: receiverRecognizer)
        let bitmap = try makeSyncBitmap()
        let captured = try await first.capture(.init(source: .init(bundleIdentifier: "test.capture", displayName: "Capture"),
            content: .bitmap(bitmap, provenance: .anyDoorScreenshot)))
        await first.awaitDerivedJobsForTesting()
        _ = try await first.apply(.setFavorite(captured.entryID, true))
        let tag = try await first.createTagDefinition(named: "Screenshots", assigningTo: captured.entryID)
        let original = try await first.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
        let preview = try await first.materialize(.init(entryID: captured.entryID, purpose: .preview))
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        await second.awaitDerivedJobsForTesting()
        let page = try await second.page(.init(facet: .screenshot))
        let received = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(received.facets, [.image, .screenshot])
        XCTAssertTrue(received.isFavorite)
        XCTAssertEqual(received.capturedAt, Date(timeIntervalSince1970: 1_000))
        let full = try await second.materialize(.init(entryID: received.id, purpose: .normalPaste))
        let thumbnail = try await second.materialize(.init(entryID: received.id, purpose: .preview))
        XCTAssertEqual(full, original)
        XCTAssertEqual(thumbnail, preview)
        let recognitionCalls = await receiverRecognizer.callCount()
        XCTAssertEqual(recognitionCalls, 0)
        let payloads = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("payloads"), includingPropertiesForKeys: nil)
        XCTAssertEqual(payloads.count, 2)
        for file in payloads {
            XCTAssertNil(try Data(contentsOf: file).range(of: bitmap))
        }
    }

    @MainActor
    func testSelectedOrdinaryFileArrivesAsUsableHistoryWithoutChangingPasteboard() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x71, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x72, time: 2_000)
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sync-file-source-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(sourceRoot)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let original = sourceRoot.appendingPathComponent("Private notes.txt")
        let expected = Data("a complete ordinary file\n".utf8)
        try expected.write(to: original)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-file-tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString(original.absoluteString, forType: .fileURL)
        let source = ClipboardHistoryCaptureSource(bundleIdentifier: "com.apple.finder", displayName: "Finder")
        let outcome = try await first.capture(.init(pasteboard: pasteboard), source: source)
        guard case .captured(let captured) = outcome else {
            return XCTFail("Expected the original file reference to be captured")
        }
        let tag = try await first.createTagDefinition(named: "Shared files", assigningTo: captured.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        let senderStatus = await first.syncStatus()
        XCTAssertEqual(senderStatus.phase, .upToDate)
        pasteboard.clearContents()
        pasteboard.setString("leave the current clipboard alone", forType: .string)
        let generation = pasteboard.changeCount

        try await second.setSyncEnabled(true)

        let receiverStatus = await second.syncStatus()
        XCTAssertEqual(receiverStatus.phase, .upToDate)

        let page = try await second.page(.init(tagID: tag.definition.id))
        let received = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(received.capturedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(received.source, source)
        XCTAssertTrue(received.facets.contains(.file))
        let materialized = try await second.materialize(.init(entryID: received.id, purpose: .normalPaste))
        guard materialized.items.count == 1,
              case .file(let file) = materialized.items[0].representations.first else {
            return XCTFail("Expected one complete working-file representation")
        }
        XCTAssertEqual(file.displayName, "Private notes.txt")
        XCTAssertNotEqual(file.currentURL, original)
        XCTAssertEqual(try Data(contentsOf: file.currentURL), expected)
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.string(forType: .string), "leave the current clipboard alone")
    }

    @MainActor
    func testOrderedRichTextAndLinkRepresentationsTransferAsOneCompleteEntry() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x81, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x82, time: 2_000)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-rich.\(UUID())"))
        pasteboard.clearContents()
        let rich = NSPasteboardItem()
        let rtf = Data(#"{\rtf1\ansi Shared rich words}"#.utf8)
        let html = Data("<p>Shared rich words</p>".utf8)
        rich.setString(" Shared exact words\r\n", forType: .string)
        rich.setData(rtf, forType: .rtf)
        rich.setData(html, forType: .html)
        let link = NSPasteboardItem()
        link.setString("Example link", forType: .string)
        link.setString("https://example.com/shared", forType: .URL)
        XCTAssertTrue(pasteboard.writeObjects([rich, link]))
        let captured = try await first.capture(.init(pasteboard: pasteboard), source: .unknown)
        guard case .captured(let outcome) = captured else { return XCTFail("Expected a complete captured entry") }
        let tag = try await first.createTagDefinition(named: "Rich", assigningTo: outcome.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        pasteboard.clearContents()
        pasteboard.setString("receiver sentinel", forType: .string)
        let generation = pasteboard.changeCount
        try await second.setSyncEnabled(true)
        let page = try await second.page(.init(tagID: tag.definition.id))
        let received = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(page.entries.count, 1)
        let normal = try await second.materialize(.init(entryID: received.id, purpose: .normalPaste))
        XCTAssertEqual(normal.items, [
            .init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: " Shared exact words\r\n"),
                .data(typeIdentifier: "public.rtf", rtf), .data(typeIdentifier: "public.html", html)]),
            .init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: "Example link"),
                .text(typeIdentifier: "public.url", value: "https://example.com/shared")]),
        ])
        let plain = try await second.materialize(.init(entryID: received.id, purpose: .plainTextPaste))
        XCTAssertEqual(plain.items.count, 2)
        let search = try await second.page(.init(text: "Shared rich words"))
        XCTAssertEqual(search.entries.map(\.id), [received.id])
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.string(forType: .string), "receiver sentinel")
    }

    func testConcurrentMembershipRemovalsStartANewLocalRetentionWindow() async throws {
        let services = ClipboardSyncServices(transport: SyncTestCloud(), keys: SyncTestKeys(), pollingInterval: nil)
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let first = makeModule(services: services, keyByte: 0x69, time: 1_000, clock: { clock.withLock { $0 } })
        let second = makeModule(services: services, keyByte: 0x6a, time: 1_000, clock: { clock.withLock { $0 } })
        let entry = try await first.capture(.init(source: .unknown, content: .text("old protected history")))
        let work = try await first.createTagDefinition(named: "Work", assigningTo: entry.entryID).definition
        let other = try await first.createTagDefinition(named: "Other", assigningTo: entry.entryID).definition
        try await first.setSyncTagSelected(work.id, selected: true)
        try await first.setSyncTagSelected(other.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        clock.withLock { $0 = $0.addingTimeInterval(100 * 86_400) }
        _ = try await first.apply(.setTags(entry.entryID, [work.id]))
        _ = try await second.apply(.setTags(entry.entryID, [other.id]))
        await first.retrySync()
        await second.retrySync()
        await first.retrySync()
        let firstPage = try await first.page(.init()).entries
        let secondPage = try await second.page(.init()).entries
        XCTAssertEqual(firstPage.map(\.id), [entry.entryID])
        XCTAssertEqual(secondPage.map(\.id), [entry.entryID])
        XCTAssertEqual(secondPage.first?.capturedAt, Date(timeIntervalSince1970: 1_000))
    }

    @MainActor
    func testRemoteMergeCannotStageFileBodiesFromAnotherAccount() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x66, time: 1_000)
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sync-account-file-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(sourceRoot)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("Private.txt")
        try Data("previous account private file".utf8).write(to: source)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-account-file.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(source.absoluteString, forType: .fileURL)
        guard case .captured(let secret) = try await first.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected an original file")
        }
        let oldTag = ClipboardHistoryTagDefinition(id: "z-old-account", displayName: "Work")
        let currentTag = ClipboardHistoryTagDefinition(id: "a-current-account", displayName: "Work")
        _ = try await first.replaceTagDefinitions(with: [oldTag])
        _ = try await first.apply(.setTags(secret.entryID, [oldTag.id]))
        try await first.setSyncTagSelected(oldTag.id, selected: true)
        try await first.setSyncEnabled(true)
        await cloud.switchAccount(to: "account-B")
        await first.retrySync()
        let peer = makeModule(services: services, keyByte: 0x68, time: 2_000)
        _ = try await peer.replaceTagDefinitions(with: [oldTag, currentTag])
        try await peer.setSyncTagSelected(currentTag.id, selected: true)
        try await peer.setSyncEnabled(true)
        try await first.setSyncEnabled(true)
        try await first.setSyncTagSelected(currentTag.id, selected: true)
        let preview = try await peer.prepareSyncTagMerge(sourceID: oldTag.id, targetID: currentTag.id)
        try await peer.mergeSyncTags(preview)
        await first.retrySync()
        let afterRemoteMerge = await cloud.currentUploads()
        XCTAssertEqual(afterRemoteMerge.filter { $0.record.kind == .entry }.count, 0)
        XCTAssertEqual(afterRemoteMerge.filter { $0.record.kind == .fileBody }.count, 0)
        let choicesAfterRemoteMerge = try await first.syncTags()
        XCTAssertTrue(try XCTUnwrap(choicesAfterRemoteMerge.first { $0.id == currentTag.id }).requiresLocalAuthorization)
        let local = try await first.page(.init()).entries
        XCTAssertEqual(local.map(\.id), [secret.entryID])
        let extra = ClipboardHistoryTagDefinition(id: "another-current-tag", displayName: "Work")
        _ = try await first.replaceTagDefinitions(with: [currentTag, extra])
        let localMerge = try await first.prepareSyncTagMerge(sourceID: currentTag.id, targetID: extra.id)
        XCTAssertEqual(localMerge.newlyEligibleEntryCount, 1,
            "A selected but account-blocked retained entry is newly enrolled by explicit local merge")
        try await first.setSyncTagSelected(currentTag.id, selected: true)
        let afterExplicitConsent = await cloud.currentUploads()
        XCTAssertEqual(afterExplicitConsent.filter { $0.record.kind == .entry }.count, 1)
        XCTAssertEqual(afterExplicitConsent.filter { $0.record.kind == .fileBody }.count, 1)
        let choicesAfterConsent = try await first.syncTags()
        XCTAssertFalse(try XCTUnwrap(choicesAfterConsent.first { $0.id == currentTag.id }).requiresLocalAuthorization)
    }

    func testRemoteMergeCannotAuthorizeHistoryFromAnotherAccount() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x66, time: 1_000)
        let secret = try await first.capture(.init(source: .unknown, content: .text("previous account history")))
        let oldTag = ClipboardHistoryTagDefinition(id: "z-old-account", displayName: "Work")
        let currentTag = ClipboardHistoryTagDefinition(id: "a-current-account", displayName: "Work")
        _ = try await first.replaceTagDefinitions(with: [oldTag])
        _ = try await first.apply(.setTags(secret.entryID, [oldTag.id]))
        try await first.setSyncTagSelected(oldTag.id, selected: true)
        try await first.setSyncEnabled(true)
        await cloud.switchAccount(to: "account-B")
        await first.retrySync()
        let peer = makeModule(services: services, keyByte: 0x68, time: 2_000)
        _ = try await peer.replaceTagDefinitions(with: [oldTag, currentTag])
        try await peer.setSyncTagSelected(currentTag.id, selected: true)
        try await peer.setSyncEnabled(true)
        try await first.setSyncEnabled(true)
        try await first.setSyncTagSelected(currentTag.id, selected: true)
        let preview = try await peer.prepareSyncTagMerge(sourceID: oldTag.id, targetID: currentTag.id)
        try await peer.mergeSyncTags(preview)
        await first.retrySync()
        let afterRemoteMerge = await cloud.currentUploads()
        XCTAssertEqual(afterRemoteMerge.filter { $0.record.kind == .entry }.count, 0)
        let choicesAfterRemoteMerge = try await first.syncTags()
        XCTAssertTrue(try XCTUnwrap(choicesAfterRemoteMerge.first { $0.id == currentTag.id }).requiresLocalAuthorization)
        let local = try await first.page(.init()).entries
        XCTAssertEqual(local.map(\.id), [secret.entryID])
        try await first.setSyncTagSelected(currentTag.id, selected: true)
        let afterExplicitConsent = await cloud.currentUploads()
        XCTAssertEqual(afterExplicitConsent.filter { $0.record.kind == .entry }.count, 1)
        let choicesAfterConsent = try await first.syncTags()
        XCTAssertFalse(try XCTUnwrap(choicesAfterConsent.first { $0.id == currentTag.id }).requiresLocalAuthorization)
    }

    func testOverlappingTagCanBeDeselectedAcrossDevicesWithoutWithdrawingEntry() async throws {
        let services = ClipboardSyncServices(transport: SyncTestCloud(), keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x64, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x65, time: 2_000)
        let entry = try await first.capture(.init(source: .unknown, content: .text("still shared")))
        let work = try await first.createTagDefinition(named: "Work", assigningTo: entry.entryID).definition
        let other = try await first.createTagDefinition(named: "Other", assigningTo: entry.entryID).definition
        try await first.setSyncTagSelected(work.id, selected: true)
        try await first.setSyncTagSelected(other.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        try await first.setSyncTagSelected(work.id, selected: false)
        await second.retrySync()
        let tags = try await second.syncTags()
        XCTAssertEqual(Set(tags.filter(\.isSelected).map(\.id)), [other.id])
        let entries = try await second.page(.init()).entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.tagIDs, [work.id, other.id])
        try await first.setSyncTagSelected(work.id, selected: true)
        await second.retrySync()
        let reselected = try await second.syncTags()
        XCTAssertEqual(Set(reselected.filter(\.isSelected).map(\.id)), [work.id, other.id])
    }

    func testExplicitMergeDisclosesEnrollmentAndSurvivesOldSnapshotReplay() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x61, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x62, time: 2_000)
        let source = try await first.capture(.init(source: .unknown, content: .text("shared before merge")))
        let local = try await second.capture(.init(source: .unknown, content: .text("enrolled by explicit merge")))
        let sharedTag = try await first.createTagDefinition(named: "Work", assigningTo: source.entryID).definition
        let localTag = try await second.createTagDefinition(named: "Work", assigningTo: local.entryID).definition
        try await first.setSyncTagSelected(sharedTag.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let preview = try await second.prepareSyncTagMerge(sourceID: localTag.id, targetID: sharedTag.id)
        XCTAssertEqual(preview.newlyEligibleEntryCount, 1)
        let beforeConfirmation = try await first.page(.init()).entries
        XCTAssertEqual(beforeConfirmation.count, 1)
        _ = try await second.capture(.init(source: .unknown, content: .text("changes invalidate consent preview")))
        do {
            try await second.mergeSyncTags(preview)
            XCTFail("Changed history must require a fresh enrollment preview")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryModuleError, .invalidConfirmation)
        }
        let current = try await second.prepareSyncTagMerge(sourceID: localTag.id, targetID: sharedTag.id)
        try await second.mergeSyncTags(current)
        await first.retrySync()
        let merged = try await first.page(.init()).entries
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.allSatisfy { $0.tagIDs == [current.canonicalTagID] })
        await cloud.reverseDelivery()
        let third = makeModule(services: services, keyByte: 0x63, time: 3_000)
        try await third.setSyncEnabled(true)
        let replayedTags = try await third.syncTags()
        let replayed = try await third.page(.init()).entries
        XCTAssertEqual(replayedTags.map(\.id), [current.canonicalTagID])
        XCTAssertEqual(replayed.count, 2)
        XCTAssertTrue(replayed.allSatisfy { $0.tagIDs == [current.canonicalTagID] })
    }

    func testSameNameTagsStayIndependentAndNameOnlyAssignmentIsRejected() async throws {
        let services = ClipboardSyncServices(transport: SyncTestCloud(), keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x78, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x79, time: 2_000)
        let firstEntry = try await first.capture(.init(source: .unknown, content: .text("first collection")))
        let secondEntry = try await second.capture(.init(source: .unknown, content: .text("unselected local collection")))
        let firstTag = try await first.createTagDefinition(named: "Work", assigningTo: firstEntry.entryID).definition
        let secondTag = try await second.createTagDefinition(named: "Work", assigningTo: secondEntry.entryID).definition
        XCTAssertNotEqual(firstTag.id, secondTag.id)
        try await first.setSyncTagSelected(firstTag.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let tags = try await second.syncTags()
        XCTAssertEqual(Set(tags.map(\.id)), [firstTag.id, secondTag.id])
        XCTAssertFalse(try XCTUnwrap(tags.first { $0.id == secondTag.id }).isSelected)
        let unselected = try await first.page(.init()).entries
        XCTAssertEqual(unselected.count, 1)
        let fresh = try await second.capture(.init(source: .unknown, content: .text("explicit identity required")))
        do {
            _ = try await second.createTagDefinition(named: "Work", assigningTo: fresh.entryID)
            XCTFail("A name collision must require an identity choice")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryModuleError, .duplicateTagName)
        }
        let freshEntry = try await second.page(.init()).entries.first { $0.id == fresh.entryID }
        XCTAssertEqual(freshEntry?.tagIDs, [])
        try await second.setSyncTagSelected(secondTag.id, selected: true)
        await first.retrySync()
        let independentlySelected = try await first.page(.init()).entries
        XCTAssertEqual(independentlySelected.count, 2)
        XCTAssertEqual(independentlySelected.first { $0.id == secondEntry.entryID }?.tagIDs, [secondTag.id])
    }

    func testIndependentTagRenamesConvergeAcrossReversedDeliveryAndRestart() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-tags-\(UUID())")
        let first = makeModule(services: services, keyByte: 0x75, time: 1_000, root: root)
        let second = makeModule(services: services, keyByte: 0x76, time: 2_000)
        let entry = try await first.capture(.init(source: .unknown, content: .text("renamed collections")))
        let work = try await first.createTagDefinition(named: "Work", assigningTo: entry.entryID).definition
        let other = try await first.createTagDefinition(named: "Other", assigningTo: entry.entryID).definition
        try await first.setSyncTagSelected(work.id, selected: true)
        try await first.setSyncTagSelected(other.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        try await first.setSyncEnabled(false)
        try await second.setSyncEnabled(false)
        _ = try await first.renameTagDefinition(id: work.id, to: "Focused work")
        _ = try await second.renameTagDefinition(id: other.id, to: "Research")
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        await first.retrySync()
        let expected = [work.id: "Focused work", other.id: "Research"]
        let firstTags = try await first.syncTags()
        let secondTags = try await second.syncTags()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: firstTags.map { ($0.id, $0.displayName) }), expected)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: secondTags.map { ($0.id, $0.displayName) }), expected)
        await cloud.reverseDelivery()
        let third = makeModule(services: services, keyByte: 0x77, time: 3_000)
        try await third.setSyncEnabled(true)
        let reversedTags = try await third.syncTags()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: reversedTags.map { ($0.id, $0.displayName) }), expected)
        let reversedEntries = try await third.page(.init()).entries
        XCTAssertEqual(reversedEntries.first?.tagIDs, [work.id, other.id])
        try await first.closeStoreForTesting()
        let reopened = makeModule(services: services, keyByte: 0x75, time: 4_000, root: root)
        await reopened.resumeSync()
        let reopenedTags = try await reopened.syncTags()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: reopenedTags.map { ($0.id, $0.displayName) }), expected)
    }

    func testSelectedMembershipChangesPreservePrivateTagsOnBothDevices() async throws {
        let cloud = SyncTestCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x73, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x74, time: 2_000)
        let entry = try await first.capture(.init(source: .unknown, content: .text("shared organization")))
        let work = try await first.createTagDefinition(named: "Work", assigningTo: entry.entryID).definition
        let other = try await first.createTagDefinition(named: "Other", assigningTo: entry.entryID).definition
        try await first.setSyncTagSelected(work.id, selected: true)
        try await first.setSyncTagSelected(other.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let personal = try await second.createTagDefinition(named: "Private on receiver", assigningTo: entry.entryID).definition
        _ = try await first.apply(.setTags(entry.entryID, [other.id]))
        await first.retrySync()
        await second.retrySync()
        let removed = try await second.page(.init()).entries
        XCTAssertEqual(removed.first?.tagIDs, [other.id, personal.id])
        _ = try await second.apply(.setTags(entry.entryID, [work.id, other.id, personal.id]))
        await second.retrySync()
        await first.retrySync()
        let restored = try await first.page(.init()).entries
        XCTAssertEqual(restored.first?.tagIDs, [work.id, other.id])
        let firstDefinitions = try await first.tagDefinitions()
        XCTAssertFalse(firstDefinitions.contains { $0.id == personal.id })
        let countBeforeReplay = await cloud.currentUploads().count
        await first.retrySync()
        await second.retrySync()
        let countAfterReplay = await cloud.currentUploads().count
        XCTAssertEqual(countAfterReplay, countBeforeReplay)
    }

    func testMultipleSelectedTagsBackfillTheirUnionWithoutPrivateLabels() async throws {
        let services = ClipboardSyncServices(transport: SyncTestCloud(), keys: SyncTestKeys(), pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x71, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x72, time: 2_000)
        let workEntry = try await first.capture(.init(source: .unknown, content: .text("work history")))
        let otherEntry = try await first.capture(.init(source: .unknown, content: .text("other history")))
        let work = try await first.createTagDefinition(named: "Work", assigningTo: workEntry.entryID).definition
        let other = try await first.createTagDefinition(named: "Other", assigningTo: otherEntry.entryID).definition
        let personal = try await first.createTagDefinition(named: "Personal", assigningTo: workEntry.entryID).definition
        _ = try await first.apply(.setTags(workEntry.entryID, [work.id, other.id, personal.id]))
        try await first.setSyncTagSelected(work.id, selected: true)
        try await first.setSyncTagSelected(other.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        let choices = try await second.syncTags()
        XCTAssertEqual(Set(choices.filter(\.isSelected).map(\.id)), [work.id, other.id])
        XCTAssertFalse(choices.contains { $0.id == personal.id })
        let entries = try await second.page(.init()).entries
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first { $0.id == workEntry.entryID }?.tagIDs, [work.id, other.id])
        await first.retrySync()
        await second.retrySync()
        let replayed = try await second.page(.init()).entries
        XCTAssertEqual(replayed.count, 2)
    }

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
            if lostPhase == "stopped" { XCTAssertGreaterThan(failed.cloudReset?.deletedRecordCount ?? 0, 0) }
            try await first.closeStoreForTesting()
            let reopened = makeModule(services: services, keyByte: 0x23, time: 2_000, root: root)
            await reopened.resumeSync()
            let completed = await reopened.syncStatus()
            XCTAssertEqual(completed.cloudReset?.stage, .completed)
            XCTAssertGreaterThanOrEqual(completed.cloudReset?.deletedRecordCount ?? 0, failed.cloudReset?.deletedRecordCount ?? 0)
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

    private static func publishFixture(_ content: ClipboardSyncContent, operationID: UUID = UUID(),
                                cloud: SyncTestCloud, keys: SyncTestKeys) async throws {
        let account = try await cloud.account()
        let descriptor = try await cloud.control(for: account)
        let control = try XCTUnwrap(descriptor)
        let loaded = await keys.load(account: account, keyID: control.keyID)
        let key = try XCTUnwrap(loaded)
        let upload = try ClipboardSyncCodec.seal(content, account: account, control: control, key: key, operationID: operationID)
        _ = try await cloud.commit(upload, for: account, control: control)
    }

    private func makeModule(
        services: ClipboardSyncServices, keyByte: UInt8, time: TimeInterval,
        root: URL? = nil, clock: (@Sendable () -> Date)? = nil,
        faults: ClipboardHistoryFaultInjector = .init(),
        workingRoot: URL? = nil,
        recognizer: any ClipboardHistoryVisionRecognizing = SyncTestRecognizer()
    ) -> ClipboardHistoryModule {
        let root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-sync-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        return trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: root,
            keyStore: SyncTestLocalKeyStore(byte: keyByte),
            faultInjector: faults,
            now: clock ?? { Date(timeIntervalSince1970: time) },
            visionRecognizer: recognizer,
            syncServices: services,
            testingSyncWorkingRoot: workingRoot
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

    @MainActor
    private func makeSyncBitmap(color: NSColor = NSColor(deviceRed: 1, green: 0.4, blue: 0.1, alpha: 1)) throws -> Data {
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<16 { for x in 0..<32 { image.setColor(color, atX: x, y: y) } }
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }
}

private actor SyncTestRecognizer: ClipboardHistoryVisionRecognizing {
    private var calls = 0
    let results: [ClipboardHistoryDerivedJobKind: [String]]
    private var held: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(results: [ClipboardHistoryDerivedJobKind: [String]] = [:], held: Bool = false) {
        self.results = results
        self.held = held
    }
    func recognize(_ kind: ClipboardHistoryDerivedJobKind, in bitmaps: [Data]) async -> [String] {
        calls += 1
        if held { await withCheckedContinuation { waiters.append($0) } }
        return results[kind] ?? []
    }
    func release() {
        held = false
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
    func callCount() -> Int { calls }
}

private extension ClipboardHistoryModule {
    /// Constructs the on-disk v14 fixture after real capture/edit operations.
    /// Assertions use the public module interface after the normal upgrade.
    func makeV14SyncFixtureForTesting() async throws {
        let pool = try await writableDatabase()
        try await pool.write { database in
            try database.execute(sql: "DROP TABLE clipboard_sync_version_selections")
            try database.execute(sql: "DROP TABLE clipboard_sync_versions")
            try database.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v18_clipboard_sync_versions'")
        }
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
    private var uploadFailureIndex: Int?
    private var uploadAttempts: [UUID] = []
    func failFileUploadOnce(after index: Int) { uploadFailureIndex = index }
    func fileUploadAttempts() -> [UUID] { uploadAttempts }
    private var failedFileSegment: Int?
    private var fileSegmentFailure: ClipboardSyncServiceError = .network(retryAfter: nil)
    private var shouldHoldFileSegment = false
    private var heldFileSegment: CheckedContinuation<Void, Never>?
    private var fileSegmentObserver: CheckedContinuation<Void, Never>?
    func holdNextFileSegment() { shouldHoldFileSegment = true }
    func waitForHeldFileSegment() async {
        if heldFileSegment == nil { await withCheckedContinuation { fileSegmentObserver = $0 } }
    }
    private var fileSegmentRequests: [Int] = []
    private let fileStorage = FileManager.default.temporaryDirectory.appendingPathComponent("sync-cloud-segments-\(UUID())")
    private var maximumFileSegment = 0
    deinit { try? FileManager.default.removeItem(at: fileStorage) }
    func largestFileSegment() -> Int { maximumFileSegment }
    func failFileSegmentOnce(at index: Int, with failure: ClipboardSyncServiceError = .network(retryAfter: nil)) {
        failedFileSegment = index
        fileSegmentFailure = failure
    }
    func requestedFileSegments() -> [Int] { fileSegmentRequests }
    private var currentAccount = ClipboardSyncAccount(container: "test", environment: "test", owner: "test-user")
    private var descriptors: [String: ClipboardSyncControl] = [:]
    private var records: [String: [ClipboardSyncUpload]] = [:]
    private var losesPurgeResponse = false
    private var purgedRecords = Set<String>()
    private var revision = 0
    private var changeCursors: [Data?] = []
    func clearObservedChangeCursors() { changeCursors.removeAll() }
    func observedChangeCursors() -> [Data?] { changeCursors }
    private var holdsPurge = false
    private var heldPurge: CheckedContinuation<Void, Never>?
    private var purgeObserver: CheckedContinuation<Void, Never>?
    private var holdsEntryCommit = false
    private var heldEntryCommit: CheckedContinuation<Void, Never>?
    private var entryCommitObserver: CheckedContinuation<Void, Never>?
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
    private var damagesFileBody = false
    private var persistentDamagedBody: String?
    private var damagesNextBodyPersistently = false
    private var fileBodyDownloads = 0
    func damageNextFileBodyDownload() { damagesFileBody = true }
    func persistentlyDamageNextFileBody() { damagesNextBodyPersistently = true }
    func repairFileBodies() { persistentDamagedBody = nil; damagesNextBodyPersistently = false }
    func fileBodyDownloadCount() -> Int { fileBodyDownloads }
    private var reversesAllChanges = false
    private var reversesDelivery = false
    func reverseDelivery() { reversesDelivery = true }
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
        changeCursors.append(cursor)
        try checkAccount(account)
        let offset = cursor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let uploads = records[account.identifier] ?? []
        let page = (reversesAllChanges ? uploads.reversed().map(\.record) : uploads.dropFirst(offset).map(\.record)).filter { !purgedRecords.contains($0.recordID) }
        return ClipboardSyncChanges(records: reversesDelivery ? Array(page.reversed()) : page,
            cursor: Data(String(uploads.count).utf8), hasMore: false)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) throws -> [Data] {
        try checkAccount(account)
        if record.kind == .fileBody { fileBodyDownloads += 1 }
        if record.kind == .fileBody, damagesNextBodyPersistently {
            damagesNextBodyPersistently = false
            persistentDamagedBody = record.recordID
        }
        guard let upload = records[account.identifier]?.first(where: { $0.record == record }) else {
            throw ClipboardSyncServiceError.missingRemoteState
        }
        if damagesDownload || (damagesFileBody && record.kind == .fileBody) || persistentDamagedBody == record.recordID {
            damagesDownload = false
            if record.kind == .fileBody { damagesFileBody = false }
            var changed = upload.chunks
            changed[0][0] ^= 1
            return changed
        }
        return upload.chunks
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount,
                control: ClipboardSyncControl) async throws -> ClipboardSyncControl {
        if holdsEntryCommit, upload.record.kind == .entry {
            holdsEntryCommit = false
            await withCheckedContinuation {
                heldEntryCommit = $0
                entryCommitObserver?.resume()
                entryCommitObserver = nil
            }
        }
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
    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount,
        control: ClipboardSyncControl, progress: @Sendable (Int64) async throws -> Void) async throws -> ClipboardSyncControl {
        uploadAttempts.append(upload.record.operationID)
        try await progress(0)
        var bytes: Int64 = 0
        let destination = fileStorage.appendingPathComponent(upload.record.recordID)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for index in 0..<upload.record.chunkCount {
            let chunk = try ClipboardSyncFileTransfer.readSegment(in: upload.directory, index: index)
            maximumFileSegment = max(maximumFileSegment, chunk.count)
            try chunk.write(to: destination.appendingPathComponent("\(index).ciphertext"), options: .atomic)
            bytes += Int64(chunk.count)
            try await progress(bytes)
            if uploadFailureIndex == index {
                uploadFailureIndex = nil
                throw ClipboardSyncServiceError.network(retryAfter: nil)
            }
        }
        return try await commit(.init(record: upload.record, chunks: []), for: account, control: control)
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) async throws -> Data {
        if shouldHoldFileSegment {
            shouldHoldFileSegment = false
            await withCheckedContinuation {
                heldFileSegment = $0
                fileSegmentObserver?.resume()
                fileSegmentObserver = nil
            }
        }
        fileSegmentRequests.append(index)
        if failedFileSegment == index {
            failedFileSegment = nil
            throw fileSegmentFailure
        }
        try checkAccount(account)
        fileBodyDownloads += 1
        guard records[account.identifier]?.contains(where: { $0.record == record }) == true else {
            throw ClipboardSyncServiceError.missingRemoteState
        }
        var bytes = try ClipboardSyncFileTransfer.readSegment(in: fileStorage.appendingPathComponent(record.recordID), index: index)
        maximumFileSegment = max(maximumFileSegment, bytes.count)
        if damagesFileBody { damagesFileBody = false; bytes[0] ^= 1 }
        return bytes
    }
    func loseNextPurgeResponse() { losesPurgeResponse = true }
    func holdNextPurge() { holdsPurge = true }
    func waitForHeldPurge() async {
        guard heldPurge == nil else { return }
        await withCheckedContinuation { purgeObserver = $0 }
    }
    func releasePurge() { heldPurge?.resume(); heldPurge = nil }
    func purge(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount,
               control: ClipboardSyncControl) async throws -> ClipboardSyncControl {
        if holdsPurge {
            holdsPurge = false
            await withCheckedContinuation {
                heldPurge = $0
                purgeObserver?.resume()
                purgeObserver = nil
            }
        }
        try checkAccount(account)
        guard let current = descriptors[account.identifier], current == control else { throw ClipboardSyncServiceError.conflict }
        guard current.phase == "active", current.epoch == record.epoch, current.keyID == record.keyID else {
            throw ClipboardSyncServiceError.missingRemoteState
        }
        purgedRecords.insert(record.recordID)
        let result = advanced(current)
        descriptors[account.identifier] = result
        if losesPurgeResponse { losesPurgeResponse = false; throw ClipboardSyncServiceError.network(retryAfter: nil) }
        return result
    }
    func holdNextEntryCommit() { holdsEntryCommit = true }
    func waitForHeldEntryCommit() async {
        guard heldEntryCommit == nil else { return }
        await withCheckedContinuation { entryCommitObserver = $0 }
    }
    func releaseEntryCommit() { heldEntryCommit?.resume(); heldEntryCommit = nil }
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
        heldFileSegment?.resume()
        heldFileSegment = nil
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
    func publishedUploads() -> [ClipboardSyncUpload] { records[currentAccount.identifier] ?? [] }
    func currentUploads() -> [ClipboardSyncUpload] { (records[currentAccount.identifier] ?? []).filter { !purgedRecords.contains($0.record.recordID) } }
    func loseNextEntryCommitResponse() { losesEntryResponse = true }
    func damageNextDownload() { damagesDownload = true }
    func replayAllChangesInReverseOrder() { reversesAllChanges = true }
    func redeliverPurgedRecord(_ id: String) { purgedRecords.remove(id); reversesAllChanges = true }
    func redeliverPurgedContent() { purgedRecords.removeAll(); reversesAllChanges = true }
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
