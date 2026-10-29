import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testSupersededUnpublishedResultSurvivesCompletionReclamationAndRemoteDeletion() async throws {
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.fileConflictBeforeStaging]))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let remote = Data("published remote choice".utf8)
        let frozen = Data("unpublished prepared result still owns these bytes".utf8)
        try remote.write(to: fixture.original)
        try frozen.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let interrupted = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        let remoteCandidate = try XCTUnwrap(interrupted.candidates.first { if case .version = $0.id { true } else { false } })
        do {
            _ = try await fixture.receiver.resolveFileConflict(interrupted, choosing: .localLocation(working.id))
            XCTFail("Expected interruption after preparing the result")
        } catch ClipboardHistoryStorageError.injected(.fileConflictBeforeStaging) {}
        try await fixture.receiver.closeStoreForTesting()
        try Data("new save invalidates the prepared choice".utf8).write(to: working.url)
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        var review = try await reopened.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        let retained = try XCTUnwrap(review.candidates.first { candidate in
            if case .version = candidate.id { return !interrupted.candidates.contains { $0.id == candidate.id } }
            return false
        })
        for index in 0..<8 {
            try Data("saved while reviewing frozen work \(index)".utf8).write(to: working.url)
            let next = try await reopened.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
            XCTAssertNotEqual(next.id, review.id)
            XCTAssertTrue(next.candidates.contains { $0.id == retained.id })
            review = next
        }
        await reopened.retrySync()
        review = try await reopened.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        XCTAssertTrue(review.candidates.contains { $0.id == retained.id })
        let result = try await reopened.resolveFileConflict(review, choosing: remoteCandidate.id)
        await fixture.sender.retrySync()
        let replay = try await reopened.resolveFileConflict(review, choosing: remoteCandidate.id)
        XCTAssertEqual(replay, result)
        XCTAssertEqual(try Data(contentsOf: working.url), remote)
        XCTAssertEqual(try Data(contentsOf: fixture.original), remote)
        try await reopened.setSyncEnabled(false)
        _ = try await fixture.sender.apply(.delete(fixture.entryID))
        await fixture.sender.retrySync()
        try await reopened.setSyncEnabled(true)

        let notices = try await reopened.preservedSyncEdits()
        var preserved: Set<Data> = []
        for notice in notices {
            let value = try await reopened.materialize(.init(entryID: notice.id, purpose: .normalPaste))
            guard case .file(let file) = value.items.first?.representations.first else { return XCTFail("Expected a preserved file") }
            preserved.insert(try Data(contentsOf: file.currentURL))
        }
        XCTAssertEqual(preserved, [frozen], "Completion cannot erase a superseded result that never obtained durable version ownership")
        XCTAssertEqual(try Data(contentsOf: working.url), remote)
        XCTAssertEqual(try Data(contentsOf: fixture.original), remote)
        try await reopened.closeStoreForTesting()
        let final = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await final.resumeSync()
        let restored = try await final.preservedSyncEdits()
        XCTAssertEqual(Set(restored.map(\.id)), Set(notices.map(\.id)))
        let saved = try XCTUnwrap(restored.first)
        let value = try await final.materialize(.init(entryID: saved.id, purpose: .normalPaste))
        guard case .file(let file) = value.items.first?.representations.first else { return XCTFail("Expected retained recovery after reopen") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL), frozen)
    }

    @MainActor
    func testPinnedCandidateFinishesDuringPlanReclamationAndSurvivesReopen() async throws {
        let fixture = try await makeLinkedFixture()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let remote = Data(repeating: 0x74, count: 6 * 1_024 * 1_024)
        try remote.write(to: fixture.original)
        try Data("local before download".utf8).write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let before = try await fixture.receiver.syncFileSelection(objectID: working.objectID)
        let pinned = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        let candidate = try XCTUnwrap(pinned.candidates.first { if case .version = $0.id { true } else { false } })
        guard case .version(let versionID) = candidate.id else { return XCTFail("Expected remote candidate") }
        XCTAssertEqual(candidate.availability, .requiresDownload)
        let downloadsBefore = await fixture.cloud.downloadedFileVersions()
        await fixture.cloud.holdNextDownload()
        let downloading = Task { try await fixture.receiver.requestFileConflictDownload(pinned, versionID: versionID) }
        addTeardownBlock {
            await fixture.cloud.releaseDownload()
            _ = await downloading.result
        }
        try await eventually { await fixture.cloud.downloadIsHeld() }
        var latest = pinned
        var finalBytes = Data()
        for index in 0..<8 {
            finalBytes = Data("saved during pinned download \(index)".utf8)
            try finalBytes.write(to: working.url)
            let next = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
            XCTAssertNotEqual(next.id, latest.id, "Each save replaces the unprotected presentation snapshot")
            latest = next
        }
        XCTAssertEqual(try Data(contentsOf: working.url), finalBytes)
        await fixture.cloud.releaseDownload()
        try await downloading.value
        let after = try await fixture.receiver.syncFileSelection(objectID: working.objectID)
        XCTAssertEqual(after?.latest.versionID, before?.latest.versionID)
        XCTAssertEqual(after?.complete?.descriptor.versionID, before?.complete?.descriptor.versionID)
        let downloadsAfter = await fixture.cloud.downloadedFileVersions()
        XCTAssertEqual(Set(downloadsAfter).subtracting(downloadsBefore), [versionID])
        XCTAssertEqual(try Data(contentsOf: working.url), finalBytes)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        let restored = try await reopened.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        let available = try XCTUnwrap(restored.candidates.first { $0.id == candidate.id })
        XCTAssertEqual(available.availability, .available)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(available.localURL)), remote)
        XCTAssertEqual(try Data(contentsOf: working.url), finalBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.original), remote)
    }

    @MainActor
    func testDeletingAnUnconsumedConflictPlanMakesItStaleWithoutRemovingVisibleFiles() async throws {
        let fixture = try await makeLinkedFixture()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let remote = Data("remote survives removal of history".utf8)
        let local = Data("local saved file survives removal of history".utf8)
        try remote.write(to: fixture.original)
        try local.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        _ = try await fixture.receiver.apply(.delete(fixture.entryID))
        await fixture.receiver.retrySync()
        do {
            _ = try await fixture.receiver.resolveFileConflict(plan, choosing: .localLocation(working.id))
            XCTFail("An unowned presentation plan must be reclaimed")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryFileConflictError, .stalePlan)
        }
        XCTAssertEqual(try Data(contentsOf: working.url), local)
        XCTAssertEqual(try Data(contentsOf: fixture.original), remote)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        do {
            _ = try await reopened.resolveFileConflict(plan, choosing: .localLocation(working.id))
            XCTFail("Reclaimed presentation authority cannot return after reopen")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryFileConflictError, .stalePlan)
        }
        XCTAssertEqual(try Data(contentsOf: working.url), local)
        XCTAssertEqual(try Data(contentsOf: fixture.original), remote)
    }

    @MainActor
    func testNewCompletedConflictRetiresOlderReceiptButKeepsCurrentReplayAcrossRestart() async throws {
        let fixture = try await makeLinkedFixture()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        try Data("first remote conflict".utf8).write(to: fixture.original)
        let firstBytes = Data("first resolved local content".utf8)
        try firstBytes.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let firstPlan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        let choice = ClipboardHistoryFileConflictChoice.localLocation(working.id)
        let firstResult = try await fixture.receiver.resolveFileConflict(firstPlan, choosing: choice)
        await fixture.sender.retrySync()
        XCTAssertEqual(try Data(contentsOf: working.url), firstBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.original), firstBytes)
        let firstUploads = await fixture.cloud.uploadCount()
        let firstReplay = try await fixture.receiver.resolveFileConflict(firstPlan, choosing: choice)
        XCTAssertEqual(firstReplay, firstResult)
        try await fixture.receiver.closeStoreForTesting()

        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        let reopenedReplay = try await reopened.resolveFileConflict(firstPlan, choosing: choice)
        XCTAssertEqual(reopenedReplay, firstResult)
        let replayUploads = await fixture.cloud.uploadCount()
        XCTAssertEqual(replayUploads, firstUploads, "A retained receipt must not publish another result after reopen")

        try await fixture.sender.setSyncEnabled(false)
        try await reopened.setSyncEnabled(false)
        try Data("second remote conflict".utf8).write(to: fixture.original)
        let secondBytes = Data("second resolved local content".utf8)
        try secondBytes.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await reopened.setSyncEnabled(true)
        let secondPlan = try await reopened.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        XCTAssertNotEqual(secondPlan.id, firstPlan.id)
        let secondResult = try await reopened.resolveFileConflict(secondPlan, choosing: choice)
        XCTAssertNotEqual(secondResult, firstResult)
        await fixture.sender.retrySync()
        XCTAssertEqual(try Data(contentsOf: working.url), secondBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.original), secondBytes)
        let secondUploads = await fixture.cloud.uploadCount()
        do {
            _ = try await reopened.resolveFileConflict(firstPlan, choosing: choice)
            XCTFail("A newer safely completed result must retire the older settled receipt")
        } catch ClipboardHistoryFileConflictError.stalePlan {}
        try await reopened.closeStoreForTesting()

        let final = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await final.resumeSync()
        let currentReplay = try await final.resolveFileConflict(secondPlan, choosing: choice)
        XCTAssertEqual(currentReplay, secondResult)
        let currentUploads = await fixture.cloud.uploadCount()
        XCTAssertEqual(currentUploads, secondUploads)
        do {
            _ = try await final.resolveFileConflict(firstPlan, choosing: choice)
            XCTFail("An evicted receipt must remain stale after reopen")
        } catch ClipboardHistoryFileConflictError.stalePlan {}
        XCTAssertEqual(try Data(contentsOf: working.url), secondBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.original), secondBytes)
    }
}
