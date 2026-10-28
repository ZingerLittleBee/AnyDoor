import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testAccountSwitchRejectsHeldFileResponseWithoutReplacingWorkingCopy() async throws {
        let fixture = try await makeLinkedFixture()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let original = try Data(contentsOf: working.url)
        try Data(repeating: 0x72, count: 2 * 1_024 * 1_024).write(to: fixture.original)
        await fixture.sender.retrySync()
        let published = try await fixture.sender.page(.init())
        XCTAssertNotEqual(published.entries.first?.syncFiles.first?.versionID, working.baseVersionID)
        let uploads = await fixture.cloud.uploadCount()
        await fixture.cloud.holdNextDownload()
        let transfer = Task { await fixture.receiver.retrySync() }
        try await eventually { await fixture.cloud.downloadIsHeld() }

        await fixture.cloud.switchAccount(to: "another-linked-file-user")
        await fixture.cloud.releaseDownload()
        await transfer.value

        let status = await fixture.receiver.syncStatus()
        XCTAssertFalse(status.isEnabled)
        XCTAssertEqual(status.phase, .failed(.accountChanged))
        XCTAssertEqual(try Data(contentsOf: working.url), original)
        let account = await fixture.cloud.account()
        let untouched = await fixture.cloud.control(for: account)
        XCTAssertNil(untouched, "A late response cannot consent to another account")
        let after = await fixture.cloud.uploadCount()
        XCTAssertEqual(after, uploads)
        try await fixture.receiver.closeStoreForTesting()
        let restarted = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await restarted.retrySync()
        let persisted = await restarted.syncStatus()
        XCTAssertFalse(persisted.isEnabled)
        XCTAssertEqual(try Data(contentsOf: working.url), original)
        let afterRestart = await fixture.cloud.uploadCount()
        XCTAssertEqual(afterRestart, uploads)
    }

    @MainActor
    func testCloudResetReclaimsPartialDownloadAndRejectsLateSuccessfulResponse() async throws {
        let fixture = try await makeLinkedFixture()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let original = try Data(contentsOf: working.url)
        try Data(repeating: 0x69, count: 20 * 1_024 * 1_024).write(to: fixture.original)
        await fixture.sender.retrySync()
        await fixture.receiver.retrySync()
        let page = try await fixture.receiver.page(.init())
        let remote = try XCTUnwrap(page.entries.first?.syncFiles.first)
        XCTAssertNotEqual(remote.versionID, working.baseVersionID)
        let before = try await fixture.receiver.storageUsage()
        await fixture.cloud.holdNextDownload(at: 1)
        let transfer = Task {
            try await fixture.receiver.requestSyncFileDownload(entryID: fixture.entryID,
                objectID: remote.id, versionID: remote.versionID)
        }
        try await eventually { await fixture.cloud.downloadIsHeld() }
        let partial = try await fixture.receiver.storageUsage()
        XCTAssertGreaterThan(partial, before + 500_000, "The first encrypted segment must already be durable")
        let confirmation = try await fixture.sender.prepareCloudReset()

        try await fixture.sender.clearCloudDataAndStopSync(confirmation)
        await fixture.cloud.releaseDownload()
        _ = try? await transfer.value
        await fixture.receiver.retrySync()

        let receiver = await fixture.receiver.syncStatus()
        XCTAssertFalse(receiver.isEnabled)
        XCTAssertEqual(try Data(contentsOf: working.url), original)
        let visible = await fixture.cloud.visibleRecords()
        XCTAssertTrue(visible.isEmpty)
        let reclaimed = try await fixture.receiver.storageUsage()
        XCTAssertLessThan(reclaimed, partial - 500_000, "Retiring the collection must reclaim partial encrypted transfers")
        try await fixture.receiver.closeStoreForTesting()
        let restarted = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await restarted.retrySync()
        let status = await restarted.syncStatus()
        XCTAssertFalse(status.isEnabled)
        XCTAssertEqual(try Data(contentsOf: working.url), original)
        let afterRestart = await fixture.cloud.visibleRecords()
        XCTAssertTrue(afterRestart.isEmpty)
    }
}
