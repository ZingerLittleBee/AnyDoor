import AppKit
import CryptoKit
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testInterruptedFrozenChoiceRemainsRecoverableAfterAnotherLocalSave() async throws {
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.fileConflictAfterBranchFreeze]))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        try Data("remote version".utf8).write(to: fixture.original)
        let frozen = Data("frozen local bytes before interruption".utf8)
        try frozen.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        do { _ = try await fixture.receiver.resolveFileConflict(plan, choosing: .localLocation(working.id)); XCTFail("Expected interruption") }
        catch ClipboardHistoryStorageError.injected(.fileConflictAfterBranchFreeze) {}
        try await fixture.receiver.closeStoreForTesting()
        let newer = Data("saved again after the interrupted choice".utf8)
        try newer.write(to: working.url)
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        let review = try await reopened.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        XCTAssertEqual(review.candidates.count, 3, "The frozen branch remains a separate recoverable choice")
        let retained = try XCTUnwrap(review.candidates.first { candidate in
            if case .version = candidate.id { return !plan.candidates.contains { $0.id == candidate.id } }
            return false
        })
        guard case .version(let retainedID) = retained.id else { return XCTFail("Expected retained version") }
        let downloads = await fixture.cloud.downloadedFileVersions()
        try await reopened.requestFileConflictDownload(review, versionID: retainedID)
        let afterDownload = await fixture.cloud.downloadedFileVersions()
        XCTAssertEqual(afterDownload, downloads, "Retained ciphertext is sufficient without a remote body")
        XCTAssertEqual(try Data(contentsOf: working.url), newer)
        let ready = try await reopened.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        let restored = try XCTUnwrap(ready.candidates.first { $0.id == retained.id })
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.localURL)), frozen)
        _ = try await reopened.resolveFileConflict(ready, choosing: retained.id)
        await fixture.sender.retrySync()
        XCTAssertEqual(try Data(contentsOf: working.url), frozen)
        XCTAssertEqual(try Data(contentsOf: fixture.original), frozen)
        let versions = try await decodedConflictVersions(cloud: fixture.cloud, services: fixture.services)
        XCTAssertTrue(versions.contains { $0.descriptor.contentDigest == Data(SHA256.hash(data: newer)) })
    }

    @MainActor
    func testOriginalSideCanChooseRemoteWorkingEditAndPreservesItsDirtyBranch() async throws {
        let fixture = try await makeLinkedFixture()
        let receiverLocations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(receiverLocations.first)
        let senderLocations = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        let original = try XCTUnwrap(senderLocations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let retained = Data("unpublished original version".utf8)
        let chosen = Data("working edit published first".utf8)
        try retained.write(to: fixture.original)
        try chosen.write(to: working.url)
        try await fixture.receiver.setSyncEnabled(true)
        try await fixture.sender.setSyncEnabled(true)
        let plan = try await fixture.sender.fileConflictPlan(entryID: fixture.entryID, objectID: original.objectID)
        let candidate = try XCTUnwrap(plan.candidates.first { if case .version = $0.id { true } else { false } })
        let result = try await fixture.sender.resolveFileConflict(plan, choosing: candidate.id)
        await fixture.receiver.retrySync()
        XCTAssertEqual(try Data(contentsOf: fixture.original), chosen)
        XCTAssertEqual(try Data(contentsOf: working.url), chosen)
        let versions = try await decodedConflictVersions(cloud: fixture.cloud, services: fixture.services)
        let preserved = try XCTUnwrap(versions.first { $0.descriptor.contentDigest == Data(SHA256.hash(data: retained)) })
        XCTAssertEqual(preserved.parents, [original.baseVersionID])
        XCTAssertTrue(versions.contains { $0.descriptor.versionID == result && $0.parents.contains(preserved.descriptor.versionID) })
    }

    @MainActor
    func testInterruptedStagedResolutionRetainsBothBodiesAndResumesWithoutNewIDs() async throws {
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.fileConflictAfterStaging]))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        try Data("remote before staged interruption".utf8).write(to: fixture.original)
        let chosen = Data("local survives staged interruption".utf8)
        try chosen.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        do { _ = try await fixture.receiver.resolveFileConflict(plan, choosing: .localLocation(working.id)); XCTFail("Expected interruption") }
        catch ClipboardHistoryStorageError.injected(.fileConflictAfterStaging) {}
        let staged = try await fixture.receiver.syncFileSelection(objectID: working.objectID)
        let resultID = try XCTUnwrap(staged?.latest.versionID)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        await fixture.sender.retrySync()
        let completed = try await reopened.syncFileSelection(objectID: working.objectID)
        XCTAssertEqual(completed?.latest.versionID, resultID)
        XCTAssertEqual(try Data(contentsOf: fixture.original), chosen)
        let versions = try await decodedConflictVersions(cloud: fixture.cloud, services: fixture.services)
        XCTAssertEqual(versions.filter { $0.descriptor.versionID == resultID }.count, 1)
    }

    @MainActor
    func decodedConflictVersions(cloud: LinkedFileCloud, services: ClipboardSyncServices) async throws -> [ClipboardSyncFileVersionContent] {
        let account = await cloud.account()
        let current = await cloud.control(for: account)
        let control = try XCTUnwrap(current)
        let loaded = try await services.keys.load(account: account, keyID: control.keyID)
        let key = try XCTUnwrap(loaded)
        let records = await cloud.uploadedRecords()
        return try records.filter { $0.record.kind == .entry }.compactMap { upload in
            if case .fileVersion(let version) = try ClipboardSyncCodec.open(upload.record, chunks: upload.chunks, account: account, control: control, key: key) { return version }
            return nil
        }
    }

    @MainActor
    func testNewSavedBytesInvalidateConflictChoiceWithoutPublishingOrOverwriting() async throws {
        let fixture = try await makeLinkedFixture()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        try Data("remote first".utf8).write(to: fixture.original)
        try Data("local first".utf8).write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        let newer = Data("local changed after confirmation opened".utf8)
        try newer.write(to: working.url)
        let before = await fixture.cloud.uploadCount()
        do {
            _ = try await fixture.receiver.resolveFileConflict(plan, choosing: .localLocation(working.id))
            XCTFail("A saved change must invalidate the displayed choice")
        } catch ClipboardHistoryFileConflictError.stalePlan {}
        XCTAssertEqual(try Data(contentsOf: working.url), newer)
        let after = await fixture.cloud.uploadCount()
        XCTAssertEqual(after, before)
    }

    @MainActor
    func testInterruptedDirtyBranchFreezeResumesAfterRestartWithOneMerge() async throws {
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.fileConflictAfterBranchFreeze]))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        try Data("remote first".utf8).write(to: fixture.original)
        let chosen = Data("durable frozen local".utf8)
        try chosen.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        let before = await fixture.cloud.uploadCount()
        do { _ = try await fixture.receiver.resolveFileConflict(plan, choosing: .localLocation(working.id)); XCTFail("Expected the injected interruption") }
        catch ClipboardHistoryStorageError.injected(.fileConflictAfterBranchFreeze) {}
        let interrupted = await fixture.cloud.uploadCount()
        XCTAssertEqual(interrupted, before)
        XCTAssertEqual(try Data(contentsOf: working.url), chosen)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        await fixture.sender.retrySync()
        XCTAssertEqual(try Data(contentsOf: fixture.original), chosen)
        let selection = try await reopened.syncFileSelection(objectID: working.objectID)
        XCTAssertEqual(selection?.heads.count, 1)
        let after = await fixture.cloud.uploadCount()
        XCTAssertEqual(after - before, 4, "One dirty branch and one resolution each publish a body and an event")
        await reopened.retrySync()
        let replay = await fixture.cloud.uploadCount()
        XCTAssertEqual(replay, after)
    }

    @MainActor
    func testEditingOlderLargeVersionResolvesLocallyWithoutFetchingNewRemoteBody() async throws {
        let fixture = try await makeLinkedFixture(initialBytes: Data(repeating: 0x31, count: 6 * 1_024 * 1_024))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let remote = Data(repeating: 0x52, count: 7 * 1_024 * 1_024)
        let chosen = Data(repeating: 0x63, count: 6 * 1_024 * 1_024 + 11)
        try remote.write(to: fixture.original)
        try chosen.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let before = await fixture.cloud.downloadedFileVersions()
        let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        XCTAssertTrue(plan.candidates.contains { $0.availability == .requiresDownload })
        _ = try await fixture.receiver.resolveFileConflict(plan, choosing: .localLocation(working.id))
        let after = await fixture.cloud.downloadedFileVersions()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: working.url), chosen)
        let account = await fixture.cloud.account()
        let currentControl = await fixture.cloud.control(for: account)
        let control = try XCTUnwrap(currentControl)
        let currentKey = try await fixture.services.keys.load(account: account, keyID: control.keyID)
        let key = try XCTUnwrap(currentKey)
        let records = await fixture.cloud.uploadedRecords()
        let versions = try records.filter { $0.record.kind == .entry }.compactMap { upload -> ClipboardSyncFileVersionContent? in
            if case .fileVersion(let version) = try ClipboardSyncCodec.open(upload.record, chunks: upload.chunks, account: account, control: control, key: key) { return version }
            return nil
        }
        let branch = try XCTUnwrap(versions.first { $0.descriptor.contentDigest == Data(CryptoKit.SHA256.hash(data: chosen)) && $0.parents == [working.baseVersionID] })
        XCTAssertTrue(versions.contains { $0.parents.contains(branch.descriptor.versionID) && $0.parents.count == 2 })
    }

    @MainActor
    func testExplicitConflictCandidateDownloadLeavesWorkingSelectionAndDirtyBytesUntouched() async throws {
        let fixture = try await makeLinkedFixture()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let remote = Data(repeating: 0x76, count: 6 * 1_024 * 1_024)
        let dirty = Data("saved local conflict".utf8)
        try remote.write(to: fixture.original)
        try dirty.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let before = try await fixture.receiver.syncFileSelection(objectID: working.objectID)
        let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        let candidate = try XCTUnwrap(plan.candidates.first { if case .version = $0.id { true } else { false } })
        guard case .version(let versionID) = candidate.id else { return XCTFail("Expected a version candidate") }
        XCTAssertEqual(candidate.availability, .requiresDownload)

        try await fixture.receiver.requestFileConflictDownload(plan, versionID: versionID)

        let after = try await fixture.receiver.syncFileSelection(objectID: working.objectID)
        XCTAssertEqual(after?.latest.versionID, before?.latest.versionID)
        XCTAssertEqual(after?.complete?.descriptor.versionID, before?.complete?.descriptor.versionID)
        XCTAssertEqual(try Data(contentsOf: working.url), dirty)
        let downloaded = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        let available = try XCTUnwrap(downloaded.candidates.first { $0.id == candidate.id })
        XCTAssertEqual(available.availability, .available)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(available.localURL)), remote)
        _ = try await fixture.receiver.resolveFileConflict(downloaded, choosing: candidate.id)
        XCTAssertEqual(try Data(contentsOf: working.url), remote)
    }

    @MainActor
    func testChoosingLocalConflictPublishesOneMergeAndConvergesWithoutRecapture() async throws {
        let fixture = try await makeLinkedFixture()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        try Data("original competing edit".utf8).write(to: fixture.original)
        let chosen = Data("chosen local working edit".utf8)
        try chosen.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)

        let result = try await fixture.receiver.resolveFileConflict(plan, choosing: .localLocation(working.id))
        await fixture.sender.retrySync()

        XCTAssertEqual(try Data(contentsOf: fixture.original), chosen)
        XCTAssertEqual(try Data(contentsOf: working.url), chosen)
        let senderPage = try await fixture.sender.page(.init())
        let receiverPage = try await fixture.receiver.page(.init())
        XCTAssertEqual(senderPage.entries.map(\.id), [fixture.entryID])
        XCTAssertEqual(receiverPage.entries.map(\.id), [fixture.entryID])
        XCTAssertEqual(senderPage.entries.first?.syncFiles.first?.versionID, result)
        XCTAssertEqual(receiverPage.entries.first?.linkedFileLocations.first?.state, .current)
        let beforeReplay = await fixture.cloud.uploadCount()
        await fixture.receiver.retrySync()
        await fixture.sender.retrySync()
        let afterReplay = await fixture.cloud.uploadCount()
        XCTAssertEqual(afterReplay, beforeReplay)
    }

    @MainActor
    func testOfflineDivergenceExposesBothContentsAndSurvivesRestart() async throws {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let originalEdit = Data("offline original edit".utf8)
        let workingEdit = Data("offline working edit".utf8)
        try originalEdit.write(to: fixture.original)
        try workingEdit.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)

        let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)

        XCTAssertEqual(plan.candidates.count, 2)
        XCTAssertTrue(plan.candidates.contains { $0.id == .localLocation(working.id) && $0.availability == .available })
        XCTAssertTrue(plan.candidates.contains { candidate in
            if case .version(let id) = candidate.id { return id != working.baseVersionID }
            return false
        })
        XCTAssertEqual(try Data(contentsOf: working.url), workingEdit)
        XCTAssertEqual(try Data(contentsOf: fixture.original), originalEdit)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        let restored = try await reopened.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        XCTAssertEqual(restored.candidates.map(\.id), plan.candidates.map(\.id))
        XCTAssertEqual(try Data(contentsOf: working.url), workingEdit)
    }
}
