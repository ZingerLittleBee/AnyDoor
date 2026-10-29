import Foundation
import GRDB
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testPreApplicationV29StoreRetainsHistoryAndLinkedPackageWhenAddingV28() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("application-migration-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let package = try ClipboardApplicationTestFixture.create(at: root.appendingPathComponent("Legacy.app"),
            bundleIdentifier: "dev.bybee.AnyDoor.tests.migration.\(UUID().uuidString)",
            resource: "retained legacy bytes", signed: false)
        let baseline = try package.contentsSnapshot()
        let proof = try ClipboardLinkedFileIO.inspect(package.url)
        let store = root.appendingPathComponent("Store")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let databaseURL = store.appendingPathComponent("history.sqlite")
        let key = Data(repeating: 0x57, count: 32)
        let legacy = try ClipboardHistoryModule.openDatabase(at: databaseURL, databaseKey: key,
            migrationTarget: "v27_clipboard_sync_directory_versions")
        addTeardownBlock { try legacy.close() }
        // The integrated pre-application branch had v29 without reserved v28.
        // Build that actual schema, rather than deleting migration markers or
        // stripping columns from a database that already used application plans.
        var oldLifecycle = DatabaseMigrator()
        oldLifecycle.registerMigration("v29_clipboard_sync_file_lifecycle") { database in
            try ClipboardHistoryModule.createSyncFileLifecycleSchema(in: database)
        }
        try oldLifecycle.migrate(legacy)
        let entry = ClipboardHistoryEntryID(UUID())
        let entryID = entry.value.uuidString.lowercased()
        let account = "legacy-application-account", epoch = UUID(), object = UUID(), version = UUID(), location = UUID()
        let descriptor = ClipboardSyncFileDescriptor(objectID: object, versionID: version, displayName: "Legacy.app",
            originalByteCount: proof.byteCount, contentDigest: proof.digest, body: nil, state: .available, kind: .directory)
        let encodedDescriptor = try JSONEncoder().encode(descriptor)
        let nativeIdentity = try proof.nativeIdentity?.encoded()
        try await legacy.write { database in
            XCTAssertFalse(try database.tableExists("clipboard_sync_application_plans"))
            XCTAssertFalse(try database.columns(in: "clipboard_sync_linked_locations").contains { $0.name == "is_application" })
            try database.execute(sql: "INSERT INTO clipboard_entries(id, captured_at, last_captured_at, preview_text, is_favorite) VALUES (?, 0, 0, 'retained legacy application', 1)", arguments: [entryID])
            try database.execute(sql: "INSERT INTO clipboard_items VALUES (?, 0)", arguments: [entryID])
            try database.execute(sql: "INSERT INTO clipboard_representations(entry_id, item_index, representation_index, kind, type_identifier, text_value) VALUES (?, 0, 0, 'fileReference', 'public.file-url', ?)", arguments: [entryID, package.url.absoluteString])
            try database.execute(sql: "INSERT INTO clipboard_entry_facets VALUES (?, 'file')", arguments: [entryID])
            try database.execute(sql: "INSERT INTO clipboard_retention_state VALUES (?, 0, 1)", arguments: [entryID])
            try database.execute(sql: """
                INSERT INTO clipboard_file_members(entry_id, item_index, member_index, captured_path, current_path,
                    display_name, bookmark_data, resource_type, availability, identity_data)
                VALUES (?, 0, 0, ?, ?, 'Legacy.app', ?, 'com.apple.application-bundle', 'available', ?)
                """, arguments: [entryID, proof.url.path, proof.url.path, proof.bookmark, proof.identity])
            try database.execute(sql: "UPDATE clipboard_sync_settings SET account_id = ?, enabled = 0 WHERE id = 1", arguments: [account])
            try database.execute(sql: """
                INSERT INTO clipboard_sync_file_versions(account_id, epoch, object_id, version_id, descriptor,
                    transfer_state, local_path, local_bookmark, local_identity)
                VALUES (?, ?, ?, ?, ?, 'complete', ?, ?, ?)
                """, arguments: [account, epoch.uuidString, object.uuidString, version.uuidString, encodedDescriptor,
                    proof.url.path, proof.bookmark, proof.identity])
            try database.execute(sql: "INSERT INTO clipboard_sync_file_members VALUES (?, ?, ?, 0, 0, ?, ?, 'local')",
                arguments: [account, epoch.uuidString, entryID, object.uuidString, version.uuidString])
            try database.execute(sql: "INSERT INTO clipboard_sync_file_selections VALUES (?, ?, ?, ?, ?)",
                arguments: [account, epoch.uuidString, object.uuidString, version.uuidString, version.uuidString])
            try database.execute(sql: """
                INSERT INTO clipboard_sync_linked_locations(id, account_id, epoch, object_id, path, bookmark, identity,
                    kind, base_version_id, base_digest, state, revision, native_identity)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'associated', ?, ?, 'paused', 17, ?)
                """, arguments: [location.uuidString, account, epoch.uuidString, object.uuidString, proof.url.path,
                    proof.bookmark, proof.identity, version.uuidString, proof.digest, nativeIdentity])
        }
        try legacy.close()

        let upgraded = try trackClipboardHistoryModule(ClipboardHistoryModule(testingDatabaseURL: databaseURL, databaseKey: key))
        let page = try await upgraded.page(.init())
        XCTAssertEqual(page.entries.map(\.id), [entry])
        XCTAssertEqual(page.entries.first?.previewText, "retained legacy application")
        XCTAssertEqual(page.entries.first?.isFavorite, true)
        let linked = try await upgraded.linkedFileLocations(for: entry)
        XCTAssertEqual(linked.count, 1)
        XCTAssertEqual(linked.first?.id, location)
        XCTAssertEqual(linked.first?.objectID, object)
        XCTAssertEqual(linked.first?.baseVersionID, version)
        XCTAssertEqual(linked.first?.revision, 17)
        XCTAssertEqual(linked.first?.state, .paused)
        XCTAssertEqual(linked.first?.url.path, proof.url.path)
        XCTAssertEqual(try package.contentsSnapshot(), baseline)
        let diagnostics = try await upgraded.storageDiagnostics()
        XCTAssertEqual(Array(diagnostics.appliedMigrations.suffix(7)),
            ["v29_clipboard_sync_file_lifecycle", "v28_clipboard_sync_application_updates", "v30_clipboard_sync_file_retries", "v31_legacy_tag_recovery", "v32_working_output_recovery", "v33_clipboard_sync_page_indexes", "v34_working_output_members"])
        XCTAssertTrue(diagnostics.databaseIntegrityOK && diagnostics.foreignKeyIntegrityOK && diagnostics.cipherIntegrityOK)
        try await upgraded.closeStoreForTesting()
        let reopened = try trackClipboardHistoryModule(ClipboardHistoryModule(testingDatabaseURL: databaseURL, databaseKey: key))
        let retained = try await reopened.linkedFileLocations(for: entry)
        XCTAssertEqual(retained, linked)
        let history = try await reopened.page(.init())
        XCTAssertEqual(history.entries.map(\.id), [entry])
    }

    @MainActor
    func testObsoleteApplicationPlanCannotInstallAfterNewVersionOrRestart() async throws {
        let fixture = try await makeLinkedFixture(prepareSource: { url in
            try FileManager.default.removeItem(at: url)
            _ = try ClipboardApplicationTestFixture.create(at: url,
                bundleIdentifier: "dev.bybee.AnyDoor.tests.stale-plan.\(UUID().uuidString)",
                resource: "installed version one", signed: false)
        }, sourceName: "Retained Application.app")
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let retained = ClipboardApplicationTestFixture(url: working.url)
        let baseline = try retained.contentsSnapshot()
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let resource = fixture.original.appendingPathComponent("Contents/Resources/Resource.txt")
        try Data("candidate version two".utf8).write(to: resource)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let displayed = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let selection = try XCTUnwrap(displayed.first)
        let obsolete = try await fixture.receiver.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: selection.id, expectedRevision: selection.revision))
        XCTAssertEqual(obsolete.state, .ready)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        try Data("latest version three".utf8).write(to: resource)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)

        do {
            try await fixture.receiver.applyApplicationUpdate(obsolete)
            XCTFail("An old confirmation cannot apply a different current version")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryApplicationUpdateError, .stalePlan)
        }
        XCTAssertEqual(try retained.contentsSnapshot(), baseline)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        await reopened.resumeSync()
        await reopened.retrySync()
        do {
            try await reopened.applyApplicationUpdate(obsolete)
            XCTFail("Restart cannot revive an obsolete application confirmation")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryApplicationUpdateError, .stalePlan)
        }
        XCTAssertEqual(try retained.contentsSnapshot(), baseline)
        let freshLocations = try await reopened.linkedFileLocations(for: fixture.entryID)
        let fresh = try XCTUnwrap(freshLocations.first)
        let current = try await reopened.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: fresh.id, expectedRevision: fresh.revision))
        XCTAssertEqual(current.state, .ready)
        XCTAssertNotEqual(current.versionID, obsolete.versionID)
        try await reopened.applyApplicationUpdate(current)
        XCTAssertEqual(try retained.contentsSnapshot(), try ClipboardApplicationTestFixture(url: fixture.original).contentsSnapshot())
        let installed = try await reopened.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(installed.first?.id, working.id)
        XCTAssertEqual(installed.first?.baseVersionID, current.versionID)
    }

    @MainActor
    func testLargeUnsignedApplicationRequiresExactDownloadThenSeparateApply() async throws {
        let identifier = "dev.bybee.AnyDoor.tests.large-application.\(UUID().uuidString)"
        let fixture = try await makeLinkedFixture(prepareSource: { url in
            try FileManager.default.removeItem(at: url)
            _ = try ClipboardApplicationTestFixture.create(at: url, bundleIdentifier: identifier,
                resource: "previous complete package", signed: false)
        }, sourceName: "Unsigned Application.app")
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let old = ClipboardApplicationTestFixture(url: working.url)
        let baseline = try old.contentsSnapshot()
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let candidate = try ClipboardApplicationTestFixture.create(at: fixture.root.appendingPathComponent("Large Candidate.app"),
            bundleIdentifier: identifier, resource: String(repeating: "A", count: 5_500_001), signed: false)
        try FileManager.default.removeItem(at: fixture.original.appendingPathComponent("Contents"))
        try FileManager.default.copyItem(at: candidate.url.appendingPathComponent("Contents"),
            to: fixture.original.appendingPathComponent("Contents"))
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let page = try await fixture.receiver.page(.init())
        let advertised = try XCTUnwrap(page.entries.first?.syncFiles.first)
        XCTAssertGreaterThan(try XCTUnwrap(advertised.originalByteCount), 5_000_000)
        let downloaded = await fixture.cloud.downloadedFileVersions()
        XCTAssertFalse(downloaded.contains(advertised.versionID), "The aggregate package exceeds automatic download consent")
        XCTAssertEqual(try old.contentsSnapshot(), baseline)
        let currentLocations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let current = try XCTUnwrap(currentLocations.first)
        let plan = try await fixture.receiver.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: current.id, expectedRevision: current.revision))
        XCTAssertEqual(plan.state, .requiresDownload)
        XCTAssertEqual(plan.versionID, advertised.versionID)
        do {
            try await fixture.receiver.applyApplicationUpdate(plan)
            XCTFail("Download permission is required before explicit application")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryApplicationUpdateError, .downloadRequired(advertised.versionID))
        }

        try await fixture.receiver.requestApplicationUpdateDownload(plan)

        let received = await fixture.cloud.downloadedFileVersions()
        XCTAssertTrue(received.contains(advertised.versionID))
        XCTAssertEqual(try old.contentsSnapshot(), baseline, "Receiving a complete version does not authorize installation")
        let afterDownload = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(afterDownload.first?.baseVersionID, working.baseVersionID)
        let displayed = try XCTUnwrap(afterDownload.first)
        let ready = try await fixture.receiver.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: displayed.id, expectedRevision: displayed.revision))
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.versionID, advertised.versionID)

        try await fixture.receiver.applyApplicationUpdate(ready)

        XCTAssertEqual(try old.contentsSnapshot(), try candidate.contentsSnapshot())
        let installed = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(installed.first?.id, working.id)
        XCTAssertEqual(installed.first?.baseVersionID, advertised.versionID)
    }
}
