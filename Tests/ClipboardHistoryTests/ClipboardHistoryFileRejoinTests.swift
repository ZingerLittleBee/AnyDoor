import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testFileRejoinRestoresNonRootAncestryForFreshReceiver() async throws {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        let original = try XCTUnwrap(initial.first)
        let changed = Data("saved child version before withdrawal".utf8)
        try changed.write(to: fixture.original)
        await fixture.sender.retrySync()
        await fixture.receiver.retrySync()
        let edited = try await fixture.sender.page(.init())
        let child = try XCTUnwrap(edited.entries.first?.syncFiles.first)
        XCTAssertNotEqual(child.versionID, original.baseVersionID)
        let tags = try await fixture.sender.tagDefinitions()
        let tag = try XCTUnwrap(tags.first)

        try await fixture.sender.setSyncTagSelected(tag.id, selected: false)
        await fixture.receiver.retrySync()
        try await fixture.receiver.setSyncTagSelected(tag.id, selected: true)

        let fresh = makeLinkedModule(root: fixture.root.appendingPathComponent("Fresh rejoin"), services: fixture.services, key: 0x53)
        try await fresh.setSyncEnabled(true)
        let restored = try await fresh.page(.init())
        XCTAssertEqual(restored.entries.map(\.id), [fixture.entryID])
        XCTAssertEqual(restored.entries.first?.syncFiles.first?.id, original.objectID)
        XCTAssertEqual(restored.entries.first?.syncFiles.first?.versionID, child.versionID)
        XCTAssertEqual(restored.entries.first?.syncFiles.first?.hasConflict, false)
        let locations = try await fresh.linkedFileLocations(for: fixture.entryID)
        let location = try XCTUnwrap(locations.first)
        XCTAssertEqual(try Data(contentsOf: location.url), changed)
    }
}
