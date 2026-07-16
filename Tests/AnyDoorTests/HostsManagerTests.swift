import XCTest
import SwiftData
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

    func write(_ content: String) async throws {
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
        lock.withLock { _lastWritten = content }
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
                             debounceInterval: Duration = .milliseconds(150)) throws
        -> (HostsManager, ModelContainer) {
        let container = try makeContainer()
        let mgr = HostsManager(writer: writer,
                               backup: HostsBackupStore(backupDirectory: FileManager.default.temporaryDirectory
                                   .appendingPathComponent(UUID().uuidString), readLiveHosts: live),
                               readLiveHosts: live,
                               debounceInterval: debounceInterval)
        mgr.bootstrap(modelContainer: container)
        return (mgr, container)
    }

    func test_createProfile_persists_noSystemWrite() throws {
        let mock = MockHostsWriter()
        let (mgr, _) = try makeManager(writer: mock)
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev")
        XCTAssertEqual(mgr.profiles.count, 1)
        XCTAssertEqual(mock.writeCount, 0)  // inactive => no write
    }

    func test_duplicateProfileCopiesContentAsInactiveProfileWithoutSystemWrite() throws {
        // The copy name resolves through the plugin module's host bridge.
        PluginHost.bootstrap(CorePluginHost(modelContainer: try makeContainer()))
        let previous = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .en
        defer { LocalizationManager.shared.preference = previous }

        let mock = MockHostsWriter()
        let (mgr, _) = try makeManager(writer: mock)
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
        let (mgr, _) = try makeManager(writer: mock)
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
        await mgr.updateSystemHosts("10.0.0.1 newsystem")
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
        let mock = MockHostsWriter()
        let (mgr, _) = try makeManager(writer: mock, debounceInterval: .milliseconds(1))
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev")
        // Inject a backup failure.
        mgr.backup.backupErrorOverride = HostsWriterError.writeFailed("backup dir unwritable")
        let profile = mgr.profiles[0]
        await mgr.setActive(profile, true)
        // Write should still have proceeded.
        XCTAssertEqual(mock.writeCount, 1, "Write must proceed even when backup creation fails")
        // lastError must surface the backup warning to the user.
        XCTAssertNotNil(mgr.lastError, "lastError must be non-nil after backup failure")
    }
}
