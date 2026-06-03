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
                             live: @escaping () -> String = { "127.0.0.1 localhost\n" }) throws
        -> (HostsManager, ModelContainer) {
        let container = try makeContainer()
        let mgr = HostsManager(writer: writer,
                               backup: HostsBackupStore(backupDirectory: FileManager.default.temporaryDirectory
                                   .appendingPathComponent(UUID().uuidString), readLiveHosts: live),
                               readLiveHosts: live)
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
}
