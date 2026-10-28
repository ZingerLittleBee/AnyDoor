import AppKit
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
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
