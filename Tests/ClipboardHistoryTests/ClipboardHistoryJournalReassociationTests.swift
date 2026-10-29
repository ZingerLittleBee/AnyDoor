import Darwin
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testReassociatingMovedInstalledJournalReplacementRetainsItsRemoteBase() async throws {
        let fixture = try await movedJournalReplacement()
        let records = await fixture.cloud.visibleRecords()
        let result = try await fixture.receiver.reassociateFileLocation(.init(
            selection: .init(entryID: fixture.entryID, locationID: fixture.location.id,
                expectedRevision: fixture.location.revision), url: fixture.moved))

        XCTAssertEqual(result.url, fixture.moved)
        XCTAssertEqual(result.baseVersionID, fixture.remoteVersion)
        XCTAssertEqual(result.state, .current)
        XCTAssertEqual(try Data(contentsOf: fixture.moved), fixture.remote)
        XCTAssertEqual(try Data(contentsOf: fixture.displaced), Data("initial linked bytes".utf8))
        try await fixture.receiver.setSyncEnabled(true)
        await fixture.receiver.retrySync()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(locations.first?.baseVersionID, fixture.remoteVersion)
        XCTAssertEqual(locations.first?.state, .current)
        let page = try await fixture.receiver.page(.init())
        XCTAssertEqual(page.entries.first?.syncFiles.first?.hasConflict, false)
        let after = await fixture.cloud.visibleRecords()
        XCTAssertEqual(after, records, "Adopting the known installed version must not publish a synthetic branch")
    }

    @MainActor
    func testReassociatingEditedJournalReplacementPreservesItsActualOldBase() async throws {
        let fixture = try await movedJournalReplacement()
        let inode = try reassociationInode(fixture.moved)
        let edited = Data("user changed the moved replacement in place".utf8)
        try edited.write(to: fixture.moved)
        XCTAssertEqual(try reassociationInode(fixture.moved), inode)
        let result = try await fixture.receiver.reassociateFileLocation(.init(
            selection: .init(entryID: fixture.entryID, locationID: fixture.location.id,
                expectedRevision: fixture.location.revision), url: fixture.moved))

        XCTAssertEqual(result.baseVersionID, fixture.location.baseVersionID)
        XCTAssertEqual(result.state, .localChanges)
        try await fixture.receiver.setSyncEnabled(true)
        let page = try await fixture.receiver.page(.init())
        XCTAssertEqual(page.entries.first?.syncFiles.first?.hasConflict, true)
        XCTAssertEqual(try Data(contentsOf: fixture.moved), edited)
        XCTAssertEqual(try Data(contentsOf: fixture.displaced), Data("initial linked bytes".utf8))
    }

    @MainActor
    func testReassociatingSameBytesOnAnotherInodeDoesNotAdoptJournalBase() async throws {
        let fixture = try await movedJournalReplacement()
        let copied = fixture.moved.deletingLastPathComponent().appendingPathComponent("Independent equal bytes.txt")
        try fixture.remote.write(to: copied)
        XCTAssertNotEqual(try reassociationInode(copied), try reassociationInode(fixture.moved))
        let result = try await fixture.receiver.reassociateFileLocation(.init(
            selection: .init(entryID: fixture.entryID, locationID: fixture.location.id,
                expectedRevision: fixture.location.revision), url: copied))

        XCTAssertEqual(result.baseVersionID, fixture.location.baseVersionID)
        XCTAssertEqual(result.state, .localChanges)
        try await fixture.receiver.setSyncEnabled(true)
        let page = try await fixture.receiver.page(.init())
        XCTAssertEqual(page.entries.first?.syncFiles.first?.hasConflict, true)
        XCTAssertEqual(try Data(contentsOf: copied), fixture.remote)
        XCTAssertEqual(try Data(contentsOf: fixture.moved), fixture.remote)
        XCTAssertEqual(try Data(contentsOf: fixture.displaced), Data("initial linked bytes".utf8))
    }

    @MainActor
    func testReassociatingSupersededJournalReplacementDoesNotAdoptStaleSelection() async throws {
        let fixture = try await movedJournalReplacement()
        try Data("later remote version superseding the journal".utf8).write(to: fixture.original)
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: fixture.location.objectID)
        try await fixture.receiver.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(false)
        let page = try await fixture.receiver.page(.init())
        XCTAssertNotEqual(page.entries.first?.syncFiles.first?.versionID, fixture.remoteVersion)
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let current = try XCTUnwrap(locations.first)
        let result = try await fixture.receiver.reassociateFileLocation(.init(
            selection: .init(entryID: fixture.entryID, locationID: current.id,
                expectedRevision: current.revision), url: fixture.moved))

        XCTAssertEqual(result.baseVersionID, fixture.location.baseVersionID)
        XCTAssertEqual(result.state, .localChanges)
        XCTAssertEqual(try Data(contentsOf: fixture.moved), fixture.remote)
        XCTAssertEqual(try Data(contentsOf: fixture.displaced), Data("initial linked bytes".utf8))
    }

    @MainActor
    private func movedJournalReplacement() async throws -> MovedJournalReplacement {
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.linkedFileAfterReplacement]))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let remote = Data("installed version moved before journal completion".utf8)
        try remote.write(to: fixture.original)
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        await fixture.receiver.retrySync()
        let page = try await fixture.sender.page(.init())
        let remoteVersion = try XCTUnwrap(page.entries.first?.syncFiles.first?.versionID)
        XCTAssertNotEqual(remoteVersion, working.baseVersionID)
        XCTAssertEqual(try Data(contentsOf: working.url), remote)
        let outputs = try FileManager.default.contentsOfDirectory(at: working.url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(working.url.lastPathComponent + " (AnyDoor update ") }
        let displaced = try XCTUnwrap(outputs.first)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(try Data(contentsOf: displaced), Data("initial linked bytes".utf8))
        let inode = try reassociationInode(working.url)
        let moved = fixture.root.appendingPathComponent("Moved installed version.txt")
        try FileManager.default.moveItem(at: working.url, to: moved)
        XCTAssertEqual(try reassociationInode(moved), inode)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        try await reopened.setSyncEnabled(false)
        let restored = try await reopened.linkedFileLocations(for: fixture.entryID)
        let current = try XCTUnwrap(restored.first)
        XCTAssertEqual(current.baseVersionID, working.baseVersionID)
        XCTAssertEqual(current.state, .unavailable)
        return .init(receiver: reopened, sender: fixture.sender, cloud: fixture.cloud, entryID: fixture.entryID,
            location: current, original: fixture.original, moved: moved, displaced: displaced,
            remoteVersion: remoteVersion, remote: remote)
    }

    private func reassociationInode(_ url: URL) throws -> ino_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw CocoaError(.fileReadUnknown) }
        return status.st_ino
    }
}

private struct MovedJournalReplacement {
    let receiver: ClipboardHistoryModule
    let sender: ClipboardHistoryModule
    let cloud: LinkedFileCloud
    let entryID: ClipboardHistoryEntryID
    let location: ClipboardHistoryLinkedFileLocation
    let original: URL
    let moved: URL
    let displaced: URL
    let remoteVersion: UUID
    let remote: Data
}
