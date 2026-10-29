import AppKit
import Darwin
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testFileIdentityPauseRevokesAReplacementAfterItsBytesWereVerified() async throws {
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .linkedFileBeforeReplacement { barrier.pause() }
            return false
        })
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        try Data("remote version reaching final replacement".utf8).write(to: fixture.original)
        try await eventually {
            let locations = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
            return locations.first?.baseVersionID != working.baseVersionID
        }
        await fixture.sender.retrySync()
        let receive = Task { await fixture.receiver.retrySync() }
        try await eventually { barrier.isWaiting }
        let current = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let displayed = try XCTUnwrap(current.first)

        try await fixture.receiver.setFileLocationPaused(.init(entryID: fixture.entryID,
            locationID: displayed.id, expectedRevision: displayed.revision), paused: true)
        barrier.release()
        await receive.value

        XCTAssertEqual(try Data(contentsOf: working.url), Data("initial linked bytes".utf8))
        let paused = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(paused.first?.state, .paused)
    }

    @MainActor
    func testFileIdentityNativeRenameAndParentMoveRefreshTheSameLocation() async throws {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        let original = try XCTUnwrap(initial.first)
        let directory = fixture.root.appendingPathComponent("Moved parent")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let moved = directory.appendingPathComponent("Moved notes.txt")

        try FileManager.default.moveItem(at: fixture.original, to: moved)

        try await eventually {
            let locations = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
            return locations.first?.url.resolvingSymlinksInPath() == moved.resolvingSymlinksInPath()
        }
        let renamedParent = fixture.root.appendingPathComponent("Renamed parent")
        try FileManager.default.moveItem(at: directory, to: renamedParent)
        let finalURL = renamedParent.appendingPathComponent("Moved notes.txt")
        try await eventually {
            await fixture.sender.retrySync()
            let current = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
            return current.first?.url.resolvingSymlinksInPath() == finalURL.resolvingSymlinksInPath()
        }
        let locations = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(locations.first?.id, original.id)
        XCTAssertEqual(locations.first?.url.resolvingSymlinksInPath(), finalURL.resolvingSymlinksInPath())
        XCTAssertGreaterThan(try XCTUnwrap(locations.first?.revision), original.revision)
        let materialized = try await fixture.sender.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("Missing moved source") }
        XCTAssertEqual(file.currentURL.resolvingSymlinksInPath(), finalURL.resolvingSymlinksInPath())
    }

    @MainActor
    func testFileIdentityPermissionLossPausesAndRestorationResumesWithoutEmptyPublication() async throws {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        let original = try XCTUnwrap(initial.first)
        let before = await fixture.cloud.uploadCount()
        XCTAssertEqual(chmod(fixture.original.path, 0), 0)
        defer { _ = chmod(fixture.original.path, 0o600) }
        XCTAssertNotEqual(access(fixture.original.path, R_OK), 0, "The fixture must genuinely deny file reads")

        await fixture.sender.retrySync()

        let unavailable = try await fixture.sender.page(.init())
        XCTAssertEqual(unavailable.entries.first?.linkedFileLocations.first?.state, .unavailable)
        XCTAssertEqual(unavailable.entries.first?.syncFiles.first?.state, .localUnavailable)
        let peerLocations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let peer = try XCTUnwrap(peerLocations.first)
        XCTAssertEqual(try Data(contentsOf: peer.url), Data("initial linked bytes".utf8))
        XCTAssertEqual(chmod(fixture.original.path, 0o600), 0)
        await fixture.sender.retrySync()
        let restored = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(restored.first?.id, original.id)
        XCTAssertEqual(restored.first?.baseVersionID, original.baseVersionID)
        XCTAssertEqual(restored.first?.state, .current)
        let after = await fixture.cloud.uploadCount()
        XCTAssertEqual(after, before)
    }

    @MainActor
    func testFileIdentityPauseKeepsWorkingBytesUntilExplicitResume() async throws {
        let fixture = try await makeLinkedFixture()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let initialInode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: working.url.path)[.systemFileNumber] as? NSNumber)
        let selection = ClipboardHistoryFileLocationSelection(entryID: fixture.entryID,
            locationID: working.id, expectedRevision: working.revision)

        try await fixture.receiver.setFileLocationPaused(selection, paused: true)

        let remote = Data("remote version while this location is paused".utf8)
        try remote.write(to: fixture.original)
        try await eventually {
            await fixture.receiver.retrySync()
            let page = try await fixture.receiver.page(.init())
            return page.entries.first?.syncFiles.first?.versionID != working.baseVersionID
        }
        XCTAssertEqual(try Data(contentsOf: working.url), Data("initial linked bytes".utf8))
        let pausedPage = try await fixture.receiver.page(.init())
        let paused = try XCTUnwrap(pausedPage.entries.first?.linkedFileLocations.first)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(pausedPage.entries.first?.syncFiles.first?.availableVersionID, working.baseVersionID)
        XCTAssertEqual(pausedPage.entries.first?.syncFiles.first?.state, .updateAvailable)
        try await fixture.receiver.setFileLocationPaused(.init(entryID: fixture.entryID,
            locationID: paused.id, expectedRevision: paused.revision), paused: false)
        try await eventually { (try? Data(contentsOf: working.url)) == remote }
        let appliedInode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: working.url.path)[.systemFileNumber] as? NSNumber)
        XCTAssertNotEqual(appliedInode, initialInode, "The owned replacement journal must admit the verified new filesystem object")
        do {
            try await fixture.receiver.setFileLocationPaused(selection, paused: true)
            XCTFail("A stale pause control must not affect a changed linked location")
        } catch ClipboardHistoryModuleError.operationUnavailable { }
    }

    @MainActor
    func testFileIdentityUnprovenSafeSaveRequiresExplicitReassociationAndRejectsStaleChoice() async throws {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        let original = try XCTUnwrap(initial.first)
        try await fixture.sender.setSyncEnabled(false)
        let replacement = fixture.root.appendingPathComponent("Editor temporary file.txt")
        let saved = Data("new saved bytes requiring an explicit identity decision".utf8)
        try saved.write(to: replacement)
        var coordinationError: NSError?
        var saveError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: fixture.original, options: [], error: &coordinationError) { url in
            do { _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement) }
            catch { saveError = error }
        }
        if let coordinationError { throw coordinationError }
        if let saveError { throw saveError }
        try await fixture.sender.setSyncEnabled(true)
        let locations = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        let ambiguous = try XCTUnwrap(locations.first)
        XCTAssertEqual(ambiguous.state, .identityUncertain)
        XCTAssertEqual(ambiguous.baseVersionID, original.baseVersionID)
        let page = try await fixture.sender.page(.init())
        XCTAssertEqual(page.entries.first?.syncFiles.first?.state, .localUnavailable)
        do {
            _ = try await fixture.sender.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
            XCTFail("An unproven replacement must not be materialized")
        } catch ClipboardHistoryModuleError.fileReferencesUnavailable { }
        let selection = ClipboardHistoryFileLocationSelection(entryID: fixture.entryID,
            locationID: original.id, expectedRevision: ambiguous.revision)
        do {
            try await fixture.sender.setFileLocationPaused(selection, paused: false)
            XCTFail("Resume must not bypass the explicit identity decision")
        } catch ClipboardHistoryModuleError.operationUnavailable { }

        let associated = try await fixture.sender.reassociateFileLocation(.init(selection: selection, url: fixture.original))

        XCTAssertEqual(associated.id, original.id)
        XCTAssertEqual(associated.objectID, original.objectID)
        XCTAssertEqual(try Data(contentsOf: fixture.original), saved)
        try await eventually {
            await fixture.receiver.retrySync()
            let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
            return locations.first.flatMap { try? Data(contentsOf: $0.url) } == saved
        }
        do {
            _ = try await fixture.sender.reassociateFileLocation(.init(selection: selection, url: fixture.original))
            XCTFail("Reassociation must reject a stale displayed revision")
        } catch ClipboardHistoryModuleError.operationUnavailable { }
    }

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
                .first(where: { $0.id == original.id })?.state == .detached
        }
        let unrelated = Data("new unrelated same-name file".utf8)
        try unrelated.write(to: fixture.original)
        try await fixture.sender.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.root.appendingPathComponent("Sender"), services: fixture.services, key: 0x51)
        await reopened.resumeSync()
        let page = try await reopened.page(.init())
        XCTAssertEqual(page.entries.first?.linkedFileLocations.first(where: { $0.id == original.id })?.state, .detached)
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
