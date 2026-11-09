import XCTest
import SwiftData
import PluginInterface
@testable import AnyDoor
@testable import HostsPlugin

/// Test writer whose next write can be suspended until the test releases it,
/// so a second mutation can join the coalesced applyTask mid-write.
private final class GatedHostsWriter: HostsWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastWritten: String?
    private var _gateNext = false
    private var _isSuspended = false
    private var continuation: CheckedContinuation<Void, Error>?

    var lastWritten: String? { lock.withLock { _lastWritten } }
    var isSuspended: Bool { lock.withLock { _isSuspended } }

    func gateNextWrite() { lock.withLock { _gateNext = true } }
    func replaceLiveContents(_ content: String) { lock.withLock { _lastWritten = content } }

    /// Resume the suspended write, optionally failing it.
    func release(throwing error: Error? = nil) {
        let cont = lock.withLock {
            let c = continuation
            continuation = nil
            _isSuspended = false
            return c
        }
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
    }

    func write(_ content: String, replacing expectedContent: String) async throws {
        let gated = lock.withLock {
            let g = _gateNext
            _gateNext = false
            return g
        }
        if gated {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    continuation = c
                    _isSuspended = true
                }
            }
        }
        try lock.withLock {
            if let live = _lastWritten, live != expectedContent { throw HostsWriterError.liveChanged }
            _lastWritten = content
        }
    }
}

@MainActor
final class HostsManagerTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
        return try ModelContainer(for: HostProfile.self, configurations: config)
    }

    private func makeManager(writer: HostsWriter,
                             live: @escaping () -> String = { "127.0.0.1 localhost\n" },
                             debounceInterval: Duration = .milliseconds(150),
                             host: PluginHostContext? = nil) throws
        -> (HostsManager, ModelContainer) {
        let container = try makeContainer()
        let mgr = HostsManager(writer: writer,
                               backup: HostsBackupStore(backupDirectory: FileManager.default.temporaryDirectory
                                   .appendingPathComponent(UUID().uuidString), readLiveHosts: live),
                               readLiveHosts: live,
                               debounceInterval: debounceInterval,
                               host: host)
        mgr.bootstrap(modelContainer: container)
        return (mgr, container)
    }

    func test_recoversLiveProfilesWithoutWritingAndPreservesOtherEntriesOnToggle() async throws {
        let original = """
        127.0.0.1 localhost
        # Keep this system comment
        192.0.2.10 local.example alias.example

        \(HostsFile.beginMarker)
        # --- Work ---
        # Keep this profile comment
        198.51.100.7 work.example
        # --- IPv6 ---
        2001:db8::4 ipv6.example another.example # Keep this inline comment
        \(HostsFile.endMarker)

        203.0.113.9 tail.example

        """
        let writer = MockHostsWriter()
        let (manager, container) = try makeManager(
            writer: writer, live: { writer.lastWritten ?? original }
        )

        XCTAssertEqual(manager.profiles.map(\.name), ["Work", "IPv6"])
        XCTAssertTrue(manager.profiles.allSatisfy(\.isActive))
        XCTAssertTrue(manager.systemHosts.contains("192.0.2.10 local.example alias.example"))
        XCTAssertTrue(manager.systemHosts.contains("203.0.113.9 tail.example"))
        XCTAssertEqual(writer.writeCount, 0, "Reading must not rewrite the live file")
        let ids = manager.profiles.map(\.id)
        manager.reload()
        manager.bootstrap(modelContainer: container)
        XCTAssertEqual(manager.profiles.map(\.id), ids, "Refresh and relaunch must not duplicate recovery")

        let work = try XCTUnwrap(manager.profiles.first { $0.name == "Work" })
        await manager.setActive(work, false)
        let written = try XCTUnwrap(writer.lastWritten)
        XCTAssertFalse(written.contains("198.51.100.7 work.example"))
        XCTAssertTrue(written.contains("2001:db8::4 ipv6.example another.example # Keep this inline comment"))
        XCTAssertTrue(written.contains("# Keep this system comment\n192.0.2.10 local.example alias.example"))
        XCTAssertTrue(written.contains("203.0.113.9 tail.example"))
        XCTAssertEqual(manager.profiles.count, 2)
        XCTAssertFalse(work.isActive)
    }

    func test_externalChangeAfterRefreshAbortsWriteAndRecoversNewEntries() async throws {
        let writer = MockHostsWriter()
        var live = "127.0.0.1 localhost\n"
        let (manager, _) = try makeManager(writer: writer, live: { live })
        manager.createProfile(name: "Local", content: "192.0.2.1 local.example")
        let local = try XCTUnwrap(manager.profiles.first)
        live += "\(HostsFile.beginMarker)\n# --- Other app ---\n198.51.100.8 external.example\n\(HostsFile.endMarker)\n"

        await manager.setActive(local, true)

        XCTAssertEqual(writer.writeCount, 0, "A stale list must never replace a newer hosts file")
        XCTAssertFalse(local.isActive)
        XCTAssertNotNil(manager.lastError)
        XCTAssertTrue(manager.profiles.contains { $0.content.contains("198.51.100.8 external.example") && $0.isActive })
    }

    func test_recoveryRetainsSavedContentAndLiveOrderIncludingUnnamedEntries() async throws {
        let writer = MockHostsWriter()
        var live = "127.0.0.1 localhost\n"
        let (manager, _) = try makeManager(writer: writer, live: { writer.lastWritten ?? live })
        manager.createProfile(name: "First", content: "192.0.2.1 shared.example")
        manager.createProfile(name: "Second", content: "192.0.2.2 shared.example")
        manager.createProfile(name: "Changed", content: "192.0.2.3 old.example")
        let savedIDs = manager.profiles.map(\.id)
        live += """
        \(HostsFile.beginMarker)
        # An unnamed legacy entry
        2001:db8::9 legacy.example
        # --- Second ---
        192.0.2.2 shared.example
        # --- First ---
        192.0.2.1 shared.example
        # --- Changed ---
        198.51.100.5 new.example
        # --- Changed ---
        198.51.100.6 another.example
        \(HostsFile.endMarker)

        """
        manager.reload()
        let old = try XCTUnwrap(manager.profiles.first { $0.id == savedIDs[2] })
        XCTAssertFalse(old.isActive)
        XCTAssertEqual(old.content, "192.0.2.3 old.example", "Recovery must never replace a saved body")
        XCTAssertEqual(manager.profiles.count, 6)
        XCTAssertEqual(manager.profiles.first { $0.name == "First" }?.id, savedIDs[0])
        XCTAssertEqual(manager.profiles.first { $0.name == "Second" }?.id, savedIDs[1])
        manager.reload()
        XCTAssertEqual(manager.profiles.count, 6)
        XCTAssertEqual(writer.writeCount, 0)

        await manager.setActive(old, true)
        let written = try XCTUnwrap(writer.lastWritten)
        XCTAssertTrue(written.contains("# An unnamed legacy entry\n2001:db8::9 legacy.example"))
        XCTAssertTrue(written.contains("198.51.100.5 new.example"))
        XCTAssertTrue(written.contains("198.51.100.6 another.example"))
        XCTAssertTrue(written.contains("192.0.2.3 old.example"))
        let second = try XCTUnwrap(written.range(of: "192.0.2.2 shared.example"))
        let first = try XCTUnwrap(written.range(of: "192.0.2.1 shared.example"))
        XCTAssertLessThan(second.lowerBound, first.lowerBound, "Live mapping precedence must be preserved")
    }

    func test_ambiguousManagedBlocksRemainVisibleAndCannotBeOverwritten() async throws {
        let block = "\(HostsFile.beginMarker)\n# --- Live ---\n192.0.2.7 live.example\n\(HostsFile.endMarker)\n"
        for live in [block + block, "\(HostsFile.beginMarker)\n192.0.2.7 live.example\n", "\(HostsFile.endMarker)\n"] {
            let writer = MockHostsWriter()
            let (manager, _) = try makeManager(writer: writer, live: { live }, debounceInterval: .milliseconds(1))
            XCTAssertEqual(manager.systemHosts, live)
            manager.createProfile(name: "New", content: "198.51.100.1 new.example")
            await manager.setActive(try XCTUnwrap(manager.profiles.first), true)
            await manager.updateSystemHosts("127.0.0.1 localhost\n", replacing: live)
            XCTAssertEqual(writer.writeCount, 0)
            XCTAssertEqual(manager.systemHosts, live)
            XCTAssertNotNil(manager.lastError)
        }
    }

    func test_systemDraftCannotOverwriteExternalChangesEvenAfterARefresh() async throws {
        let writer = MockHostsWriter()
        var live = "127.0.0.1 localhost\n"
        let (manager, _) = try makeManager(writer: writer, live: { live })
        let original = manager.systemHosts
        live += "198.51.100.99 external.example\n"
        manager.reload()
        await manager.updateSystemHosts(original + "192.0.2.9 draft.example\n", replacing: original)
        XCTAssertEqual(writer.writeCount, 0)
        XCTAssertEqual(manager.systemHosts, live)
        XCTAssertNotNil(manager.lastError)
    }

    func test_externalChangeDuringAuthorizationAbortsAndRefreshDoesNotUndoPendingToggle() async throws {
        let writer = GatedHostsWriter()
        let (manager, _) = try makeManager(
            writer: writer, live: { writer.lastWritten ?? "127.0.0.1 localhost\n" },
            debounceInterval: .milliseconds(1)
        )
        manager.createProfile(name: "New", content: "192.0.2.9 new.example")
        let profile = try XCTUnwrap(manager.profiles.first)
        writer.gateNextWrite()
        let activation = Task { @MainActor in await manager.setActive(profile, true) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !writer.isSuspended, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard writer.isSuspended else {
            await activation.value
            return XCTFail("Writer did not reach authorization")
        }
        manager.reload()
        XCTAssertTrue(profile.isActive)
        let external = "127.0.0.1 localhost\n198.51.100.99 external.example\n"
        writer.replaceLiveContents(external)
        writer.release()
        await activation.value
        XCTAssertEqual(writer.lastWritten, external)
        XCTAssertEqual(manager.systemHosts, external)
        XCTAssertFalse(profile.isActive)
        XCTAssertEqual(manager.lastError, HostsPlugin.L10n.Key.hostsErrorLiveChanged.rawValue)
    }

    func test_createProfile_persists_noSystemWrite() throws {
        let mock = MockHostsWriter()
        let (mgr, _) = try makeManager(writer: mock)
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev")
        XCTAssertEqual(mgr.profiles.count, 1)
        XCTAssertEqual(mock.writeCount, 0)  // inactive => no write
    }

    func test_duplicateProfileCopiesContentAsInactiveProfileWithoutSystemWrite() throws {
        let host = PluginHostContext(
            services: CorePluginHost(modelContainer: try makeContainer())
        )
        let previous = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .en
        defer { LocalizationManager.shared.preference = previous }

        let mock = MockHostsWriter()
        let (mgr, _) = try makeManager(writer: mock, host: host)
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev")
        mgr.profiles[0].isActive = true

        let duplicate = mgr.duplicateProfile(mgr.profiles[0])

        XCTAssertEqual(mgr.profiles.map(\.name), ["Dev", "Dev Copy"])
        XCTAssertEqual(duplicate?.name, "Dev Copy")
        XCTAssertEqual(mgr.profiles[1].content, "1.2.3.4 dev")
        XCTAssertFalse(mgr.profiles[1].isActive)
        XCTAssertEqual(mock.writeCount, 0)
    }

    func test_activateProfile_composesAndWritesActiveContent() async throws {
        let mock = MockHostsWriter()
        let (mgr, _) = try makeManager(writer: mock, live: { mock.lastWritten ?? "127.0.0.1 localhost\n" })
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev.example.com")
        let profile = mgr.profiles[0]
        await mgr.setActive(profile, true)
        XCTAssertTrue(mgr.profiles[0].isActive)
        let written = try XCTUnwrap(mock.lastWritten)
        XCTAssertTrue(written.contains("127.0.0.1 localhost"))      // prefix preserved
        XCTAssertTrue(written.contains("1.2.3.4 dev.example.com"))  // active content
        XCTAssertTrue(written.contains(HostsFile.beginMarker))
    }

    func test_writeFailure_rollsBack_persistsNothing() async throws {
        let mock = MockHostsWriter()
        let (mgr, container) = try makeManager(writer: mock)
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev")
        mock.errorToThrow = HostsWriterError.writeFailed("denied")
        let profile = mgr.profiles[0]
        await mgr.setActive(profile, true)
        XCTAssertFalse(mgr.profiles[0].isActive)
        let rows = try container.mainContext.fetch(FetchDescriptor<HostProfile>())
        XCTAssertFalse(rows[0].isActive)
    }

    func test_deactivate_removesManagedBlock() async throws {
        let mock = MockHostsWriter()
        // Stateful live: each write becomes the new file content, so the no-op
        // skip behaves as it would against the real /etc/hosts.
        let (mgr, _) = try makeManager(writer: mock,
                                       live: { mock.lastWritten ?? "127.0.0.1 localhost\n" })
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev")
        let p = mgr.profiles[0]
        await mgr.setActive(p, true)
        await mgr.setActive(mgr.profiles[0], false)
        let written = try XCTUnwrap(mock.lastWritten)
        XCTAssertFalse(written.contains(HostsFile.beginMarker))
        XCTAssertTrue(written.contains("127.0.0.1 localhost"))
    }

    // MARK: - Blank profiles never trigger a privileged write

    func test_activateBlankProfile_skipsWrite() async throws {
        let mock = MockHostsWriter()
        let (mgr, _) = try makeManager(writer: mock,
                                       live: { mock.lastWritten ?? "127.0.0.1 localhost\n" })
        mgr.createProfile(name: "Blank", content: "")
        await mgr.setActive(mgr.profiles[0], true)
        XCTAssertEqual(mock.writeCount, 0, "A blank profile changes nothing; no privileged write")
        XCTAssertTrue(mgr.profiles[0].isActive, "Activation is still recorded in the model")
    }

    func test_deleteBlankActiveProfile_skipsWrite() async throws {
        let mock = MockHostsWriter()
        let (mgr, _) = try makeManager(writer: mock,
                                       live: { mock.lastWritten ?? "127.0.0.1 localhost\n" })
        mgr.createProfile(name: "Blank", content: "")
        await mgr.setActive(mgr.profiles[0], true)
        await mgr.deleteProfile(mgr.profiles[0])
        XCTAssertEqual(mock.writeCount, 0, "Deleting a blank profile requires no authorization")
        XCTAssertEqual(mgr.profiles.count, 0)
    }

    // MARK: - System hosts editing

    func test_updateSystemHosts_writesEditedPrefix_preservesManagedBlock() async throws {
        let mock = MockHostsWriter()
        let (mgr, _) = try makeManager(writer: mock,
                                       live: { mock.lastWritten ?? "127.0.0.1 localhost\n" })
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev.example.com")
        await mgr.setActive(mgr.profiles[0], true)
        await mgr.updateSystemHosts("10.0.0.1 newsystem", replacing: mgr.systemHosts)
        let written = try XCTUnwrap(mock.lastWritten)
        XCTAssertTrue(written.contains("10.0.0.1 newsystem"))       // edited system content
        XCTAssertTrue(written.contains("1.2.3.4 dev.example.com"))  // managed block preserved
        XCTAssertTrue(written.contains(HostsFile.beginMarker))
    }

    // MARK: - Fix 1: debounce / coalesce

    func test_rapidToggles_coalesceIntoSingleWrite() async throws {
        let mock = MockHostsWriter()
        // Use a small debounce so the test runs quickly but both calls still land in the window.
        let (mgr, _) = try makeManager(writer: mock, debounceInterval: .milliseconds(30))
        mgr.createProfile(name: "Alpha", content: "1.1.1.1 alpha")
        mgr.createProfile(name: "Beta", content: "2.2.2.2 beta")
        // Capture IDs to look up profiles after awaiting — avoids sending isolated objects off-actor.
        let alphaID = mgr.profiles[0].id
        let betaID = mgr.profiles[1].id
        // Fire two concurrent activations within the debounce window using Task so they both
        // enqueue before the debounce window expires, then await both.
        let t1 = Task { @MainActor in
            if let p = mgr.profiles.first(where: { $0.id == alphaID }) {
                await mgr.setActive(p, true)
            }
        }
        let t2 = Task { @MainActor in
            if let p = mgr.profiles.first(where: { $0.id == betaID }) {
                await mgr.setActive(p, true)
            }
        }
        await t1.value
        await t2.value
        // Only one write should have reached the system.
        XCTAssertEqual(mock.writeCount, 1, "Rapid concurrent toggles must coalesce into a single write")
        // The single write must contain both profiles' content.
        let written = try XCTUnwrap(mock.lastWritten)
        XCTAssertTrue(written.contains("1.1.1.1 alpha"))
        XCTAssertTrue(written.contains("2.2.2.2 beta"))
    }

    func test_prepareForDeactivationDrainsAStartedWrite() async throws {
        let writer = GatedHostsWriter()
        let (manager, _) = try makeManager(
            writer: writer, live: { writer.lastWritten ?? "127.0.0.1 localhost\n" },
            debounceInterval: .milliseconds(1)
        )
        manager.createProfile(name: "Dev", content: "1.2.3.4 dev")
        writer.gateNextWrite()

        let activation = Task { @MainActor in
            await manager.setActive(manager.profiles[0], true)
        }
        let startDeadline = ContinuousClock.now + .seconds(1)
        while !writer.isSuspended, ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(writer.isSuspended)

        var didPrepare = false
        let preparation = Task { @MainActor in
            await manager.prepareForDeactivation()
            didPrepare = true
        }
        await Task.yield()
        XCTAssertFalse(didPrepare, "Deactivation must wait for a writer that already started")

        writer.release()
        await activation.value
        await preparation.value

        XCTAssertTrue(didPrepare)
        XCTAssertTrue(manager.profiles[0].isActive)
    }

    // MARK: - Fix 1: unreadable /etc/hosts aborts the apply instead of writing empty

    func test_liveReadFailure_abortsApply_setsError_neverWrites() async throws {
        struct LiveReadError: Error {}
        let mock = MockHostsWriter()
        let container = try makeContainer()
        let live: () throws -> String = { throw LiveReadError() }
        let mgr = HostsManager(
            writer: mock,
            backup: HostsBackupStore(backupDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString), readLiveHosts: live),
            readLiveHosts: live,
            debounceInterval: .milliseconds(1))
        mgr.bootstrap(modelContainer: container)
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev")
        let profile = mgr.profiles[0]
        await mgr.setActive(profile, true)
        // A failed read must never destroy the system file: no write may be issued.
        XCTAssertEqual(mock.writeCount, 0, "A failed /etc/hosts read must abort before any write")
        XCTAssertNotNil(mgr.lastError, "lastError must surface the read failure")
    }

    // MARK: - Fix 2: deleting an active profile survives a failed system write

    func test_deleteActiveProfile_failedWrite_keepsRow_restoresActive() async throws {
        let mock = MockHostsWriter()
        let (mgr, _) = try makeManager(writer: mock,
                                       live: { mock.lastWritten ?? "127.0.0.1 localhost\n" })
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev")
        await mgr.setActive(mgr.profiles[0], true)
        XCTAssertEqual(mock.writeCount, 1)
        // The delete's block-removal write fails.
        mock.errorToThrow = HostsWriterError.writeFailed("denied")
        await mgr.deleteProfile(mgr.profiles[0])
        // Row must survive so its block is not orphaned in /etc/hosts.
        XCTAssertEqual(mgr.profiles.count, 1, "Profile must survive a failed system write")
        XCTAssertTrue(mgr.profiles[0].isActive, "Active state must be restored on failed delete")
        XCTAssertNotNil(mgr.lastError, "lastError must surface the write failure")
    }

    /// Regression: deleteProfile must not trust the shared coalesced apply result.
    /// A delete that joins an in-flight applyTask whose write fails gets rolled
    /// back (`isActive` restored) — the follow-up retry is then a no-op "success"
    /// that must NOT let the delete drop the row while its block is still live.
    func test_deleteActiveProfile_joiningFailedCoalescedApply_keepsRow() async throws {
        let writer = GatedHostsWriter()
        let (mgr, _) = try makeManager(writer: writer,
                                       live: { writer.lastWritten ?? "127.0.0.1 localhost\n" },
                                       debounceInterval: .milliseconds(10))
        mgr.createProfile(name: "A", content: "1.1.1.1 a")
        mgr.createProfile(name: "B", content: "2.2.2.2 b")
        let aID = mgr.profiles[0].id
        let bID = mgr.profiles[1].id
        await mgr.setActive(mgr.profiles[0], true) // A applied; live file has A's block

        // Suspend the next write (B's activation) mid-flight, like an open auth dialog.
        writer.gateNextWrite()
        let toggleB = Task { @MainActor in
            if let b = mgr.profiles.first(where: { $0.id == bID }) { await mgr.setActive(b, true) }
        }
        while !writer.isSuspended { try await Task.sleep(for: .milliseconds(5)) }

        // Delete A while the coalesced apply is suspended: it joins the same task.
        let deleteA = Task { @MainActor in
            if let a = mgr.profiles.first(where: { $0.id == aID }) { await mgr.deleteProfile(a) }
        }
        try await Task.sleep(for: .milliseconds(30))
        writer.release(throwing: HostsWriterError.writeFailed("denied"))
        await toggleB.value
        await deleteA.value

        // Rollback restored A.isActive; the retry was a no-op. A's block is still
        // in the live file, so its row must survive and the failure must surface.
        XCTAssertEqual(mgr.profiles.count, 2, "Profile A must survive: its block was never removed")
        XCTAssertEqual(mgr.profiles.first { $0.id == aID }?.isActive, true)
        XCTAssertNotNil(mgr.lastError, "The failed delete must surface an error")
    }

    func test_deleteActiveProfile_successfulWrite_removesRowAndBlock() async throws {
        let mock = MockHostsWriter()
        let (mgr, _) = try makeManager(writer: mock,
                                       live: { mock.lastWritten ?? "127.0.0.1 localhost\n" })
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev")
        await mgr.setActive(mgr.profiles[0], true)
        await mgr.deleteProfile(mgr.profiles[0])
        XCTAssertEqual(mgr.profiles.count, 0)
        let written = try XCTUnwrap(mock.lastWritten)
        XCTAssertFalse(written.contains(HostsFile.beginMarker), "Managed block removed on delete")
        XCTAssertTrue(written.contains("127.0.0.1 localhost"))
    }

    // MARK: - Fix 3: backup failure surfaced but write proceeds

    func test_backupFailure_surfacedButWriteProceeds() async throws {
        struct BackupReadError: Error {}
        let mock = MockHostsWriter()
        let container = try makeContainer()
        // Inject a backup failure: the backup store's snapshot read throws, while
        // the manager's own live read (and so the compose + write) succeeds.
        let failingBackupRead: () throws -> String = { throw BackupReadError() }
        let mgr = HostsManager(
            writer: mock,
            backup: HostsBackupStore(backupDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString), readLiveHosts: failingBackupRead),
            readLiveHosts: { "127.0.0.1 localhost\n" },
            debounceInterval: .milliseconds(1))
        mgr.bootstrap(modelContainer: container)
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev")
        let profile = mgr.profiles[0]
        await mgr.setActive(profile, true)
        // Write should still have proceeded.
        XCTAssertEqual(mock.writeCount, 1, "Write must proceed even when backup creation fails")
        // lastError must surface the backup warning to the user.
        XCTAssertEqual(mgr.lastError, HostsPlugin.L10n.Key.hostsErrorBackupFailed.rawValue,
                       "lastError must be the backup warning after backup failure")
    }
}
