import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testFreshReceiverDoesNotLinkIncompleteVersionDeliveredBeforeEntry() async throws {
        let fixture = try await makeLinkedFixture()
        let locations = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        let original = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        let parentID = UUID(), childID = UUID()
        let expected = Data("complete version after reordered metadata".utf8)
        _ = try await commitConflictRemoteFile(bytes: expected, versionID: childID,
            parents: [original.baseVersionID, parentID], objectID: original.objectID,
            root: fixture.root, services: fixture.services, cloud: fixture.cloud)
        await fixture.cloud.moveLastTwoRecordsToFront()
        let fresh = makeLinkedModule(root: fixture.root.appendingPathComponent("Fresh"), services: fixture.services, key: 0x53)
        try await fresh.setSyncEnabled(true)
        let unproven = try await fresh.linkedFileLocations(for: fixture.entryID)
        XCTAssertTrue(unproven.isEmpty)
        _ = try await commitConflictRemoteFile(bytes: Data("parent version".utf8), versionID: parentID,
            parents: [original.baseVersionID], objectID: original.objectID,
            root: fixture.root, services: fixture.services, cloud: fixture.cloud)
        await fresh.retrySync()
        let complete = try await fresh.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(complete.first?.baseVersionID, childID)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(complete.first?.url)), expected)
    }

    @MainActor
    func testReorderedFileAncestryWaitsForEveryParentBeforeInstalling() async throws {
        let fixture = try await makeLinkedFixture()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        let parentID = UUID()
        let resultID = UUID()
        let expected = Data("latest causally complete content".utf8)
        _ = try await commitConflictRemoteFile(bytes: expected, versionID: resultID,
            parents: [working.baseVersionID, parentID], objectID: working.objectID,
            root: fixture.root, services: fixture.services, cloud: fixture.cloud)
        await fixture.receiver.retrySync()
        XCTAssertEqual(try Data(contentsOf: working.url), Data("initial linked bytes".utf8))
        let incomplete = try await fixture.receiver.syncFileSelection(objectID: working.objectID)
        XCTAssertEqual(incomplete?.latest.versionID, working.baseVersionID)
        let page = try await fixture.receiver.page(.init())
        XCTAssertEqual(page.entries.first?.syncFiles.first?.hasConflict, true)

        _ = try await commitConflictRemoteFile(bytes: Data("intermediate saved version".utf8), versionID: parentID,
            parents: [working.baseVersionID], objectID: working.objectID,
            root: fixture.root, services: fixture.services, cloud: fixture.cloud)
        await fixture.receiver.retrySync()
        XCTAssertEqual(try Data(contentsOf: working.url), expected)
        let complete = try await fixture.receiver.syncFileSelection(objectID: working.objectID)
        XCTAssertEqual(complete?.latest.versionID, resultID)
        let before = await fixture.cloud.uploadCount()
        await fixture.receiver.retrySync()
        let after = await fixture.cloud.uploadCount()
        XCTAssertEqual(after, before)
    }

    @MainActor
    func testCyclicFileAncestryCannotAuthorizeAReplacement() async throws {
        let fixture = try await makeLinkedFixture()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        let first = UUID(), second = UUID()
        _ = try await commitConflictRemoteFile(bytes: Data("first invalid cycle".utf8), versionID: first,
            parents: [working.baseVersionID, second], objectID: working.objectID,
            root: fixture.root, services: fixture.services, cloud: fixture.cloud)
        _ = try await commitConflictRemoteFile(bytes: Data("second invalid cycle".utf8), versionID: second,
            parents: [first], objectID: working.objectID,
            root: fixture.root, services: fixture.services, cloud: fixture.cloud)
        await fixture.receiver.retrySync()
        XCTAssertEqual(try Data(contentsOf: working.url), Data("initial linked bytes".utf8))
        let status = await fixture.receiver.syncStatus()
        XCTAssertEqual(status.phase, .failed(.corruptData))
    }

    /// The external cloud boundary can deliver authenticated events out of order.
    /// Bodies use the real bounded encrypted format and real temporary files.
    @MainActor
    func commitConflictRemoteFile(bytes: Data, versionID: UUID, parents: [UUID], objectID: UUID,
        root: URL, services: ClipboardSyncServices, cloud: LinkedFileCloud) async throws -> ClipboardSyncFileDescriptor {
        let account = await cloud.account()
        let current = await cloud.control(for: account)
        var control = try XCTUnwrap(current)
        let loaded = try await services.keys.load(account: account, keyID: control.keyID)
        let key = try XCTUnwrap(loaded)
        let source = root.appendingPathComponent("remote-\(versionID).txt")
        try bytes.write(to: source)
        let proof = try ClipboardLinkedFileIO.inspect(source)
        let frozen = try await ClipboardSyncFileTransfer.freeze(url: source, bookmark: proof.bookmark, identity: proof.identity,
            directory: root.appendingPathComponent("remote-body-\(versionID)"), account: account, control: control,
            key: key, objectID: objectID, versionID: versionID)
        let descriptor = ClipboardSyncFileDescriptor(objectID: objectID, versionID: versionID,
            displayName: "Linked notes.txt", originalByteCount: frozen.originalByteCount,
            contentDigest: frozen.contentDigest, body: frozen.upload.record, state: .available, bodyFormat: .segmentsV1)
        control = try await cloud.commitFile(frozen.upload, for: account, control: control, progress: { _ in })
        let event = try ClipboardSyncCodec.seal(.fileVersion(.init(descriptor: descriptor, parents: parents)),
            account: account, control: control, key: key, operationID: UUID())
        _ = try await cloud.commit(event, for: account, control: control)
        return descriptor
    }
}
