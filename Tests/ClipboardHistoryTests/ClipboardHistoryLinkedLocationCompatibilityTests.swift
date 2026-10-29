import Foundation
import GRDB
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testUnsupportedLinkedLocationsDoNotHideHistoryOrAuthorizeFileActions() async throws {
        for (column, value) in [("id", "invalid-location-id"), ("base_version_id", "invalid-version-id"),
                                ("kind", "future-kind"), ("state", "future-state")] {
            let fixture = try await makeLinkedFixture()
            await fixture.sender.suspendSync()
            await fixture.receiver.suspendSync()
            let text = try await fixture.receiver.capture(.init(source: .unknown, content: .text("unrelated history")))
            let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
            let original = try XCTUnwrap(locations.first)
            let bytes = try Data(contentsOf: original.url)
            try await fixture.receiver.closeStoreForTesting()

            // Damage only this fixture's persisted row. Public writers cannot
            // produce future enum values or malformed identifiers.
            let database = try ClipboardHistoryModule.openDatabase(
                at: fixture.receiverRoot.appendingPathComponent("history.sqlite"),
                databaseKey: ClipboardHistoryKeyDerivation.deriveV1(from: Data(repeating: 0x52, count: 32)).databaseKey)
            addTeardownBlock { try database.close() }
            try await database.write { db in
                try db.execute(sql: "UPDATE clipboard_sync_linked_locations SET \(column) = ? WHERE id = ?",
                    arguments: [value, original.id.uuidString])
            }
            try database.close()
            let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)

            let page = try await reopened.page(.init())
            XCTAssertEqual(Set(page.entries.map(\.id)), [fixture.entryID, text.entryID], column)
            let entry = try XCTUnwrap(page.entries.first { $0.id == fixture.entryID })
            XCTAssertTrue(entry.linkedFileLocations.isEmpty, column)
            XCTAssertEqual(entry.syncFiles.count, 1, "The unsupported location must not remove the file member")
            XCTAssertEqual(entry.syncFiles.first?.state, .localUnavailable, column)
            let currentLocations = try await reopened.linkedFileLocations(for: fixture.entryID)
            XCTAssertTrue(currentLocations.isEmpty, column)
            do {
                _ = try await reopened.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
                XCTFail("An unsupported location must not fall back to its old stored file path: \(column)")
            } catch ClipboardHistoryModuleError.fileReferencesUnavailable {}
            let selection = ClipboardHistoryFileLocationSelection(entryID: fixture.entryID,
                locationID: original.id, expectedRevision: original.revision)
            do {
                try await reopened.setFileLocationPaused(selection, paused: true)
                XCTFail("A prior selection must not authorize an unsupported location: \(column)")
            } catch ClipboardHistoryModuleError.operationUnavailable {}
            do {
                _ = try await reopened.reassociateFileLocation(.init(selection: selection, url: original.url))
                XCTFail("Reassociation must not rewrite an unsupported location: \(column)")
            } catch ClipboardHistoryModuleError.operationUnavailable {}
            XCTAssertEqual(try Data(contentsOf: original.url), bytes, column)
            try await reopened.closeStoreForTesting()

            let retained = try ClipboardHistoryModule.openDatabase(
                at: fixture.receiverRoot.appendingPathComponent("history.sqlite"),
                databaseKey: ClipboardHistoryKeyDerivation.deriveV1(from: Data(repeating: 0x52, count: 32)).databaseKey)
            addTeardownBlock { try retained.close() }
            let stored = try await retained.read { db in
                try String.fetchOne(db, sql: "SELECT \(column) FROM clipboard_sync_linked_locations WHERE path = ?",
                    arguments: [original.url.path])
            }
            XCTAssertEqual(stored, value, "Keep unsupported records available to a compatible version")
            try retained.close()
        }
    }
}
