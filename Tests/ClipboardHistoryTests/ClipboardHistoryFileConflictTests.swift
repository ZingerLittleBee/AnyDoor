import AppKit
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
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
