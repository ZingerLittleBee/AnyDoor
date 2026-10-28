import AppKit
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testNestedDirectorySaveSynchronizesWithoutRefreshingTheSourceMac() async throws {
        let fixture = try await makeObservedTreeFixture()
        let expected = Data("nested saved change observed recursively".utf8)

        try expected.write(to: fixture.source.appendingPathComponent("nested/deep/note.txt"))

        // Only the receiving Mac is polled. The source must react to its native
        // recursive observation; a root-only vnode event cannot see this write.
        try await eventually {
            await fixture.receiver.retrySync()
            return (try? Data(contentsOf: fixture.working.appendingPathComponent("nested/deep/note.txt"))) == expected
        }
    }

    @MainActor
    func testNestedDirectoryAdditionAndRemovalSynchronizeWithoutDetachingTheRoot() async throws {
        let fixture = try await makeObservedTreeFixture()
        let addedDirectory = fixture.source.appendingPathComponent("nested/deep/new branch")
        let bytes = Data("new nested file".utf8)
        try FileManager.default.createDirectory(at: addedDirectory, withIntermediateDirectories: false)
        try bytes.write(to: addedDirectory.appendingPathComponent("added.txt"))

        try await eventually {
            await fixture.receiver.retrySync()
            return (try? Data(contentsOf: fixture.working.appendingPathComponent("nested/deep/new branch/added.txt"))) == bytes
        }
        try FileManager.default.removeItem(at: addedDirectory)
        try await eventually {
            await fixture.receiver.retrySync()
            return !FileManager.default.fileExists(atPath: fixture.working.appendingPathComponent("nested/deep/new branch").path)
        }
        let locations = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(locations.count, 1)
        XCTAssertEqual(locations.first?.state, .current, "Removing a child must not detach its linked directory root")
        XCTAssertEqual(try Data(contentsOf: fixture.working.appendingPathComponent("nested/deep/note.txt")), Data("initial nested content".utf8))
    }

    @MainActor
    func testDirectoryObservationStopsWhenDisabledAndResumesAfterRestart() async throws {
        let fixture = try await makeObservedTreeFixture()
        try await fixture.sender.setSyncEnabled(false)
        let before = await fixture.cloud.uploadCount()
        let saved = Data("saved nested bytes while sync was off".utf8)
        try saved.write(to: fixture.source.appendingPathComponent("nested/deep/note.txt"))
        try await Task.sleep(for: .seconds(1))
        let after = await fixture.cloud.uploadCount()
        XCTAssertEqual(after, before, "Disabling sync must stop native subtree observation and publication")
        XCTAssertEqual(try Data(contentsOf: fixture.working.appendingPathComponent("nested/deep/note.txt")), Data("initial nested content".utf8))
        try await fixture.sender.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.root.appendingPathComponent("Sender"), services: fixture.services, key: 0x61)

        try await reopened.setSyncEnabled(true)

        try await eventually {
            await fixture.receiver.retrySync()
            return (try? Data(contentsOf: fixture.working.appendingPathComponent("nested/deep/note.txt"))) == saved
        }
        let secondSave = Data("observed after the module restarted".utf8)
        try secondSave.write(to: fixture.source.appendingPathComponent("nested/deep/note.txt"))
        try await eventually {
            await fixture.receiver.retrySync()
            return (try? Data(contentsOf: fixture.working.appendingPathComponent("nested/deep/note.txt"))) == secondSave
        }
    }

    @MainActor
    func testDirectoryAndParentMovesKeepObservingSubsequentNestedSaves() async throws {
        let fixture = try await makeObservedTreeFixture()
        let initialLocations = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        let initial = try XCTUnwrap(initialLocations.first)
        let parent = fixture.root.appendingPathComponent("Moved parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let moved = parent.appendingPathComponent("Moved tree")
        try FileManager.default.moveItem(at: fixture.source, to: moved)
        let firstSave = Data("nested save after root move".utf8)
        try firstSave.write(to: moved.appendingPathComponent("nested/deep/note.txt"))
        try await eventually {
            await fixture.receiver.retrySync()
            return (try? Data(contentsOf: fixture.working.appendingPathComponent("nested/deep/note.txt"))) == firstSave
        }

        let renamedParent = fixture.root.appendingPathComponent("Renamed parent")
        try FileManager.default.moveItem(at: parent, to: renamedParent)
        let finalURL = renamedParent.appendingPathComponent("Moved tree")
        let secondSave = Data("nested save after parent move".utf8)
        try secondSave.write(to: finalURL.appendingPathComponent("nested/deep/note.txt"))
        try await eventually {
            await fixture.receiver.retrySync()
            return (try? Data(contentsOf: fixture.working.appendingPathComponent("nested/deep/note.txt"))) == secondSave
        }
        let locations = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(locations.first?.id, initial.id)
        XCTAssertEqual(locations.first?.url.resolvingSymlinksInPath(), finalURL.resolvingSymlinksInPath())
        XCTAssertGreaterThan(try XCTUnwrap(locations.first?.revision), initial.revision)
    }

    @MainActor
    private func makeObservedTreeFixture() async throws -> (
        sender: ClipboardHistoryModule, receiver: ClipboardHistoryModule,
        source: URL, working: URL, root: URL, entryID: ClipboardHistoryEntryID,
        services: ClipboardSyncServices, cloud: LinkedFileCloud
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tree-observation-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let source = root.appendingPathComponent("Shared folder", isDirectory: true)
        let nested = source.appendingPathComponent("nested/deep/note.txt")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("initial nested content".utf8).write(to: nested)
        let cloud = LinkedFileCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: TreeObservationTestKeys(), pollingInterval: nil)
        let sender = makeLinkedModule(root: root.appendingPathComponent("Sender"), services: services, key: 0x61)
        let receiver = makeLinkedModule(root: root.appendingPathComponent("Receiver"), services: services, key: 0x62)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.tree-observation.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(source.absoluteString, forType: .fileURL)
        guard case .captured(let capture) = try await sender.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let tag = try await sender.createTagDefinition(named: "Observed tree", assigningTo: capture.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        let locations = try await receiver.linkedFileLocations(for: capture.entryID)
        let working = try XCTUnwrap(locations.first, "The complete directory must have a managed working location")
        return (sender, receiver, source, working.url, root, capture.entryID, services, cloud)
    }
}

private actor TreeObservationTestKeys: ClipboardSyncKeyStoring {
    private var values: [UUID: Data] = [:]
    func load(account: ClipboardSyncAccount, keyID: UUID) -> Data? { values[keyID] }
    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) throws -> Data {
        if let existing = values[keyID] {
            guard existing == key else { throw ClipboardSyncServiceError.corruptData }
            return existing
        }
        values[keyID] = key
        return key
    }
}
