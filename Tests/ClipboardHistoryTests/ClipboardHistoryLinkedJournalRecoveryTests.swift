import Darwin
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testMovedCandidateExposesReassociationWithoutChangingSavedBytes() async throws {
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.linkedFileBeforeReplacement]))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let remote = Data("prepared remote bytes kept at another path".utf8)
        try remote.write(to: fixture.original)
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        await fixture.receiver.retrySync()
        let candidate = try XCTUnwrap(try journalOutputs(beside: working.url).first)
        try await fixture.receiver.closeStoreForTesting()
        let moved = fixture.root.appendingPathComponent("User retained candidate.txt")
        try FileManager.default.moveItem(at: candidate, to: moved)
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        let visible = try await reopened.linkedFileLocations(for: fixture.entryID)
        let current = try XCTUnwrap(visible.first)
        XCTAssertEqual(current.state, .unavailable, "The existing Host Retry/Reassociate actions must be reachable for unresolved journal ownership")
        let materialized = try await reopened.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("Missing saved working file") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL), Data("initial linked bytes".utf8))
        try await reopened.setSyncEnabled(false)
        _ = try await reopened.reassociateFileLocation(.init(
            selection: .init(entryID: fixture.entryID, locationID: current.id, expectedRevision: current.revision), url: working.url))
        XCTAssertEqual(try Data(contentsOf: working.url), Data("initial linked bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: moved), remote)
        let status = await reopened.syncStatus()
        XCTAssertFalse(status.isEnabled)
        try await reopened.setSyncEnabled(true)
        XCTAssertEqual(try Data(contentsOf: working.url), remote)
        XCTAssertEqual(try Data(contentsOf: moved), remote)
    }

    @MainActor
    func testAtomicSaveAfterSwapRequiresExplicitReassociationAndKeepsDisplacedBytes() async throws {
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.linkedFileAfterReplacement]))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let remote = Data("installed remote version".utf8)
        try remote.write(to: fixture.original)
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        await fixture.receiver.retrySync()
        XCTAssertEqual(try Data(contentsOf: working.url), remote)
        let displaced = try XCTUnwrap(try journalOutputs(beside: working.url).first)
        let installedInode = try journalInode(working.url)
        let edit = Data("atomic editor save after interrupted exchange".utf8)
        try edit.write(to: working.url, options: .atomic)
        XCTAssertNotEqual(try journalInode(working.url), installedInode)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        let uncertain = try await reopened.linkedFileLocations(for: fixture.entryID)
        let current = try XCTUnwrap(uncertain.first)
        XCTAssertEqual(current.baseVersionID, working.baseVersionID, "An unknown replacement does not prove which version was installed")
        XCTAssertEqual(try Data(contentsOf: working.url), edit)
        try await reopened.setSyncEnabled(false)
        let reassociated = try await reopened.reassociateFileLocation(.init(
            selection: .init(entryID: fixture.entryID, locationID: current.id, expectedRevision: current.revision), url: working.url))
        XCTAssertEqual(reassociated.state, .localChanges)
        XCTAssertEqual(reassociated.baseVersionID, working.baseVersionID)
        XCTAssertEqual(try Data(contentsOf: working.url), edit)
        XCTAssertEqual(try Data(contentsOf: displaced), Data("initial linked bytes".utf8))
        try await reopened.closeStoreForTesting()
        let again = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        let retained = try await again.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(retained.first?.url, working.url)
        XCTAssertEqual(retained.first?.state, .localChanges)
        XCTAssertEqual(try Data(contentsOf: displaced), Data("initial linked bytes".utf8))
    }

    @MainActor
    func testReassociationRevokesAnExchangeWaitingAtItsFinalGate() async throws {
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .linkedFileBeforeReplacement { barrier.pause() }
            return false
        })
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let remote = Data("remote version at final exchange gate".utf8)
        try remote.write(to: fixture.original)
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        let receive = Task { await fixture.receiver.retrySync() }
        try await eventually { barrier.isWaiting }
        let displayed = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let current = try XCTUnwrap(displayed.first)
        let chosen = fixture.root.appendingPathComponent("Explicitly chosen.txt")
        let bytes = Data("explicit working file chosen while exchange waits".utf8)
        try bytes.write(to: chosen)
        let reassociate = Task { try await fixture.receiver.reassociateFileLocation(.init(
            selection: .init(entryID: fixture.entryID, locationID: current.id, expectedRevision: current.revision), url: chosen)) }
        try await eventually {
            let now = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
            return now.first?.url == chosen && now.first?.revision != current.revision
        }
        barrier.release()
        await receive.value
        let result = try await reassociate.value
        XCTAssertEqual(result.url, chosen)
        XCTAssertEqual(try Data(contentsOf: chosen), bytes)
        XCTAssertEqual(try Data(contentsOf: working.url), Data("initial linked bytes".utf8),
            "The old worker must lose its serialized revision admission before rename")
        let candidates = try journalOutputs(beside: working.url)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(candidates.first)), remote)
    }

    @MainActor
    func testEditedPreparedCandidateIsRetainedInsteadOfReusedOrDeleted() async throws {
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.linkedFileBeforeReplacement]))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let remote = Data("authenticated remote version".utf8)
        try remote.write(to: fixture.original)
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        await fixture.receiver.retrySync()
        let candidate = try XCTUnwrap(try journalOutputs(beside: working.url).first)
        try await fixture.receiver.closeStoreForTesting()
        let edited = Data("user edited the visible prepared candidate".utf8)
        try edited.write(to: candidate)
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        XCTAssertEqual(try Data(contentsOf: working.url), remote)
        XCTAssertEqual(try Data(contentsOf: candidate), edited)
        let retained = try journalOutputs(beside: working.url)
        XCTAssertEqual(retained.count, 2, "Keep the edited candidate and the genuinely displaced original")
        await reopened.retrySync()
        XCTAssertEqual(Set(try journalOutputs(beside: working.url)), Set(retained))
        XCTAssertTrue(retained.contains { (try? Data(contentsOf: $0)) == Data("initial linked bytes".utf8) })
    }

    @MainActor
    func testPendingCandidateRetiresWhenANewerSelectedVersionArrives() async throws {
        let fixture = try await makeLinkedFixture()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        XCTAssertEqual(chflags(working.url.path, UInt32(UF_IMMUTABLE)), 0)
        addTeardownBlock { _ = chflags(working.url.path, 0) }
        let earlier = Data("first prepared remote version".utf8)
        try earlier.write(to: fixture.original)
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        await fixture.receiver.retrySync()
        let candidate = try XCTUnwrap(try journalOutputs(beside: working.url).first)
        let latest = Data("newer selected version replaces the old intent".utf8)
        try latest.write(to: fixture.original)
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        await fixture.receiver.retrySync()
        XCTAssertEqual(chflags(working.url.path, 0), 0)
        await fixture.receiver.retrySync()
        XCTAssertEqual(try Data(contentsOf: working.url), latest,
            "A proven no-swap old intent must not block the normal update to the new selected version")
        XCTAssertEqual(try Data(contentsOf: candidate), earlier)
        let retained = try journalOutputs(beside: working.url)
        XCTAssertEqual(retained.count, 2, "Only the retired candidate and genuinely displaced original remain")
        await fixture.receiver.retrySync()
        XCTAssertEqual(Set(try journalOutputs(beside: working.url)), Set(retained))
    }

    @MainActor
    func testLockedApplicationReusesCandidateOnlyAfterAnotherExplicitApply() async throws {
        let fixture = try await makeLinkedFixture(prepareSource: { url in
            try FileManager.default.removeItem(at: url)
            _ = try ClipboardApplicationTestFixture.create(at: url,
                bundleIdentifier: "dev.bybee.AnyDoor.tests.journal-retry.\(UUID())", resource: "old package", signed: false)
        }, sourceName: "Journal Retry.app")
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let relative = "Contents/Resources/Resource.txt"
        let remote = Data("verified application update".utf8)
        try remote.write(to: fixture.original.appendingPathComponent(relative))
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        XCTAssertEqual(chflags(working.url.path, UInt32(UF_IMMUTABLE)), 0)
        addTeardownBlock { _ = chflags(working.url.path, 0) }
        for _ in 0..<2 {
            let current = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
            let location = try XCTUnwrap(current.first)
            let plan = try await fixture.receiver.applicationUpdatePlan(.init(entryID: fixture.entryID,
                locationID: location.id, expectedRevision: location.revision))
            XCTAssertEqual(plan.state, .ready, "A proven unchanged no-swap candidate can be retried with fresh explicit consent")
            do { try await fixture.receiver.applyApplicationUpdate(plan); XCTFail("The native immutable root must refuse exchange") }
            catch {}
            await fixture.receiver.retrySync()
        }
        let candidates = try journalOutputs(beside: working.url)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(chflags(working.url.path, 0), 0)
        await fixture.receiver.retrySync()
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent(relative)), Data("old package".utf8),
            "Unlock and ordinary Retry do not constitute a fresh Apply Update action")
        let current = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let location = try XCTUnwrap(current.first)
        let plan = try await fixture.receiver.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: location.id, expectedRevision: location.revision))
        XCTAssertEqual(plan.state, .ready)
        try await fixture.receiver.applyApplicationUpdate(plan)
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent(relative)), remote)
        XCTAssertEqual(Set(try journalOutputs(beside: working.url)), Set(candidates))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(candidates.first).appendingPathComponent(relative)), Data("old package".utf8))
    }

    @MainActor
    func testLockedDirectoryRetriesReuseOnePreparedReplacementAcrossRestart() async throws {
        let fixture = try await makeLinkedFixture(prepareSource: { url in
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("original directory member".utf8).write(to: url.appendingPathComponent("member"))
        }, sourceName: "Linked folder")
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        XCTAssertEqual(chflags(working.url.path, UInt32(UF_IMMUTABLE)), 0)
        addTeardownBlock { _ = chflags(working.url.path, 0) }
        let remote = Data("remote directory member waiting for unlock".utf8)
        try remote.write(to: fixture.original.appendingPathComponent("member"))
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        await fixture.receiver.retrySync()
        let prepared = try journalOutputs(beside: working.url)
        XCTAssertEqual(prepared.count, 1)
        let candidate = try XCTUnwrap(prepared.first)
        for _ in 0..<4 { await fixture.receiver.retrySync() }
        XCTAssertEqual(Set(try journalOutputs(beside: working.url)), Set(prepared),
            "A persistent native EPERM must reuse its exact prepared tree, not allocate a tree every retry")
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("member")), Data("original directory member".utf8))
        XCTAssertEqual(try Data(contentsOf: candidate.appendingPathComponent("member")), remote)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        await reopened.retrySync()
        XCTAssertEqual(Set(try journalOutputs(beside: working.url)), Set(prepared))
        XCTAssertEqual(chflags(working.url.path, 0), 0)
        await reopened.retrySync()
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("member")), remote)
        XCTAssertEqual(Set(try journalOutputs(beside: working.url)), Set(prepared))
        XCTAssertEqual(try Data(contentsOf: candidate.appendingPathComponent("member")), Data("original directory member".utf8),
            "After the real swap the same name owns displaced user bytes and must be kept")
    }

    @MainActor
    func testInterruptedBeforeSwapAllowsExplicitReassociationAfterInPlaceSave() async throws {
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.linkedFileBeforeReplacement]))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let remote = Data("remote version waiting for exchange".utf8)
        try remote.write(to: fixture.original)
        try await fixture.sender.refreshSyncFile(entryID: fixture.entryID, objectID: working.objectID)
        await fixture.receiver.retrySync()
        XCTAssertEqual(try Data(contentsOf: working.url), Data("initial linked bytes".utf8))
        let candidates = try journalOutputs(beside: working.url)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(candidates.first)), remote)
        try await fixture.receiver.closeStoreForTesting()

        let before = try journalInode(working.url)
        let local = Data("user saved in place after the interrupted exchange".utf8)
        try local.write(to: working.url)
        XCTAssertEqual(try journalInode(working.url), before)
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        try await reopened.setSyncEnabled(false)
        let restored = try await reopened.linkedFileLocations(for: fixture.entryID)
        let current = try XCTUnwrap(restored.first)
        let reassociated = try await reopened.reassociateFileLocation(.init(
            selection: .init(entryID: fixture.entryID, locationID: current.id, expectedRevision: current.revision),
            url: working.url))

        XCTAssertEqual(reassociated.id, working.id)
        XCTAssertEqual(reassociated.state, .localChanges)
        XCTAssertEqual(try Data(contentsOf: working.url), local)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(candidates.first)), remote)
        let status = await reopened.syncStatus()
        XCTAssertFalse(status.isEnabled)
    }

    private func journalOutputs(beside url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + " (AnyDoor update ") }
    }

    private func journalInode(_ url: URL) throws -> ino_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw CocoaError(.fileReadUnknown) }
        return status.st_ino
    }
}
