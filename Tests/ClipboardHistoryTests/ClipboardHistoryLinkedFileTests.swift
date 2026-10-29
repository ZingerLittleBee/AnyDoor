import AppKit
import Darwin
import Foundation
import XCTest
import os
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

final class ClipboardHistoryLinkedFileTests: XCTestCase {
    @MainActor
    func testRestoringLinkedBaseClearsSourceFailureWithoutPublishingAnotherVersion() async throws {
        let changing = OSAllocatedUnfairLock(initialState: Optional<URL>.none)
        let faults = ClipboardHistoryFaultInjector { point in
            if point == .syncFileTreeBeforeFreezeVerification, let member = changing.withLock({ $0 }) {
                try? Data("changed during freeze".utf8).write(to: member)
            }
            return false
        }
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("original tree member".utf8).write(to: root.appendingPathComponent("member"))
        }, senderFault: faults)
        let member = fixture.original.appendingPathComponent("member")
        var original = stat()
        XCTAssertEqual(lstat(member.path, &original), 0)
        let before = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        let originalLocation = try XCTUnwrap(before.first)
        let uploads = await fixture.cloud.uploadCount()
        changing.withLock { $0 = member }
        try Data("saved before freeze".utf8).write(to: member)
        await fixture.sender.retrySync()
        let failed = try await fixture.sender.page(.init()).entries
        XCTAssertEqual(failed.first?.syncFiles.first?.transferFailure, .sourceChanged)
        changing.withLock { $0 = nil }
        try Data("original tree member".utf8).write(to: member)
        let descriptor = open(member.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var timestamps = [original.st_atimespec, original.st_mtimespec]
        XCTAssertEqual(futimens(descriptor, &timestamps), 0)
        await fixture.sender.resumeSync()
        await fixture.sender.retrySync()
        let restored = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(restored.first?.state, .current)
        XCTAssertEqual(restored.first?.baseVersionID, originalLocation.baseVersionID)
        let current = try await fixture.sender.page(.init()).entries
        XCTAssertNil(current.first?.syncFiles.first?.transferFailure)
        let after = await fixture.cloud.uploadCount()
        XCTAssertEqual(after, uploads, "Restoring the exact base needs no synthetic child version")
        try await fixture.sender.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.root.appendingPathComponent("Sender"), services: fixture.services, key: 0x51)
        await reopened.resumeSync()
        let page = try await reopened.page(.init()).entries
        XCTAssertNil(page.first?.syncFiles.first?.transferFailure)
        let content = try await reopened.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = content.items.first?.representations.first else { return XCTFail("Expected restored tree") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL.appendingPathComponent("member")), Data("original tree member".utf8))
    }

    @MainActor
    func testChangingLinkedSourceKeepsItsDeadlineAcrossObservedSavesAndRestart() async throws {
        let changes = OSAllocatedUnfairLock(initialState: (url: Optional<URL>.none, attempts: 0))
        let faults = ClipboardHistoryFaultInjector { point in
            guard point == .syncFileTreeBeforeFreezeVerification else { return false }
            changes.withLock { state in
                guard let url = state.url else { return }
                state.attempts += 1
                try? Data("save during linked freeze \(state.attempts)".utf8).write(to: url)
            }
            return false
        }
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("deep"), withIntermediateDirectories: true)
            try Data("old complete tree".utf8).write(to: root.appendingPathComponent("deep/member"))
        }, senderFault: faults)
        let tags = try await fixture.sender.syncTags()
        let tag = try XCTUnwrap(tags.first)
        let removed = try await fixture.sender.capture(.init(source: .unknown, content: .text("delete during linked instability")))
        _ = try await fixture.sender.apply(.setTags(removed.entryID, [tag.id]))
        await fixture.sender.retrySync()
        await fixture.receiver.retrySync()
        try await fixture.sender.setSyncEnabled(false)
        _ = try await fixture.sender.apply(.delete(removed.entryID))
        let added = try await fixture.sender.capture(.init(source: .unknown, content: .text("upload despite linked instability")))
        _ = try await fixture.sender.apply(.setTags(added.entryID, [tag.id]))
        let member = fixture.original.appendingPathComponent("deep/member")
        changes.withLock { $0.url = member }
        try Data("saved first change".utf8).write(to: member)
        try await fixture.sender.setSyncEnabled(true)
        await fixture.receiver.retrySync()
        let received = try await fixture.receiver.page(.init()).entries
        XCTAssertFalse(received.contains { $0.id == removed.entryID })
        XCTAssertTrue(received.contains { $0.id == added.entryID })
        let local = try await fixture.sender.page(.init()).entries
        XCTAssertEqual(local.first { $0.id == fixture.entryID }?.syncFiles.first?.transferFailure, .sourceChanged)
        XCTAssertEqual(changes.withLock { $0.attempts }, 1)
        for index in 0..<3 {
            try Data("observed saved edit \(index)".utf8).write(to: member)
            try await Task.sleep(for: .milliseconds(450))
            await fixture.sender.resumeSync()
        }
        XCTAssertEqual(changes.withLock { $0.attempts }, 1, "Vnode/subtree hints and changed location revisions must keep one deadline")
        try await fixture.sender.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.root.appendingPathComponent("Sender"), services: fixture.services,
            key: 0x51, faultInjector: faults)
        await reopened.resumeSync()
        XCTAssertEqual(changes.withLock { $0.attempts }, 1, "Location retry must survive restart")
        changes.withLock { $0.url = nil }
        try Data("final stable save".utf8).write(to: member)
        await reopened.retrySync()
        await fixture.receiver.retrySync()
        let content = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = content.items.first?.representations.first else { return XCTFail("Expected complete linked tree") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL.appendingPathComponent("deep/member")), Data("final stable save".utf8))
        let recovered = try await reopened.page(.init()).entries
        XCTAssertNil(recovered.first { $0.id == fixture.entryID }?.syncFiles.first?.transferFailure)
    }

    @MainActor
    func testRecoveredLinkedExchangeClearsEarlierPermissionFailure() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission denial requires an unprivileged test process") }
        for recoverWhileDisabled in [false, true] {
            let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.linkedFileAfterReplacement]))
            let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
            let working = try XCTUnwrap(locations.first)
            let updated = Data("installed before journal recovery".utf8)
            try updated.write(to: fixture.original)
            try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
            let parent = working.url.deletingLastPathComponent()
            XCTAssertEqual(chmod(parent.path, 0o500), 0)
            defer { _ = chmod(parent.path, 0o700) }
            await fixture.receiver.retrySync()
            let denied = try await fixture.receiver.page(.init()).entries
            XCTAssertEqual(denied.first?.syncFiles.first?.transferFailure, .localFileAccessDenied)

            XCTAssertEqual(chmod(parent.path, 0o700), 0)
            await fixture.receiver.retrySync()
            XCTAssertEqual(try Data(contentsOf: working.url), updated,
                "The real exchange must precede the injected journal interruption")
            if recoverWhileDisabled { try await fixture.receiver.setSyncEnabled(false) }
            else { await fixture.receiver.retrySync() }
            let recovered = try await fixture.receiver.page(.init()).entries
            XCTAssertNil(recovered.first?.syncFiles.first?.transferFailure,
                "A completed journal must retire its earlier location retry failure")
            let current = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
            XCTAssertEqual(current.first?.id, working.id)
            XCTAssertNotEqual(current.first?.baseVersionID, working.baseVersionID)
            XCTAssertEqual(try Data(contentsOf: working.url), updated)
        }
    }

    @MainActor
    func testReadOnlyLinkedDestinationDoesNotBlockIndependentSharing() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission denial requires an unprivileged test process") }
        let fixture = try await makeLinkedFixture()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let tags = try await fixture.receiver.syncTags()
        let tag = try XCTUnwrap(tags.first)
        let removed = try await fixture.receiver.capture(.init(source: .unknown, content: .text("remove while linked update waits")))
        _ = try await fixture.receiver.apply(.setTags(removed.entryID, [tag.id]))
        await fixture.receiver.retrySync()
        await fixture.sender.retrySync()
        try await fixture.receiver.setSyncEnabled(false)
        _ = try await fixture.receiver.apply(.delete(removed.entryID))
        let independent = try await fixture.receiver.capture(.init(source: .unknown, content: .text("share while linked update waits")))
        _ = try await fixture.receiver.apply(.setTags(independent.entryID, [tag.id]))

        let updated = Data("remote saved content".utf8)
        try updated.write(to: fixture.original)
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        let parent = working.url.deletingLastPathComponent()
        XCTAssertEqual(chmod(parent.path, 0o500), 0)
        defer { _ = chmod(parent.path, 0o700) }
        try await fixture.receiver.setSyncEnabled(true)
        await fixture.sender.retrySync()
        let sent = try await fixture.sender.page(.init()).entries
        XCTAssertFalse(sent.contains { $0.id == removed.entryID })
        XCTAssertTrue(sent.contains { $0.id == independent.entryID })
        XCTAssertEqual(try Data(contentsOf: working.url), Data("initial linked bytes".utf8))
        let retained = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let reference) = retained.items.first?.representations.first else {
            return XCTFail("The prior complete linked file must remain usable")
        }
        XCTAssertEqual(try Data(contentsOf: reference.currentURL), Data("initial linked bytes".utf8))
        let status = await fixture.receiver.syncStatus()
        XCTAssertEqual(status.phase, .failed(.localFileAccessDenied))
        let pending = try await fixture.receiver.page(.init()).entries
        XCTAssertEqual(pending.first { $0.id == fixture.entryID }?.syncFiles.first?.transferFailure, .localFileAccessDenied)

        XCTAssertEqual(chmod(parent.path, 0o700), 0)
        await fixture.receiver.retrySync()
        XCTAssertEqual(try Data(contentsOf: working.url), updated)
        let current = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(current.first?.id, working.id)
        XCTAssertNotEqual(current.first?.baseVersionID, working.baseVersionID)
        let repaired = try await fixture.receiver.page(.init()).entries
        XCTAssertNil(repaired.first { $0.id == fixture.entryID }?.syncFiles.first?.transferFailure)
    }

    @MainActor
    func testDeletionRevokesReplacementAlreadyWaitingAfterFileVerification() async throws {
        let barrier = LinkedReplacementBarrier()
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .linkedFileBeforeReplacement { barrier.pause() }
            return false
        })
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        try Data("remote update waiting to replace".utf8).write(to: fixture.original)
        try await eventually {
            let locations = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
            return locations.first?.baseVersionID != working.baseVersionID
        }
        await fixture.sender.retrySync()
        let receive = Task { await fixture.receiver.retrySync() }
        try await eventually { barrier.isWaiting }
        let deletion = Task { try await fixture.receiver.apply(.delete(fixture.entryID)) }
        try await eventually { try await fixture.receiver.page(.init()).entries.isEmpty }
        barrier.release()
        _ = try await deletion.value
        await receive.value

        XCTAssertEqual(try Data(contentsOf: working.url), Data("initial linked bytes".utf8),
            "A persisted deletion must revoke the final filesystem mutation")
    }

    @MainActor
    func testDisableRevokesReplacementAlreadyWaitingAfterFileVerification() async throws {
        let barrier = LinkedReplacementBarrier()
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .linkedFileBeforeReplacement { barrier.pause() }
            return false
        })
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        try Data("remote update waiting to replace".utf8).write(to: fixture.original)
        try await eventually {
            let locations = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
            return locations.first?.baseVersionID != working.baseVersionID
        }
        await fixture.sender.retrySync()
        let receive = Task { await fixture.receiver.retrySync() }
        try await eventually { barrier.isWaiting }
        let cancelledBefore = await fixture.cloud.cancellationCount()
        let disable = Task { try await fixture.receiver.setSyncEnabled(false) }
        try await eventually { await fixture.cloud.cancellationCount() > cancelledBefore }
        barrier.release()
        try await disable.value
        await receive.value

        XCTAssertEqual(try Data(contentsOf: working.url), Data("initial linked bytes".utf8),
            "Revoked I/O must not exchange a linked file after verification finishes")
        let status = await fixture.receiver.syncStatus()
        XCTAssertFalse(status.isEnabled)
    }

    @MainActor
    func testExplicitAssociatedLocationPublishesToOriginalAndStableWorkingCopy() async throws {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        let associatedURL = fixture.root.appendingPathComponent("Different local name.txt")
        _ = try await fixture.receiver.exportFiles(fixture.entryID, to: [associatedURL])
        _ = try await fixture.receiver.associateFileLocation(.init(entryID: fixture.entryID, objectID: working.objectID, url: associatedURL))
        let saved = Data("saved from an explicitly associated location".utf8)
        try saved.write(to: associatedURL)

        try await eventually {
            await fixture.sender.retrySync()
            return (try? Data(contentsOf: fixture.original)) == saved && (try? Data(contentsOf: working.url)) == saved
        }

        let page = try await fixture.receiver.page(.init())
        XCTAssertEqual(page.entries.first?.linkedFileLocations.count, 2)
        XCTAssertEqual(page.entries.first?.syncFiles.first?.displayName, "Linked notes.txt")
    }

    @MainActor
    func testSaveDuringRemoteDownloadIsPreservedAsConflict() async throws {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        try Data("remote while downloader waits".utf8).write(to: fixture.original)
        try await eventually {
            let locations = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
            return locations.first?.baseVersionID != working.baseVersionID
        }
        await fixture.sender.retrySync()
        await fixture.cloud.holdNextDownload()
        let download = Task { await fixture.receiver.retrySync() }
        try await eventually { await fixture.cloud.downloadIsHeld() }
        let local = Data("local save during download".utf8)
        try local.write(to: working.url)
        await fixture.cloud.releaseDownload()
        await download.value

        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(locations.first?.state, .conflict)
        XCTAssertEqual(try Data(contentsOf: working.url), local)
    }

    @MainActor
    func testRemoteUpdatePreservesDirtyWorkingFileAndConflictAcrossRestart() async throws {
        let fixture = try await makeLinkedFixture()
        let initialLocations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initialLocations.first)
        try await fixture.receiver.setSyncEnabled(false)
        let dirty = Data("unuploaded working file changes".utf8)
        try dirty.write(to: working.url)
        let remote = Data("new remote version".utf8)
        try remote.write(to: fixture.original)
        try await eventually {
            let locations = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
            return locations.first?.baseVersionID != working.baseVersionID
        }
        await fixture.sender.retrySync()

        try await fixture.receiver.setSyncEnabled(true)

        let conflict = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(conflict.first?.state, .conflict)
        XCTAssertEqual(conflict.first?.baseVersionID, working.baseVersionID)
        XCTAssertEqual(try Data(contentsOf: working.url), dirty)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        let restored = try await reopened.page(.init())
        XCTAssertEqual(restored.entries.first?.linkedFileLocations.first?.state, .conflict)
        XCTAssertEqual(try Data(contentsOf: working.url), dirty)
    }

    @MainActor
    func testInterruptedReplacementAdoptsInstalledVersionAndPreservesLaterSave() async throws {
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.linkedFileAfterReplacement]))
        let initialLocations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initialLocations.first)
        let remote = Data("verified replacement before interruption".utf8)
        try remote.write(to: fixture.original)
        try await eventually {
            await fixture.receiver.retrySync()
            return (try? Data(contentsOf: working.url)) == remote
        }
        try await fixture.receiver.closeStoreForTesting()
        let local = Data("saved after replacement before restart".utf8)
        try local.write(to: working.url)
        await fixture.cloud.failCommits(true)
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)

        await reopened.resumeSync()

        let restored = try await reopened.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(restored.first?.id, working.id)
        XCTAssertNotEqual(restored.first?.baseVersionID, working.baseVersionID)
        XCTAssertTrue(restored.first?.state == .localChanges || restored.first?.state == .pendingUpload)
        XCTAssertEqual(try Data(contentsOf: working.url), local)
    }

    @MainActor
    func testEditingIndependentExportNeverPublishesAFileVersion() async throws {
        let fixture = try await makeLinkedFixture()
        let destination = fixture.root.appendingPathComponent("Independent.txt")
        _ = try await fixture.receiver.exportFiles(fixture.entryID, to: [destination])
        let before = await fixture.cloud.uploadCount()
        try Data("independent changes".utf8).write(to: destination)
        try await Task.sleep(for: .milliseconds(700))
        await fixture.receiver.retrySync()
        await fixture.sender.retrySync()
        let after = await fixture.cloud.uploadCount()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: fixture.original), Data("initial linked bytes".utf8))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertFalse(locations.contains { $0.url == destination })
    }

    @MainActor
    func testSavedChangesTravelBothDirectionsWithoutRecaptureOrUploadLoops() async throws {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        let forward = Data("saved in the original file".utf8)
        try forward.write(to: fixture.original)
        try await eventually {
            await fixture.receiver.retrySync()
            return (try? Data(contentsOf: working.url)) == forward
        }
        let backward = Data("saved in the receiving working copy".utf8)
        try backward.write(to: working.url)
        try await eventually {
            await fixture.sender.retrySync()
            return (try? Data(contentsOf: fixture.original)) == backward
        }
        let count = await fixture.cloud.uploadCount()
        await fixture.sender.retrySync()
        await fixture.receiver.retrySync()
        try await Task.sleep(for: .milliseconds(700))
        let settledCount = await fixture.cloud.uploadCount()
        XCTAssertEqual(settledCount, count, "Applying received bytes must not echo another version")
        let stable = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(stable.first?.id, working.id)
        XCTAssertEqual(stable.first?.url, working.url)
        let content = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = content.items.first?.representations.first else { return XCTFail("Missing linked file") }
        XCTAssertEqual(file.currentURL.resolvingSymlinksInPath(), working.url.resolvingSymlinksInPath())
    }

    @MainActor
    func eventually(_ condition: () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(6)
        repeat {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        XCTFail("Expected linked file update did not arrive", file: file, line: line)
    }

    @MainActor
    func testDisabledLocationDefersObservationAndReconcilesSavedBytesAfterRestart() async throws {
        let fixture = try await makeLinkedFixture()
        await fixture.cloud.failCommits(true)
        try await fixture.sender.setSyncEnabled(false)
        let saved = Data("saved while this device was disabled".utf8)
        try saved.write(to: fixture.original)
        try await Task.sleep(for: .milliseconds(700))
        let disabled = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(disabled.first?.state, .current)
        try await fixture.sender.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.root.appendingPathComponent("Sender"), services: fixture.services, key: 0x51)

        try await reopened.setSyncEnabled(true)

        let restored = try await reopened.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(restored.first?.id, disabled.first?.id)
        XCTAssertTrue(restored.first?.state == .localChanges || restored.first?.state == .pendingUpload)
        XCTAssertEqual(try Data(contentsOf: fixture.original), saved)
    }

    @MainActor
    func testSavedFileChangeIsObservedWithoutRecaptureOrManualRefresh() async throws {
        let fixture = try await makeLinkedFixture()
        await fixture.cloud.failCommits(true)
        let changed = Data("saved after association".utf8)

        try changed.write(to: fixture.original)

        let deadline = Date().addingTimeInterval(5)
        var observed: ClipboardHistoryLinkedFileLocationState?
        repeat {
            observed = try await fixture.sender.linkedFileLocations(for: fixture.entryID).first?.state
            if observed == .localChanges || observed == .pendingUpload { break }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        XCTAssertTrue(observed == .localChanges || observed == .pendingUpload,
            "A real filesystem save must be observed without recapture or manual sync")
        XCTAssertEqual(try Data(contentsOf: fixture.original), changed)
    }

    @MainActor
    func testExplicitAssociationPreservesChosenContentsAndIndependentExportsStayUnlinked() async throws {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        let destination = fixture.root.appendingPathComponent("Independent saved copy.txt")
        _ = try await fixture.receiver.exportFiles(fixture.entryID, to: [destination])
        let afterExport = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(afterExport, initial)
        let chosenBytes = Data("keep the chosen file contents".utf8)
        try chosenBytes.write(to: destination)
        try await fixture.receiver.setSyncEnabled(false)

        let associated = try await fixture.receiver.associateFileLocation(.init(
            entryID: fixture.entryID, objectID: working.objectID, url: destination))

        XCTAssertEqual(associated.kind, .associated)
        XCTAssertEqual(associated.state, .localChanges)
        XCTAssertEqual(associated.baseVersionID, working.baseVersionID)
        XCTAssertEqual(try Data(contentsOf: destination), chosenBytes)
        XCTAssertEqual(try Data(contentsOf: working.url), Data("initial linked bytes".utf8))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(locations.count, 2)
        let page = try await fixture.receiver.page(.init())
        XCTAssertEqual(page.entries.first?.linkedFileLocations, locations,
            "History surfaces must expose the same persisted associations and dirty state")
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        let restored = try await reopened.linkedFileLocations(for: fixture.entryID)
        XCTAssertTrue(restored.contains(associated))
    }

    @MainActor
    func testOriginalAndManagedWorkingLocationsKeepTheirIdentityAfterRestart() async throws {
        let fixture = try await makeLinkedFixture()
        let originals = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        let working = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)

        XCTAssertEqual(originals.count, 1)
        XCTAssertEqual(originals.first?.kind, .original)
        XCTAssertEqual(originals.first?.url.standardizedFileURL, fixture.original.standardizedFileURL)
        XCTAssertEqual(working.count, 1)
        XCTAssertEqual(working.first?.kind, .workingCopy)
        XCTAssertEqual(working.first?.objectID, originals.first?.objectID)
        let location = try XCTUnwrap(working.first)
        XCTAssertNotEqual(location.url, fixture.original)
        XCTAssertEqual(try Data(contentsOf: location.url), Data("initial linked bytes".utf8))
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        let restored = try await reopened.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(restored, working)
    }

    @MainActor
    func makeLinkedFixture(receiverFault: ClipboardHistoryFaultInjector = .init(), initialBytes: Data = Data("initial linked bytes".utf8),
        prepareSource: ((URL) throws -> Void)? = nil, senderFault: ClipboardHistoryFaultInjector = .init(),
        sourceName: String = "Linked notes.txt") async throws -> (
        sender: ClipboardHistoryModule, receiver: ClipboardHistoryModule,
        entryID: ClipboardHistoryEntryID, original: URL, root: URL, receiverRoot: URL,
        services: ClipboardSyncServices, cloud: LinkedFileCloud
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linked-files-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent(sourceName)
        try initialBytes.write(to: original)
        try prepareSource?(original)
        let cloud = LinkedFileCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: LinkedFileKeys(), pollingInterval: nil)
        let sender = makeLinkedModule(root: root.appendingPathComponent("Sender"), services: services, key: 0x51, faultInjector: senderFault)
        let receiverRoot = root.appendingPathComponent("Receiver")
        let receiver = makeLinkedModule(root: receiverRoot, services: services, key: 0x52, faultInjector: receiverFault)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.linked-files.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(original.absoluteString, forType: .fileURL)
        guard case .captured(let capture) = try await sender.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let tag = try await sender.createTagDefinition(named: "Linked", assigningTo: capture.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        if initialBytes.count > 5 * 1_024 * 1_024 {
            let page = try await receiver.page(.init())
            if let file = page.entries.first?.syncFiles.first {
                try await receiver.requestSyncFileDownload(entryID: capture.entryID, objectID: file.id, versionID: file.versionID)
            }
        }
        return (sender, receiver, capture.entryID, original, root, receiverRoot, services, cloud)
    }

    func makeLinkedModule(root: URL, services: ClipboardSyncServices, key: UInt8,
        faultInjector: ClipboardHistoryFaultInjector = .init()) -> ClipboardHistoryModule {
        trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root,
            keyStore: LinkedFileLocalKey(byte: key), faultInjector: faultInjector, syncServices: services))
    }
}

private struct LinkedFileLocalKey: ClipboardHistoryMasterKeyStoring {
    let byte: UInt8
    func load() -> ClipboardHistoryMasterKeyResult { .key(Data(repeating: byte, count: 32)) }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

actor LinkedFileKeys: ClipboardSyncKeyStoring {
    private var keys: [UUID: Data] = [:]
    func load(account: ClipboardSyncAccount, keyID: UUID) -> Data? { keys[keyID] }
    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) throws -> Data {
        if let current = keys[keyID] {
            guard current == key else { throw ClipboardSyncServiceError.corruptData }
            return current
        }
        keys[keyID] = key
        return key
    }
}

actor LinkedFileCloud: ClipboardSyncTransport {
    private var identity = ClipboardSyncAccount(container: "test", environment: "test", owner: "linked-file-user")
    private var currentControl: ClipboardSyncControl?
    private var uploads: [ClipboardSyncUpload] = []
    private var purgedRecords: Set<String> = []
    private var commitsFail = false
    private var heldSegmentIndex: Int?
    private var heldDownload: CheckedContinuation<Void, Never>?
    private var cancellations = 0
    private var fileDownloads: [UUID] = []
    private var partialFileRecords: [String: ClipboardSyncRemoteRecord] = [:]
    func partialFileRecordIDs() -> Set<String> { Set(partialFileRecords.keys) }
    func downloadedFileVersions() -> [UUID] { fileDownloads }
    func uploadedRecords() -> [ClipboardSyncUpload] { uploads }
    func visibleRecords() -> [ClipboardSyncRemoteRecord] {
        var seen: Set<String> = []
        return uploads.filter { !purgedRecords.contains($0.record.recordID) && seen.insert($0.record.recordID).inserted }.map(\.record)
    }
    func replayLateRecords(_ records: [ClipboardSyncUpload]) {
        for record in records { purgedRecords.remove(record.record.recordID) }
        uploads.append(contentsOf: records)
        if let currentControl { self.currentControl = advanced(currentControl) }
    }
    func moveLastTwoRecordsToFront() {
        guard uploads.count >= 2 else { return }
        let tail = Array(uploads.suffix(2))
        uploads.removeLast(2)
        uploads.insert(contentsOf: tail, at: 0)
    }
    func failCommits(_ fail: Bool) { commitsFail = fail }
    func holdNextDownload(at index: Int = 0) { heldSegmentIndex = index }
    func switchAccount(to owner: String) {
        identity = .init(container: identity.container, environment: identity.environment, owner: owner)
        currentControl = nil
    }
    func downloadIsHeld() -> Bool { heldDownload != nil }
    func releaseDownload() { heldDownload?.resume(); heldDownload = nil }

    func account() -> ClipboardSyncAccount { identity }
    func control(for account: ClipboardSyncAccount) -> ClipboardSyncControl? { currentControl }
    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) -> ClipboardSyncControl {
        if let currentControl { return currentControl }
        let created = advanced(candidate)
        currentControl = created
        return created
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) -> ClipboardSyncChanges {
        let offset = cursor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        return .init(records: uploads.dropFirst(offset).filter { !purgedRecords.contains($0.record.recordID) }.map(\.record), cursor: Data(String(uploads.count).utf8), hasMore: false)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) throws -> [Data] {
        guard !purgedRecords.contains(record.recordID), let content = uploads.first(where: { $0.record == record }) else { throw ClipboardSyncServiceError.recordUnavailable }
        return content.chunks
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl) throws -> ClipboardSyncControl {
        if commitsFail { throw ClipboardSyncServiceError.network(retryAfter: nil) }
        guard let currentControl, account == identity, currentControl.epoch == control.epoch else {
            throw ClipboardSyncServiceError.accountChanged
        }
        if let current = uploads.first(where: { $0.record.recordID == upload.record.recordID }) {
            guard current == upload else { throw ClipboardSyncServiceError.corruptData }
            if purgedRecords.contains(upload.record.recordID) {
                guard currentControl.serverToken == control.serverToken else { throw ClipboardSyncServiceError.conflict }
                purgedRecords.remove(upload.record.recordID)
                uploads.append(upload)
                let updated = advanced(currentControl)
                self.currentControl = updated
                return updated
            }
            return currentControl
        }
        guard currentControl.serverToken == control.serverToken else { throw ClipboardSyncServiceError.conflict }
        uploads.append(upload)
        let updated = advanced(currentControl)
        self.currentControl = updated
        return updated
    }
    func cancel() { cancellations += 1 }
    func purge(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount,
        control: ClipboardSyncControl) throws -> ClipboardSyncControl {
        guard let currentControl, account == identity, currentControl.epoch == control.epoch else { throw ClipboardSyncServiceError.accountChanged }
        guard currentControl.serverToken == control.serverToken else { throw ClipboardSyncServiceError.conflict }
        purgedRecords.insert(record.recordID)
        partialFileRecords.removeValue(forKey: record.recordID)
        let updated = advanced(currentControl)
        self.currentControl = updated
        return updated
    }
    func transition(_ control: ClipboardSyncControl, to phase: String, epoch: UUID,
        for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl {
        guard account == identity else { throw ClipboardSyncServiceError.accountChanged }
        guard currentControl == control else { throw ClipboardSyncServiceError.conflict }
        let result = advanced(.init(accountID: control.accountID, keyID: control.keyID,
            keyCheck: control.keyCheck, epoch: epoch, phase: phase, serverToken: control.serverToken))
        currentControl = result
        return result
    }
    func clearPage(for account: ClipboardSyncAccount, control: ClipboardSyncControl,
        cursor: Data?) async throws -> ClipboardSyncCleanupPage {
        guard account == identity else { throw ClipboardSyncServiceError.accountChanged }
        guard currentControl == control, control.phase == "resetting" else { throw ClipboardSyncServiceError.conflict }
        let records = visibleRecords()
        purgedRecords.formUnion(records.map(\.recordID))
        partialFileRecords.removeAll()
        let result = advanced(control)
        currentControl = result
        return .init(control: result, cursor: nil, deletedRecordCount: records.count, hasMore: false)
    }
    func cancellationCount() -> Int { cancellations }
    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount,
        control: ClipboardSyncControl, progress: @Sendable (Int64) async throws -> Void) async throws -> ClipboardSyncControl {
        partialFileRecords[upload.record.recordID] = upload.record
        var chunks: [Data] = []
        var bytes: Int64 = 0
        for index in 0..<upload.record.chunkCount {
            let chunk = try ClipboardSyncFileTransfer.readSegment(in: upload.directory, index: index)
            chunks.append(chunk)
            bytes += Int64(chunk.count)
            try await progress(bytes)
        }
        let result = try commit(.init(record: upload.record, chunks: chunks), for: account, control: control)
        partialFileRecords.removeValue(forKey: upload.record.recordID)
        return result
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) async throws -> Data {
        fileDownloads.append(record.operationID)
        let chunks = try download(record, for: account)
        guard chunks.indices.contains(index) else { throw ClipboardSyncServiceError.corruptData }
        let response = chunks[index]
        if heldSegmentIndex == index {
            heldSegmentIndex = nil
            await withCheckedContinuation { heldDownload = $0 }
        }
        // Simulate an already-read successful provider response arriving after
        // cancellation, account replacement, or collection retirement.
        return response
    }
    func uploadCount() -> Int { uploads.count }
    private func advanced(_ control: ClipboardSyncControl) -> ClipboardSyncControl {
        .init(accountID: control.accountID, keyID: control.keyID, keyCheck: control.keyCheck,
            epoch: control.epoch, phase: control.phase, serverToken: Data(UUID().uuidString.utf8))
    }
}

/// Blocks only the detached filesystem boundary, never the module actor.
final class LinkedReplacementBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var waiting = false
    var isWaiting: Bool { lock.withLock { waiting } }
    func pause() {
        lock.withLock { waiting = true }
        _ = semaphore.wait(timeout: .now() + 10)
    }
    func release() { semaphore.signal() }
}
