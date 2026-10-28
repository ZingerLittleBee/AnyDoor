import AppKit
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testFileIdentityFollowsRenamedOriginalAcrossRestartWithoutAdoptingOldPath() async throws {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        let original = try XCTUnwrap(initial.first)
        try await fixture.sender.setSyncEnabled(false)
        let moved = fixture.root.appendingPathComponent("Renamed notes.txt")
        try FileManager.default.moveItem(at: fixture.original, to: moved)
        let unrelated = Data("unrelated replacement at the former path".utf8)
        try unrelated.write(to: fixture.original)
        try await fixture.sender.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.root.appendingPathComponent("Sender"), services: fixture.services, key: 0x51)

        try await reopened.setSyncEnabled(true)

        let locations = try await reopened.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(locations.first?.id, original.id)
        XCTAssertEqual(locations.first?.url.standardizedFileURL, moved.standardizedFileURL)
        XCTAssertEqual(locations.first?.state, .current)
        XCTAssertEqual(try Data(contentsOf: fixture.original), unrelated)
        let saved = Data("saved in moved original".utf8)
        try saved.write(to: moved)
        try await eventually {
            await fixture.receiver.retrySync()
            guard let working = try await fixture.receiver.linkedFileLocations(for: fixture.entryID).first else { return false }
            return (try? Data(contentsOf: working.url)) == saved
        }
    }
}
