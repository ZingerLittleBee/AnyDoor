import XCTest
@testable import AnyDoor
@testable import HostsPlugin

final class HostsBackupStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosts-backup-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_ensureOriginalBackup_writesSnapshotOnce() throws {
        let dir = tempDir()
        var reads = 0
        let store = HostsBackupStore(backupDirectory: dir, readLiveHosts: {
            reads += 1
            return "127.0.0.1 localhost\n"
        })
        try store.ensureOriginalBackup()
        try store.ensureOriginalBackup()  // second call must be a no-op
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(store.hasBackup)
        XCTAssertEqual(store.originalContents(), "127.0.0.1 localhost\n")
    }

    func test_restoreFirstRunBackup_writesSnapshotThroughWriter() async throws {
        let dir = tempDir()
        let store = HostsBackupStore(backupDirectory: dir, readLiveHosts: { "ORIGINAL\n" })
        try store.ensureOriginalBackup()
        let mock = MockHostsWriter()
        try await store.restoreFirstRunBackup(using: mock)
        XCTAssertEqual(mock.lastWritten, "ORIGINAL\n")
    }
}
