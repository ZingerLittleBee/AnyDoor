import XCTest
import SwiftData
@testable import AnyDoor

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
        let (mgr, _) = try makeManager(writer: mock)
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev")
        let p = mgr.profiles[0]
        await mgr.setActive(p, true)
        await mgr.setActive(mgr.profiles[0], false)
        let written = try XCTUnwrap(mock.lastWritten)
        XCTAssertFalse(written.contains(HostsFile.beginMarker))
        XCTAssertTrue(written.contains("127.0.0.1 localhost"))
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
