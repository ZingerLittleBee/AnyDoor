import AppKit
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testFileIdentityConfirmedRemovalStaysDetachedAndUsesAnotherLinkedCopyAfterRestart() async throws {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        let original = try XCTUnwrap(initial.first)
        let second = fixture.root.appendingPathComponent("Other linked location.txt")
        try FileManager.default.copyItem(at: fixture.original, to: second)
        _ = try await fixture.sender.associateFileLocation(.init(entryID: fixture.entryID, objectID: original.objectID, url: second))

        try FileManager.default.removeItem(at: fixture.original)

        try await eventually {
            try await fixture.sender.linkedFileLocations(for: fixture.entryID)
                .first(where: { $0.id == original.id })?.state.rawValue == "detached"
        }
        let unrelated = Data("new unrelated same-name file".utf8)
        try unrelated.write(to: fixture.original)
        try await fixture.sender.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.root.appendingPathComponent("Sender"), services: fixture.services, key: 0x51)
        await reopened.resumeSync()
        let page = try await reopened.page(.init())
        XCTAssertEqual(page.entries.first?.linkedFileLocations.first(where: { $0.id == original.id })?.state.rawValue, "detached")
        XCTAssertEqual(page.entries.first?.syncFiles.first?.state, .complete)
        let materialized = try await reopened.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("Missing remaining linked copy") }
        XCTAssertEqual(file.currentURL.resolvingSymlinksInPath(), second.resolvingSymlinksInPath())
        let peerLocations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let peer = try XCTUnwrap(peerLocations.first)
        let remote = Data("peer keeps syncing after source removal".utf8)
        try remote.write(to: peer.url)
        try await eventually {
            await reopened.retrySync()
            return (try? Data(contentsOf: second)) == remote
        }
        XCTAssertEqual(try Data(contentsOf: fixture.original), unrelated)
    }

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
        let page = try await reopened.page(.init())
        XCTAssertEqual(page.entries.first?.syncFiles.first?.state, .complete)
        let materialized = try await reopened.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("Missing moved file") }
        XCTAssertEqual(file.currentURL.resolvingSymlinksInPath(), moved.resolvingSymlinksInPath())
        let saved = Data("saved in moved original".utf8)
        try saved.write(to: moved)
        try await eventually {
            await fixture.receiver.retrySync()
            guard let working = try await fixture.receiver.linkedFileLocations(for: fixture.entryID).first else { return false }
            return (try? Data(contentsOf: working.url)) == saved
        }
    }
}
