import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testRepeatedConflictPlansReuseAuthorityAndBoundEncryptedStoreGrowth() async throws {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        try Data("published competing branch".utf8).write(to: fixture.original)
        let chosen = Data("local choice survives repeated presentation".utf8)
        try chosen.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(false)

        let original = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        var identities: Set<UUID> = [original.id]
        for _ in 0..<64 {
            let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
            identities.insert(plan.id)
            XCTAssertEqual(plan.candidates, original.candidates)
        }
        try await fixture.receiver.closeStoreForTesting()
        let warmAllocated = try await fixture.receiver.storageUsage()
        let warmBytes = try conflictDatabaseBytes(in: fixture.receiverRoot)

        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        for _ in 0..<256 {
            identities.insert(try await reopened.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID).id)
        }
        try await reopened.closeStoreForTesting()
        let retainedAllocated = try await reopened.storageUsage()
        let retainedBytes = try conflictDatabaseBytes(in: fixture.receiverRoot)
        print("Conflict plan storage after close: database=\(warmBytes)->\(retainedBytes), allocated=\(warmAllocated)->\(retainedAllocated)")
        XCTAssertEqual(identities.count, 1, "An unchanged displayed choice must reuse its durable authority")
        XCTAssertLessThanOrEqual(retainedBytes, warmBytes + 64 * 1_024,
            "Repeated presentation must not retain another full snapshot on every open")

        let final = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        let current = try await final.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        XCTAssertEqual(current.id, original.id)
        try await final.setSyncEnabled(true)
        _ = try await final.resolveFileConflict(current, choosing: .localLocation(working.id))
        await fixture.sender.retrySync()
        XCTAssertEqual(try Data(contentsOf: working.url), chosen)
        XCTAssertEqual(try Data(contentsOf: fixture.original), chosen)
    }

    private func conflictDatabaseBytes(in root: URL) throws -> UInt64 {
        try ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm"].reduce(UInt64(0)) { total, name in
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return total }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
            return total + size.uint64Value
        }
    }
}
