import AppKit
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testFileTransferCleanupCannotFollowParentReplacedBySymlink() async throws {
        let barrier = LinkedReplacementBarrier()
        let bytes = Data(repeating: 0x32, count: 20_000_000)
        let fixture = try await makeLinkedFixture(receiverFault: .init(shouldFail: { point in
            if point == .syncFileCleanupBeforeRemoval { barrier.pause() }
            return false
        }), initialBytes: bytes)
        let downloads = fixture.receiverRoot.appendingPathComponent("SyncTransfers/Downloads")
        let outside = fixture.root.appendingPathComponent("Independent documents")
        try FileManager.default.copyItem(at: downloads, to: outside)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: outside, includingPropertiesForKeys: nil))
        let external = try XCTUnwrap(enumerator.allObjects.compactMap { $0 as? URL }.first { $0.pathExtension == "ciphertext" })
        let contents = try Data(contentsOf: external)
        _ = try await fixture.sender.apply(.delete(fixture.entryID))
        await fixture.sender.retrySync()
        let deletion = Task { await fixture.receiver.retrySync() }
        try await eventually { barrier.isWaiting }
        try FileManager.default.moveItem(at: downloads, to: fixture.receiverRoot.appendingPathComponent("Retained transfer directory"))
        try FileManager.default.createSymbolicLink(at: downloads, withDestinationURL: outside)
        barrier.release()
        await deletion.value

        XCTAssertEqual(try Data(contentsOf: external), contents, "Cleanup must use the opened owned directory, not a later parent symlink")
        XCTAssertEqual(try Data(contentsOf: fixture.original), bytes)
    }

    @MainActor
    func testDirectoryDeletionPreservesCompleteOfflineTreeAsIndependentCopy() async throws {
        let fixture = try await makeLinkedFixture(prepareSource: { url in
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Empty"), withIntermediateDirectories: true)
            try Data("initial member".utf8).write(to: url.appendingPathComponent("notes.txt"))
            try FileManager.default.createSymbolicLink(atPath: url.appendingPathComponent("Relative link").path, withDestinationPath: "notes.txt")
        })
        let page = try await fixture.receiver.page(.init())
        let working = try XCTUnwrap(page.entries.first?.linkedFileLocations.first)
        try await fixture.receiver.setSyncEnabled(false)
        let saved = Data("offline directory member update".utf8)
        try saved.write(to: working.url.appendingPathComponent("notes.txt"))
        _ = try await fixture.sender.apply(.delete(fixture.entryID))
        await fixture.sender.retrySync()
        try await fixture.receiver.setSyncEnabled(true)

        let notices = try await fixture.receiver.preservedSyncEdits()

        XCTAssertEqual(notices.count, 1)
        let value = try await fixture.receiver.materialize(.init(entryID: XCTUnwrap(notices.first).id, purpose: .normalPaste))
        guard case .file(let file) = value.items.first?.representations.first else { return XCTFail("Missing independent tree") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL.appendingPathComponent("notes.txt")), saved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.currentURL.appendingPathComponent("Empty").path), [])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.currentURL.appendingPathComponent("Relative link").path), "notes.txt")
        XCTAssertNotEqual(file.currentURL, working.url)
        XCTAssertEqual(try Data(contentsOf: fixture.original.appendingPathComponent("notes.txt")), Data("initial member".utf8))
    }

    @MainActor
    func testFileDeletionRetriesPreservationWhenLocalAccessReturns() async throws {
        let fixture = try await makeLinkedFixture()
        let page = try await fixture.receiver.page(.init())
        let working = try XCTUnwrap(page.entries.first?.linkedFileLocations.first)
        try await fixture.receiver.setSyncEnabled(false)
        let saved = Data("saved work temporarily unavailable during remote deletion".utf8)
        try saved.write(to: working.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: working.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: working.url.path) }
        _ = try await fixture.sender.apply(.delete(fixture.entryID))
        await fixture.sender.retrySync()
        try await fixture.receiver.setSyncEnabled(true)
        let pending = try await fixture.receiver.preservedSyncEdits()
        XCTAssertTrue(pending.isEmpty, "Unverified inaccessible work must remain pending rather than claim a preserved copy")
        try await fixture.receiver.closeStoreForTesting()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: working.url.path)
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)

        let notices = try await reopened.preservedSyncEdits()

        XCTAssertEqual(notices.count, 1)
        let value = try await reopened.materialize(.init(entryID: XCTUnwrap(notices.first).id, purpose: .normalPaste))
        guard case .file(let file) = value.items.first?.representations.first else { return XCTFail("Missing preserved work") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL), saved)
        XCTAssertEqual(try Data(contentsOf: working.url), saved)
    }

    @MainActor
    func testFilePreservationSurvivesRestartAfterCopyAndLaterSourceSave() async throws {
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.syncFilePreservationAfterCopy]))
        let page = try await fixture.receiver.page(.init())
        let working = try XCTUnwrap(page.entries.first?.linkedFileLocations.first)
        try await fixture.receiver.setSyncEnabled(false)
        let saved = Data("work already copied before the interrupted transaction".utf8)
        try saved.write(to: working.url)
        _ = try await fixture.sender.apply(.delete(fixture.entryID))
        await fixture.sender.retrySync()
        try await fixture.receiver.setSyncEnabled(true)
        try await fixture.receiver.closeStoreForTesting()
        let newer = Data("independent user save after the preservation interruption".utf8)
        try newer.write(to: working.url)
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)

        let notices = try await reopened.preservedSyncEdits()

        XCTAssertEqual(notices.count, 1)
        let notice = try XCTUnwrap(notices.first)
        let materialized = try await reopened.materialize(.init(entryID: notice.id, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("Missing retained saved copy") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL), saved)
        XCTAssertEqual(try Data(contentsOf: working.url), newer)
        let repeated = try await reopened.preservedSyncEdits()
        XCTAssertEqual(repeated.map(\.id), [notice.id])
    }

    @MainActor
    func testFileDeletionReclaimsEncryptedTransfersButKeepsOrdinaryWorkingFile() async throws {
        let bytes = Data(repeating: 0x75, count: 20_000_000)
        let fixture = try await makeLinkedFixture(initialBytes: bytes)
        let page = try await fixture.receiver.page(.init())
        let working = try XCTUnwrap(page.entries.first?.linkedFileLocations.first)
        let before = try await fixture.receiver.storageUsage()

        _ = try await fixture.sender.apply(.delete(fixture.entryID))
        await fixture.sender.retrySync()
        await fixture.receiver.retrySync()

        let after = try await fixture.receiver.storageUsage()
        XCTAssertLessThan(after + 15_000_000, before, "The encrypted transfer is reclaimable after its owned work is safely retained")
        XCTAssertEqual(try Data(contentsOf: working.url), bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.original), bytes)
        let notices = try await fixture.receiver.preservedSyncEdits()
        XCTAssertTrue(notices.isEmpty, "An unchanged already-shared file is not unuploaded local work")
    }

    @MainActor
    func testFileDeletionPreservesQueuedVersionAndLaterSaveAndPurgesPartialUploads() async throws {
        let fixture = try await makeLinkedFixture()
        await fixture.cloud.failCommits(true)
        let frozen = Data("immutable pending version with uploaded segments".utf8)
        try frozen.write(to: fixture.original)
        try await eventually { !(await fixture.cloud.partialFileRecordIDs()).isEmpty }
        try await fixture.sender.setSyncEnabled(false)
        let newer = Data("new local work after the pending version was frozen".utf8)
        try newer.write(to: fixture.original)
        await fixture.cloud.failCommits(false)
        _ = try await fixture.receiver.apply(.delete(fixture.entryID))
        await fixture.receiver.retrySync()

        try await fixture.sender.setSyncEnabled(true)

        let notices = try await fixture.sender.preservedSyncEdits()
        XCTAssertEqual(notices.count, 2)
        var contents = Set<Data>()
        for notice in notices {
            let value = try await fixture.sender.materialize(.init(entryID: notice.id, purpose: .normalPaste))
            guard case .file(let file) = value.items.first?.representations.first else { return XCTFail("Missing unpublished branch") }
            contents.insert(try Data(contentsOf: file.currentURL))
        }
        XCTAssertEqual(contents, [frozen, newer])
        let partial = await fixture.cloud.partialFileRecordIDs()
        XCTAssertTrue(partial.isEmpty, "The cleanup ledger must own segments whose manifest never committed")
    }

    @MainActor
    func testFileDeletionPreservesInterruptedFrozenBranchAndNewerSavedWork() async throws {
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.fileConflictAfterBranchFreeze]))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        try Data("remote competing published version".utf8).write(to: fixture.original)
        let frozen = Data("frozen unpublished choice before interruption".utf8)
        try frozen.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        do { _ = try await fixture.receiver.resolveFileConflict(plan, choosing: .localLocation(working.id)); XCTFail("Expected interruption") }
        catch ClipboardHistoryStorageError.injected(.fileConflictAfterBranchFreeze) { }
        try await fixture.receiver.setSyncEnabled(false)
        let newer = Data("new saved bytes after freezing the earlier branch".utf8)
        try newer.write(to: working.url)
        _ = try await fixture.sender.apply(.delete(fixture.entryID))
        await fixture.sender.retrySync()

        try await fixture.receiver.setSyncEnabled(true)

        let notices = try await fixture.receiver.preservedSyncEdits()
        XCTAssertEqual(notices.count, 2)
        var contents = Set<Data>()
        for notice in notices {
            let value = try await fixture.receiver.materialize(.init(entryID: notice.id, purpose: .normalPaste))
            guard case .file(let file) = value.items.first?.representations.first else { return XCTFail("Missing preserved branch") }
            contents.insert(try Data(contentsOf: file.currentURL))
        }
        XCTAssertEqual(contents, [frozen, newer])
        XCTAssertEqual(try Data(contentsOf: working.url), newer)
    }

    @MainActor
    func testLateFileVersionAfterDeletionIsPurgedWithoutRevivingHistory() async throws {
        let fixture = try await makeLinkedFixture()
        try await fixture.receiver.setSyncEnabled(false)
        let initialRecords = Set(await fixture.cloud.uploadedRecords().map { $0.record.recordID })
        try Data("a version this offline receiver has never seen".utf8).write(to: fixture.original)
        try await eventually { await fixture.cloud.uploadedRecords().filter { $0.record.kind == .fileBody }.count == 2 }
        let late = await fixture.cloud.uploadedRecords().filter {
            !initialRecords.contains($0.record.recordID) && ($0.record.kind == .entry || $0.record.kind == .fileBody)
        }
        _ = try await fixture.sender.apply(.delete(fixture.entryID))
        await fixture.sender.retrySync()
        try await fixture.receiver.setSyncEnabled(true)
        let deleted = try await fixture.receiver.page(.init())
        XCTAssertTrue(deleted.entries.isEmpty)

        await fixture.cloud.replayLateRecords(late)
        await fixture.receiver.retrySync()

        let page = try await fixture.receiver.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
        let remaining = await fixture.cloud.visibleRecords()
        XCTAssertTrue(remaining.allSatisfy { record in !late.contains { $0.record.recordID == record.recordID } },
            "The retired object identity must still own late version envelopes and their body segments")
    }

    @MainActor
    func testFileDisableRecoversCompletedLocalSwapWithoutCloudReactivation() async throws {
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.linkedFileAfterReplacement]))
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        let remote = Data("a verified remote file already physically installed".utf8)
        try remote.write(to: fixture.original)
        try await eventually {
            await fixture.receiver.retrySync()
            return (try? Data(contentsOf: working.url)) == remote
        }

        try await fixture.receiver.setSyncEnabled(false)

        let materialized = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("Missing retained swapped file") }
        XCTAssertEqual(file.currentURL.resolvingSymlinksInPath(), working.url.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: file.currentURL), remote)
        let disabled = await fixture.receiver.syncStatus()
        XCTAssertFalse(disabled.isEnabled)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        _ = try await reopened.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        let reopenedStatus = await reopened.syncStatus()
        XCTAssertFalse(reopenedStatus.isEnabled)
    }

    @MainActor
    func testFileDeletionPreservesUnobservedOfflineWorkOnceWithoutRepublishing() async throws {
        let fixture = try await makeLinkedFixture()
        let page = try await fixture.receiver.page(.init())
        let location = try XCTUnwrap(page.entries.first?.linkedFileLocations.first)
        let independent = fixture.root.appendingPathComponent("Independent export.txt")
        _ = try await fixture.receiver.exportFiles(fixture.entryID, to: [independent])
        try await fixture.receiver.setSyncEnabled(false)
        let dirty = Data("saved offline before any watcher could inspect this work".utf8)
        try dirty.write(to: location.url)
        _ = try await fixture.sender.apply(.delete(fixture.entryID))
        await fixture.sender.retrySync()

        try await fixture.receiver.setSyncEnabled(true)

        let notices = try await fixture.receiver.preservedSyncEdits()
        XCTAssertEqual(notices.count, 1)
        let preserved = try XCTUnwrap(notices.first)
        XCTAssertNotEqual(preserved.id, fixture.entryID)
        let materialized = try await fixture.receiver.materialize(.init(entryID: preserved.id, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("Missing preserved file") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL), dirty)
        XCTAssertNotEqual(file.currentURL, location.url, "The saved work needs an independent visible copy")
        XCTAssertEqual(try Data(contentsOf: fixture.original), Data("initial linked bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: independent), Data("initial linked bytes".utf8))
        let uploadCount = await fixture.cloud.uploadCount()
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        let replay = try await reopened.preservedSyncEdits()
        XCTAssertEqual(replay.map(\.id), [preserved.id])
        let retained = try await reopened.page(.init())
        XCTAssertEqual(retained.entries.map(\.id), [preserved.id])
        XCTAssertFalse(retained.entries.first?.tagIDs.isEmpty ?? true)
        let after = await fixture.cloud.uploadCount()
        XCTAssertEqual(after, uploadCount, "Retained selected tags must not publish an independent preserved copy")
    }

    @MainActor
    func testFileWithdrawalPurgesHistoricalBodiesAndRetainsUsableLinkedCopies() async throws {
        let fixture = try await makeLinkedFixture()
        let before = try await fixture.sender.page(.init())
        let tag = try XCTUnwrap(before.entries.first?.tagIDs.first)
        let source = try XCTUnwrap(before.entries.first?.linkedFileLocations.first)
        let edited = Data("a second immutable shared file version".utf8)
        try edited.write(to: fixture.original)
        try await eventually {
            await fixture.receiver.retrySync()
            let page = try await fixture.receiver.page(.init())
            return page.entries.first?.linkedFileLocations.first.flatMap { try? Data(contentsOf: $0.url) } == edited
        }
        let published = await fixture.cloud.visibleRecords()
        let bodies = published.filter { $0.kind == .fileBody }
        XCTAssertEqual(bodies.count, 2)

        try await fixture.sender.setSyncTagSelected(tag, selected: false)
        await fixture.receiver.retrySync()

        let remaining = await fixture.cloud.visibleRecords()
        XCTAssertTrue(remaining.filter { $0.kind == .fileBody }.isEmpty,
            "Withdrawal must reclaim every body, including an acknowledged historical version")
        let materialized = try await fixture.sender.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("Missing retained file") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL), edited)
        let locations = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(locations.first?.id, source.id)
        let uploadCount = await fixture.cloud.uploadCount()
        try Data("a retained local save after withdrawal".utf8).write(to: fixture.original)
        await fixture.sender.retrySync()
        await fixture.receiver.retrySync()
        let after = await fixture.cloud.uploadCount()
        XCTAssertEqual(after, uploadCount, "A retained linked copy must not reactivate publication")
    }
}
