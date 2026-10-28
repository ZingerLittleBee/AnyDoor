import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testMissingCiphertextCreatesANewVersionOnTheOriginalObject() async throws {
        let bytes = Data(repeating: 0x64, count: 6 * 1_024 * 1_024)
        let fixture = try await makeLinkedFixture(initialBytes: bytes)
        let initial = try await fixture.receiver.page(.init())
        let original = try XCTUnwrap(initial.entries.first?.syncFiles.first)
        let tag = try XCTUnwrap(initial.entries.first?.tagIDs.first)
        try await fixture.sender.setSyncTagSelected(tag, selected: false)
        await fixture.receiver.retrySync()
        try await fixture.sender.setSyncEnabled(false)
        try FileManager.default.removeItem(at: fixture.receiverRoot.appendingPathComponent("SyncTransfers/Downloads"))

        try await fixture.receiver.setSyncTagSelected(tag, selected: true)

        let page = try await fixture.receiver.page(.init())
        let replacement = try XCTUnwrap(page.entries.first?.syncFiles.first)
        XCTAssertEqual(replacement.id, original.id)
        XCTAssertNotEqual(replacement.versionID, original.versionID,
            "Even unchanged plaintext cannot be re-encrypted under an old immutable version ID")
        let visible = await fixture.cloud.visibleRecords()
        XCTAssertFalse(visible.contains { $0.kind == .fileBody && $0.operationID == original.versionID })
        XCTAssertTrue(visible.contains { $0.kind == .fileBody && $0.operationID == replacement.versionID })
        let fresh = makeLinkedModule(root: fixture.root.appendingPathComponent("Fresh replacement rejoin"), services: fixture.services, key: 0x53)
        try await fresh.setSyncEnabled(true)
        try await fresh.requestSyncFileDownload(entryID: fixture.entryID, objectID: replacement.id, versionID: replacement.versionID)
        let locations = try await fresh.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(locations.first?.url)), bytes)
        XCTAssertEqual(locations.first?.objectID, original.id)
        let restored = try await fresh.page(.init())
        XCTAssertEqual(restored.entries.first?.syncFiles.first?.hasConflict, false)
    }

    @MainActor
    func testDirectoryRejoinUsesTheSameImmutableRestorationPath() async throws {
        let bytes = Data("a retained complete directory version".utf8)
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
            try bytes.write(to: root.appendingPathComponent("nested/notes.txt"))
        })
        let initial = try await fixture.receiver.page(.init())
        let file = try XCTUnwrap(initial.entries.first?.syncFiles.first)
        let tag = try XCTUnwrap(initial.entries.first?.tagIDs.first)
        let uploaded = await fixture.cloud.uploadedRecords()
        let original = try XCTUnwrap(uploaded.first { $0.record.kind == .fileBody && $0.record.operationID == file.versionID })
        try await fixture.sender.setSyncTagSelected(tag, selected: false)
        await fixture.receiver.retrySync()
        try await fixture.sender.setSyncEnabled(false)

        try await fixture.receiver.setSyncTagSelected(tag, selected: true)

        let visible = await fixture.cloud.visibleRecords()
        XCTAssertTrue(visible.contains(original.record))
        let fresh = makeLinkedModule(root: fixture.root.appendingPathComponent("Fresh tree rejoin"), services: fixture.services, key: 0x53)
        try await fresh.setSyncEnabled(true)
        let locations = try await fresh.linkedFileLocations(for: fixture.entryID)
        let location = try XCTUnwrap(locations.first)
        XCTAssertEqual(location.objectID, file.id)
        XCTAssertEqual(location.baseVersionID, file.versionID)
        XCTAssertEqual(try Data(contentsOf: location.url.appendingPathComponent("nested/notes.txt")), bytes)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.url.appendingPathComponent("nested/empty").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let account = await fixture.cloud.account()
        let restored = try await fixture.cloud.download(original.record, for: account)
        XCTAssertEqual(restored, original.chunks)
    }

    @MainActor
    func testReceiverRejoinRestoresIdenticalPurgedCiphertextWithoutChangingVersion() async throws {
        let bytes = Data(repeating: 0x59, count: 6 * 1_024 * 1_024)
        let fixture = try await makeLinkedFixture(initialBytes: bytes)
        let initial = try await fixture.receiver.page(.init())
        let file = try XCTUnwrap(initial.entries.first?.syncFiles.first)
        let tag = try XCTUnwrap(initial.entries.first?.tagIDs.first)
        let uploaded = await fixture.cloud.uploadedRecords()
        let original = try XCTUnwrap(uploaded.first { $0.record.kind == .fileBody && $0.record.operationID == file.versionID })
        try await fixture.sender.setSyncTagSelected(tag, selected: false)
        await fixture.receiver.retrySync()
        try await fixture.sender.setSyncEnabled(false)
        let removed = await fixture.cloud.visibleRecords()
        XCTAssertFalse(removed.contains(original.record))

        try await fixture.receiver.setSyncTagSelected(tag, selected: true)

        let visible = await fixture.cloud.visibleRecords()
        XCTAssertTrue(visible.contains(original.record))
        let account = await fixture.cloud.account()
        let restored = try await fixture.cloud.download(original.record, for: account)
        XCTAssertEqual(restored, original.chunks, "Restoration must reuse the exact immutable ciphertext")
        let fresh = makeLinkedModule(root: fixture.root.appendingPathComponent("Fresh exact rejoin"), services: fixture.services, key: 0x53)
        try await fresh.setSyncEnabled(true)
        try await fresh.requestSyncFileDownload(entryID: fixture.entryID, objectID: file.id, versionID: file.versionID)
        let page = try await fresh.page(.init())
        XCTAssertEqual(page.entries.map(\.id), [fixture.entryID])
        XCTAssertEqual(page.entries.first?.syncFiles.first?.id, file.id)
        XCTAssertEqual(page.entries.first?.syncFiles.first?.versionID, file.versionID)
        let locations = try await fresh.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(locations.first?.url)), bytes)
    }

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
