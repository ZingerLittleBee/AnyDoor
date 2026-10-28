import ClipboardHistoryTestSupport
import Foundation
import SwiftData
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardHistoryPortableSettingsTests: XCTestCase {
    func testAutomaticSettingsRefreshPreservesMembershipWhenTagMirrorIsStale() async throws {
        let fixture = try Fixture(testCase: self)
        let module = fixture.module
        let captured = try await module.capture(ClipboardHistoryCaptureRequest(
            source: .unknown, content: .text("local history")
        ))
        let localTag = try await module.createTagDefinition(
            named: "Local", assigningTo: captured.entryID
        )
        fixture.defaults.set(
            #"[{"id":"stale","name":"Stale mirror"}]"#,
            forKey: ClipboardHistoryPortableKeys.customTags
        )
        var peer = SyncDocument(deviceID: "peer")
        peer.entries[.setting(key: "menuBar.iconName")] = SyncEntry(
            payload: .setting(.string("peer-icon")),
            clock: SyncTimestamp(wallMillis: 9_000, counter: 0, deviceID: "peer")
        )
        try SyncStateCodec.encode(peer).write(to: fixture.directory.appendingPathComponent(
            SyncStateFile.name(forDeviceID: "peer")
        ))
        let container = try ModelContainer(
            for: Schema([KeyBinding.self, BuiltinPreference.self, Quicklink.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let engine = SyncEngine(
            config: .init(deviceID: "local"),
            context: container.mainContext,
            defaults: fixture.defaults,
            transport: SyncFolderTransport(folderURL: fixture.directory),
            stateStore: SyncLocalStateStore(url: fixture.directory.appendingPathComponent("sync-state.json")),
            reconcileRuntime: { importClipboardTags in
                try await ClipboardHistoryPortableSettings.reconcile(
                    module: module, defaults: fixture.defaults,
                    importClipboardTags: importClipboardTags
                )
            },
            wallNow: { 1_000 }
        )

        await engine.tick()

        XCTAssertEqual(fixture.defaults.string(forKey: "menuBar.iconName"), "peer-icon")
        let definitions = try await module.tagDefinitions()
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(definitions, [localTag.definition])
        XCTAssertEqual(page.entries.first?.tagIDs, [localTag.definition.id])
    }

    func testPersistsDefinitionsWithoutMembership() async throws {
        let fixture = try Fixture(testCase: self)
        let module = fixture.module
        let entry = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .unknown,
                content: .text("private membership")
            )
        )
        let assignment = try await module.createTagDefinition(
            named: "Work",
            assigningTo: entry.entryID
        )

        try ClipboardHistoryPortableSettings.persist(
            await module.tagDefinitions(),
            to: fixture.defaults
        )

        let json = try XCTUnwrap(
            fixture.defaults.string(
                forKey: ClipboardHistoryPortableKeys.customTags
            )
        )
        XCTAssertTrue(json.contains(assignment.definition.id))
        XCTAssertTrue(json.contains("Work"))
        XCTAssertFalse(json.contains(entry.entryID.value.uuidString))
        XCTAssertFalse(json.contains("private membership"))
    }

    func testManualBackupRoundTripReplacesDefinitionsAndRemovedMembership()
        async throws
    {
        let fixture = try Fixture(testCase: self)
        let module = fixture.module
        let entry = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .unknown,
                content: .text("local")
            )
        )
        _ = try await module.createTagDefinition(
            named: "Local",
            assigningTo: entry.entryID
        )
        let imported = [
            ClipboardTag(id: "second", name: "Second"),
            ClipboardTag(id: "first", name: "First"),
        ]
        let data = try JSONEncoder().encode(imported)
        fixture.defaults.set(
            String(decoding: data, as: UTF8.self),
            forKey: ClipboardHistoryPortableKeys.customTags
        )

        let container = try ModelContainer(
            for: Schema([KeyBinding.self, BuiltinPreference.self, Quicklink.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let backup = BackupService(
            context: container.mainContext,
            defaults: fixture.defaults,
            appPathResolver: { _ in nil },
            reconcileRuntime: {
                try await ClipboardHistoryPortableSettings.reconcile(
                    module: module, defaults: fixture.defaults
                )
            }
        )
        let exported = try BackupCodec.encode(backup.exportSnapshot())
        fixture.defaults.removeObject(forKey: ClipboardHistoryPortableKeys.customTags)

        _ = try await backup.restore(BackupCodec.decode(exported))

        let definitions = try await module.tagDefinitions()
        XCTAssertEqual(
            definitions,
            [
                ClipboardHistoryTagDefinition(
                    id: "second",
                    displayName: "Second"
                ),
                ClipboardHistoryTagDefinition(
                    id: "first",
                    displayName: "First"
                ),
            ]
        )
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.first?.tagIDs, [])
    }
}

private struct Fixture {
    let directory: URL
    let defaults: UserDefaults
    let module: ClipboardHistoryModule

    init(testCase: XCTestCase) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        testCase.removeClipboardHistoryDirectoryAfterTest(directory)
        defaults = testCase.makeTemporaryDefaults()
        module = try testCase.trackClipboardHistoryModule(
            ClipboardHistoryModule(
                testingDatabaseURL:
                    directory.appendingPathComponent("history.sqlite"),
                databaseKey: Data(repeating: 0x42, count: 32)
            )
        )
    }
}
