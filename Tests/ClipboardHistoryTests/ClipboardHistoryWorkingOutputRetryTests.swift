import Darwin
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testTemporaryWorkingOutputAccessFailureRetriesAfterReopenWithoutKeep() async throws {
        for stage in ["checkpoint", "before"] {
            let fixture = try await interruptedWorkingOutputForRecovery(stage: stage)
            let member = fixture.pending.appendingPathComponent("member.txt")
            let prefix = try Data(contentsOf: member)
            let access = try WorkingOutputAncestorAccess(fixture.pending)
            defer { access.restore() }
            try access.denyAndVerify()
            let keys = WorkingOutputObservedKeys(base: fixture.services.keys)
            let services = ClipboardSyncServices(transport: fixture.services.transport, keys: keys, pollingInterval: nil)
            let root = fixture.root.appendingPathComponent("Receiver")
            let module = makeLinkedModule(root: root, services: services, key: 0x52)
            let unavailable = try await module.workingOutputRecoveries()
            let notice = try XCTUnwrap(unavailable.first, stage)
            XCTAssertEqual(unavailable.count, 1, stage)
            XCTAssertEqual(notice.reason, .unavailable, stage)
            access.restore()
            try await module.setSyncEnabled(false)
            for _ in 0..<3 {
                let retained = try await module.workingOutputRecoveries()
                XCTAssertEqual(retained.map(\.id), [notice.id], stage)
            }
            await module.retrySync()
            XCTAssertEqual(try Data(contentsOf: member), prefix, stage)
            let offLoads = await keys.loadCount()
            XCTAssertEqual(offLoads, 0, "Off must not acquire a replay key")
            try await module.closeStoreForTesting()

            let reopened = makeLinkedModule(root: root, services: services, key: 0x52)
            let persisted = try await reopened.workingOutputRecoveries()
            XCTAssertEqual(persisted.map(\.id), [notice.id], stage)
            let reopenLoads = await keys.loadCount()
            XCTAssertEqual(reopenLoads, 0, "Reopening an unavailable notice does not authorize replay")
            try await reopened.setSyncEnabled(true)
            await reopened.retrySync()
            let remaining = try await reopened.workingOutputRecoveries()
            XCTAssertTrue(remaining.isEmpty, "A restored ancestor must permit a fully verified retry: \(remaining)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pending.path), stage)
            let entries = try await reopened.page(.init()).entries
            let entry = try XCTUnwrap(entries.first)
            let materialized = try await reopened.materialize(.init(entryID: entry.id, purpose: .normalPaste))
            guard case .file(let file) = materialized.items.first?.representations.first else {
                return XCTFail("Expected complete tree after access recovered")
            }
            XCTAssertEqual(try Data(contentsOf: file.currentURL.appendingPathComponent("member.txt")),
                try Data(contentsOf: fixture.root.appendingPathComponent("Notes/member.txt")), stage)
            try await reopened.closeStoreForTesting()
        }
    }

    @MainActor
    func testWorkingOutputEditAfterTemporaryFailureStaysChangedUntilKeep() async throws {
        let fixture = try await interruptedWorkingOutputForRecovery(stage: "checkpoint")
        let member = fixture.pending.appendingPathComponent("member.txt")
        let access = try WorkingOutputAncestorAccess(fixture.pending)
        defer { access.restore() }
        try access.denyAndVerify()
        let root = fixture.root.appendingPathComponent("Receiver")
        let module = makeLinkedModule(root: root, services: fixture.services, key: 0x52)
        let unavailable = try await module.workingOutputRecoveries()
        let notice = try XCTUnwrap(unavailable.first)
        XCTAssertEqual(notice.reason, .unavailable)
        access.restore()
        let writer = try FileHandle(forWritingTo: member)
        try writer.write(contentsOf: Data("user edit".utf8))
        try writer.close()
        let edited = try Data(contentsOf: member)
        try await module.setSyncEnabled(true)
        await module.retrySync()
        let changed = try await module.workingOutputRecoveries()
        XCTAssertEqual(changed.map(\.id), [notice.id])
        XCTAssertEqual(changed.first?.reason, .changed)
        XCTAssertEqual(try Data(contentsOf: member), edited)

        // A later access failure must not erase already established modification.
        try access.denyAndVerify()
        let inaccessible = try await module.workingOutputRecoveries()
        XCTAssertEqual(inaccessible.first?.reason, .changed)
        access.restore()
        try await module.closeStoreForTesting()
        let reopened = makeLinkedModule(root: root, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        await reopened.retrySync()
        let retained = try await reopened.workingOutputRecoveries()
        XCTAssertEqual(retained.map(\.id), [notice.id])
        XCTAssertEqual(retained.first?.reason, .changed)
        XCTAssertEqual(try Data(contentsOf: member), edited)

        try await reopened.keepWorkingOutput(notice.id)
        await reopened.retrySync()
        let entries = try await reopened.page(.init()).entries
        let entry = try XCTUnwrap(entries.first)
        let materialized = try await reopened.materialize(.init(entryID: entry.id, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else {
            return XCTFail("Expected complete tree after explicit Keep")
        }
        XCTAssertEqual(try Data(contentsOf: file.currentURL.appendingPathComponent("member.txt")),
            try Data(contentsOf: fixture.root.appendingPathComponent("Notes/member.txt")))
        XCTAssertEqual(try Data(contentsOf: member), edited)
    }
}

/// Permission changes stay outside the Receiving tree and its durable snapshots.
/// Verify a real kernel denial; elevated test execution must fail instead of skip.
private final class WorkingOutputAncestorAccess {
    private let url: URL
    private let mode: mode_t

    init(_ pending: URL) throws {
        url = pending.deletingLastPathComponent().deletingLastPathComponent()
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        mode = status.st_mode & 0o777
    }

    func denyAndVerify() throws {
        guard chmod(url.path, 0) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let failure = errno
        if fd >= 0 { close(fd) }
        XCTAssertLessThan(fd, 0, "This test requires effective UID \(geteuid()) to honor directory permissions")
        XCTAssertEqual(failure, EACCES, "The public recovery must encounter a real temporary access failure")
        guard fd < 0, failure == EACCES else { throw CocoaError(.fileReadNoPermission) }
    }

    func restore() { _ = chmod(url.path, mode) }
}

private actor WorkingOutputObservedKeys: ClipboardSyncKeyStoring {
    let base: any ClipboardSyncKeyStoring
    private var loads = 0

    init(base: any ClipboardSyncKeyStoring) { self.base = base }
    func loadCount() -> Int { loads }
    func load(account: ClipboardSyncAccount, keyID: UUID) async throws -> Data? {
        loads += 1
        return try await base.load(account: account, keyID: keyID)
    }
    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) async throws -> Data {
        try await base.create(account: account, keyID: keyID, key: key)
    }
}
