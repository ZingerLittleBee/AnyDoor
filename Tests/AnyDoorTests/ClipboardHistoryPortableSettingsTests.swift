import ClipboardHistoryTestSupport
import Foundation
import SwiftData
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardHistoryPortableSettingsTests: XCTestCase {
    func testLifecycleRetiresLegacyMirrorBeforeReportingReady() async throws {
        let fixture = try Fixture(testCase: self)
        fixture.defaults.set(false, forKey: ClipboardPreferences.monitoringKey)
        fixture.defaults.set(try ClipboardHistoryPortableSettings.encode([.init(id: "private", displayName: "Private label")]), forKey: ClipboardHistoryPortableKeys.customTags)
        let lifecycle = ClipboardHistoryLifecycle(module: fixture.module, defaults: fixture.defaults, migrationRequest: nil)
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        let definitions = try await fixture.module.tagDefinitions()
        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
        XCTAssertEqual(definitions, [.init(id: "private", displayName: "Private label")])
        await lifecycle.stop()
    }

    func testFailedLegacyMirrorMigrationPreservesSourceAndRetriesAfterRestart() async throws {
        let fixture = try Fixture(testCase: self, faultInjector: .init(points: [.databaseTransaction]))
        fixture.defaults.set(false, forKey: ClipboardPreferences.monitoringKey)
        let legacy = try ClipboardHistoryPortableSettings.encode([.init(id: "private", displayName: "Private label")])
        fixture.defaults.set(legacy, forKey: ClipboardHistoryPortableKeys.customTags)
        let failed = ClipboardHistoryLifecycle(module: fixture.module, defaults: fixture.defaults, migrationRequest: nil)
        failed.start()
        await failed.awaitCurrentOperationForTesting()
        XCTAssertEqual(failed.state, .migrationFailed)
        XCTAssertEqual(fixture.defaults.string(forKey: ClipboardHistoryPortableKeys.customTags), legacy)
        let afterFailure = try await fixture.module.tagDefinitions()
        XCTAssertTrue(afterFailure.isEmpty, "The failed encrypted transaction must not partially import definitions")
        await failed.stop()
        try await fixture.module.closeStoreForTesting()

        let reopened = try trackClipboardHistoryModule(ClipboardHistoryModule(
            testingDatabaseURL: fixture.directory.appendingPathComponent("history.sqlite"), databaseKey: Data(repeating: 0x42, count: 32)))
        let retry = ClipboardHistoryLifecycle(module: reopened, defaults: fixture.defaults, migrationRequest: nil)
        retry.start()
        await retry.awaitCurrentOperationForTesting()
        XCTAssertEqual(retry.state, .ready)
        XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
        let recovered = try await reopened.tagDefinitions()
        XCTAssertEqual(recovered, [.init(id: "private", displayName: "Private label")])
        await retry.stop()
    }

    func testLegacyMirrorMigratesOnceWithoutReplacingCurrentIdentityOrMembership() async throws {
        let fixture = try Fixture(testCase: self)
        let entry = try await fixture.module.capture(.init(source: .unknown, content: .text("retained local history")))
        let current = try await fixture.module.createTagDefinition(named: "Current name", assigningTo: entry.entryID).definition
        let legacy = [ClipboardHistoryTagDefinition(id: current.id, displayName: "Stale name"),
                      ClipboardHistoryTagDefinition(id: "private-legacy", displayName: "Private legacy tag")]
        fixture.defaults.set(try ClipboardHistoryPortableSettings.encode(legacy), forKey: ClipboardHistoryPortableKeys.customTags)
        fixture.defaults.set(false, forKey: ClipboardPreferences.monitoringKey)
        let lifecycle = ClipboardHistoryLifecycle(module: fixture.module, defaults: fixture.defaults, migrationRequest: nil)
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .ready)
        await lifecycle.stop()
        XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
        let migrated = try await fixture.module.tagDefinitions()
        XCTAssertEqual(migrated, [current, legacy[1]])
        let entries = try await fixture.module.page(.init()).entries
        XCTAssertEqual(entries.first?.tagIDs, [current.id])
        _ = try await fixture.module.deleteTagDefinition(id: "private-legacy")
        try await fixture.module.closeStoreForTesting()
        let reopened = try trackClipboardHistoryModule(ClipboardHistoryModule(
            testingDatabaseURL: fixture.directory.appendingPathComponent("history.sqlite"), databaseKey: Data(repeating: 0x42, count: 32)))
        fixture.defaults.set(try ClipboardHistoryPortableSettings.encode(legacy), forKey: ClipboardHistoryPortableKeys.customTags)
        let restarted = ClipboardHistoryLifecycle(module: reopened, defaults: fixture.defaults, migrationRequest: nil)
        restarted.start()
        await restarted.awaitCurrentOperationForTesting()
        XCTAssertEqual(restarted.state, .ready)
        await restarted.stop()
        let afterReplay = try await reopened.tagDefinitions()
        XCTAssertEqual(afterReplay, [current])
        XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
    }

    func testManualExportReadsCurrentDefinitionsInsteadOfStaleDefaultsMirror() async throws {
        let fixture = try Fixture(testCase: self)
        let entry = try await fixture.module.capture(.init(source: .unknown, content: .text("current tag identity")))
        let tag = try await fixture.module.createTagDefinition(named: "Before rename", assigningTo: entry.entryID).definition
        fixture.defaults.set(try ClipboardHistoryPortableSettings.encode([tag]), forKey: ClipboardHistoryPortableKeys.customTags)
        let originalMirror = fixture.defaults.string(forKey: ClipboardHistoryPortableKeys.customTags)
        let renamed = try await fixture.module.renameTagDefinition(id: tag.id, to: "Current name")
        let container = try ModelContainer(for: Schema([KeyBinding.self, BuiltinPreference.self, Quicklink.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let backup = BackupService(context: container.mainContext, defaults: fixture.defaults, appPathResolver: { _ in nil },
            currentClipboardTags: { try await fixture.module.tagDefinitions() })
        let snapshot = try await backup.exportCurrentSnapshot()
        guard case .string(let json) = snapshot.settings[ClipboardHistoryPortableKeys.customTags] else {
            return XCTFail("Manual backup must retain current tag definitions")
        }
        let exported = try JSONDecoder().decode([ClipboardTag].self, from: Data(json.utf8))
        XCTAssertEqual(exported, [ClipboardTag(id: renamed.id, name: renamed.displayName)])
        XCTAssertEqual(fixture.defaults.string(forKey: ClipboardHistoryPortableKeys.customTags), originalMirror)
        fixture.defaults.removeObject(forKey: ClipboardHistoryPortableKeys.customTags)
        _ = try await backup.exportCurrentSnapshot()
        XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
    }

    func testManualBackupRoundTripsDistinctSameNameIdentities() async throws {
        let fixture = try Fixture(testCase: self)
        let entry = try await fixture.module.capture(.init(source: .unknown, content: .text("kept membership")))
        let local = try await fixture.module.createTagDefinition(named: "Work", assigningTo: entry.entryID).definition
        let definitions = [local, ClipboardHistoryTagDefinition(id: "independent-work", displayName: "Work")]
        _ = try await fixture.module.replaceTagDefinitions(with: definitions)
        let container = try ModelContainer(for: Schema([KeyBinding.self, BuiltinPreference.self, Quicklink.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let backup = BackupService(context: container.mainContext, defaults: fixture.defaults, appPathResolver: { _ in nil },
            currentClipboardTags: { try await fixture.module.tagDefinitions() },
            restoreClipboardTags: { _ = try await fixture.module.replaceTagDefinitions(with: $0) }, reconcileRuntime: {})
        let exported = try await BackupCodec.encode(backup.exportCurrentSnapshot())
        _ = try await fixture.module.renameTagDefinition(id: local.id, to: "Changed after backup")
        _ = try await backup.restore(BackupCodec.decode(exported))
        let restoredDefinitions = try await fixture.module.tagDefinitions()
        let restored = try await fixture.module.page(.init()).entries
        XCTAssertEqual(restoredDefinitions, definitions)
        XCTAssertEqual(restored.first?.tagIDs, [local.id])
        XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
    }

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
            reconcileRuntime: {},
            wallNow: { 1_000 }
        )

        await engine.tick()

        XCTAssertEqual(fixture.defaults.string(forKey: "menuBar.iconName"), "peer-icon")
        let definitions = try await module.tagDefinitions()
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(definitions, [localTag.definition])
        XCTAssertEqual(page.entries.first?.tagIDs, [localTag.definition.id])
    }

    func testManualEncodingIncludesDefinitionsWithoutMembershipOrPreferencesMirror() async throws {
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

        let json = try await ClipboardHistoryPortableSettings.encode(module.tagDefinitions())
        XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
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
        let container = try ModelContainer(
            for: Schema([KeyBinding.self, BuiltinPreference.self, Quicklink.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let backup = BackupService(
            context: container.mainContext,
            defaults: fixture.defaults,
            appPathResolver: { _ in nil },
            restoreClipboardTags: { _ = try await module.replaceTagDefinitions(with: $0) },
            reconcileRuntime: {}
        )
        var snapshot = try backup.exportSnapshot()
        snapshot.settings[ClipboardHistoryPortableKeys.customTags] = .string(String(decoding: data, as: UTF8.self))
        let exported = try BackupCodec.encode(snapshot)

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
        XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
    }
}

private struct Fixture {
    let directory: URL
    let defaults: UserDefaults
    let module: ClipboardHistoryModule

    init(testCase: XCTestCase, faultInjector: ClipboardHistoryFaultInjector = .init()) throws {
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
                databaseKey: Data(repeating: 0x42, count: 32),
                faultInjector: faultInjector
            )
        )
    }
}
