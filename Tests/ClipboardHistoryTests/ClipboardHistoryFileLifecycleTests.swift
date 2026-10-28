import AppKit
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
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
