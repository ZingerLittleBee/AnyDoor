import ClipboardHistoryTestSupport
import Foundation
import SwiftData
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class BackupAvailabilityTests: XCTestCase {
    func testUnavailableHistoryExportsIndependentConfigurationWithTagOmission() async throws {
        let fixture = try makeFixture()
        let entry = try await fixture.module.capture(.init(source: .unknown, content: .text("Retained history")))
        _ = try await fixture.module.createTagDefinition(named: "Private tag", assigningTo: entry.entryID)
        fixture.context.insert(KeyBinding(keyCode: 4, modifierFlags: 256,
            appBundleID: "com.example.Backup", appName: "Backup", appPath: "",
            isEnabled: true, isVisible: true, displayOrder: 1))
        fixture.context.insert(Quicklink(name: "Documentation", link: "https://example.com/docs", displayOrder: 1))
        try fixture.context.save()
        fixture.defaults.set("en", forKey: "dev.bybee.AnyDoor.language")
        fixture.defaults.set("stale plaintext mirror", forKey: ClipboardHistoryPortableKeys.customTags)
        let service = BackupService(context: fixture.context, defaults: fixture.defaults,
            appPathResolver: { _ in nil }, currentClipboardTags: { try await fixture.module.tagDefinitions() })
        try await fixture.module.closeStoreForTesting()

        let snapshot = try await service.exportCurrentSnapshot()
        let data = try BackupCodec.encode(snapshot)
        let decoded = try BackupCodec.decode(data)
        XCTAssertEqual(decoded.appShortcuts.map(\.appBundleID), ["com.example.Backup"])
        XCTAssertEqual(decoded.quicklinks.map(\.link), ["https://example.com/docs"])
        XCTAssertEqual(decoded.settings["dev.bybee.AnyDoor.language"], .string("en"))
        XCTAssertNil(decoded.settings[ClipboardHistoryPortableKeys.customTags])
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(file["omittedSections"] as? [String], ["clipboardTags"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("stale plaintext mirror"))
    }

    func testUnavailableTagsDoNotBlockIndependentRestoreOrEraseMembership() async throws {
        let fixture = try makeFixture()
        let entry = try await fixture.module.capture(.init(source: .unknown, content: .text("Protected history")))
        let retainedTag = try await fixture.module.createTagDefinition(named: "Retained", assigningTo: entry.entryID).definition
        let imported = BackupSnapshot(schemaVersion: 2, exportedAt: Date(), appVersion: "1.0", deviceName: nil,
            appShortcuts: [.init(appBundleID: "com.example.Imported", appName: "Imported", keyCode: 8,
                modifierFlags: 256, isEnabled: true, isVisible: true, displayOrder: 1)],
            builtinPreferences: [],
            quicklinks: [.init(id: UUID(), name: "Imported docs", keyword: nil, link: "https://example.com/imported",
                openWithBundleID: nil, keyCode: nil, modifierFlags: nil, isVisible: true, displayOrder: 1, createdAt: Date())],
            settings: ["dev.bybee.AnyDoor.language": .string("zh"),
                ClipboardHistoryPortableKeys.customTags: .string(try ClipboardHistoryPortableSettings.encode([
                    .init(id: "imported-tag", displayName: "Imported tag")]))])
        var reconciledLanguage: String?
        let service = BackupService(context: fixture.context, defaults: fixture.defaults,
            appPathResolver: { _ in nil },
            restoreClipboardTags: { _ = try await fixture.module.replaceTagDefinitions(with: $0) },
            reconcileRuntime: { reconciledLanguage = fixture.defaults.string(forKey: "dev.bybee.AnyDoor.language") })
        try await fixture.module.closeStoreForTesting()

        var restoreError: (any Error)?
        do {
            _ = try await service.restore(BackupCodec.decode(BackupCodec.encode(imported)))
        } catch {
            restoreError = error
        }

        let partial = try XCTUnwrap(restoreError as? BackupImportPartialFailure)
        XCTAssertEqual(partial.summary.shortcutsInserted, 1)
        XCTAssertEqual(partial.summary.quicklinksInserted, 1)
        XCTAssertEqual(partial.summary.settingsApplied, 1, "Unavailable tags must not be counted as applied")
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<KeyBinding>()).map(\.appBundleID), ["com.example.Imported"])
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<Quicklink>()).map(\.link), ["https://example.com/imported"])
        XCTAssertEqual(fixture.defaults.string(forKey: "dev.bybee.AnyDoor.language"), "zh")
        XCTAssertEqual(reconciledLanguage, "zh")
        XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
        let reopened = try trackClipboardHistoryModule(ClipboardHistoryModule(
            testingDatabaseURL: fixture.directory.appendingPathComponent("history.sqlite"),
            databaseKey: Data(repeating: 0x42, count: 32)))
        let definitions = try await reopened.tagDefinitions()
        let restoredEntry = try await reopened.page(.init()).entries.first
        XCTAssertEqual(definitions, [retainedTag])
        XCTAssertEqual(restoredEntry?.tagIDs, [retainedTag.id])
    }

    func testSameNameTagBackupRequiresNewReaderAndPreservesIdentities() async throws {
        let fixture = try makeFixture()
        let entry = try await fixture.module.capture(.init(source: .unknown, content: .text("Retained membership")))
        let first = try await fixture.module.createTagDefinition(named: "Work", assigningTo: entry.entryID).definition
        let definitions = [first, ClipboardHistoryTagDefinition(id: "independent-work", displayName: "Work")]
        _ = try await fixture.module.replaceTagDefinitions(with: definitions)
        let service = BackupService(context: fixture.context, defaults: fixture.defaults,
            appPathResolver: { _ in nil }, currentClipboardTags: { try await fixture.module.tagDefinitions() },
            restoreClipboardTags: { _ = try await fixture.module.replaceTagDefinitions(with: $0) }, reconcileRuntime: {})

        let data = try await BackupCodec.encode(service.exportCurrentSnapshot())
        XCTAssertThrowsError(try VersionTwoBackupCodec.decode(data)) { error in
            XCTAssertEqual(error as? VersionTwoBackupCodec.ReadError, .unsupportedSchemaVersion(3))
        }
        _ = try await fixture.module.renameTagDefinition(id: first.id, to: "Changed")
        _ = try await service.restore(BackupCodec.decode(data))
        let restored = try await fixture.module.tagDefinitions()
        let restoredEntry = try await fixture.module.page(.init()).entries.first
        XCTAssertEqual(restored, definitions)
        XCTAssertEqual(restoredEntry?.tagIDs, [first.id])

        _ = try await fixture.module.renameTagDefinition(id: first.id, to: "Unique")
        let compatible = try await BackupCodec.encode(service.exportCurrentSnapshot())
        XCTAssertEqual(try VersionTwoBackupCodec.decode(compatible).schemaVersion, 2)
    }

    func testOmittedOrMalformedBackupTagsPreserveExistingDefinitions() async throws {
        let fixture = try makeFixture()
        let entry = try await fixture.module.capture(.init(source: .unknown, content: .text("Protected history")))
        let tag = try await fixture.module.createTagDefinition(named: "Kept", assigningTo: entry.entryID).definition
        let service = BackupService(context: fixture.context, defaults: fixture.defaults,
            appPathResolver: { _ in nil },
            restoreClipboardTags: { _ = try await fixture.module.replaceTagDefinitions(with: $0) }, reconcileRuntime: {})
        var omitted = try service.exportSnapshot()
        omitted.settings["dev.bybee.AnyDoor.language"] = .string("en")
        omitted.omittedSections = [.clipboardTags]
        var malformed = try service.exportSnapshot()
        malformed.settings["dev.bybee.AnyDoor.language"] = .string("zh")
        malformed.settings[ClipboardHistoryPortableKeys.customTags] = .string("not valid tag JSON")

        for snapshot in [omitted, malformed] {
            do {
                _ = try await service.restore(BackupCodec.decode(BackupCodec.encode(snapshot)))
                XCTFail("Unavailable backup tags must not be presented as a complete import")
            } catch let partial as BackupImportPartialFailure {
                XCTAssertEqual(partial.summary.settingsApplied, 1)
                XCTAssertNil(partial.runtimeError)
            }
            let definitions = try await fixture.module.tagDefinitions()
            let retained = try await fixture.module.page(.init()).entries.first
            XCTAssertEqual(definitions, [tag])
            XCTAssertEqual(retained?.tagIDs, [tag.id])
            XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
        }
        XCTAssertEqual(fixture.defaults.string(forKey: "dev.bybee.AnyDoor.language"), "zh")
    }

    func testMissingTagSectionKeepsTagsWhileExplicitEmptySectionRemovesThem() async throws {
        let fixture = try makeFixture()
        let entry = try await fixture.module.capture(.init(source: .unknown, content: .text("Kept entry")))
        let tag = try await fixture.module.createTagDefinition(named: "Local", assigningTo: entry.entryID).definition
        let service = BackupService(context: fixture.context, defaults: fixture.defaults,
            appPathResolver: { _ in nil },
            restoreClipboardTags: { _ = try await fixture.module.replaceTagDefinitions(with: $0) }, reconcileRuntime: {})
        var snapshot = try service.exportSnapshot()
        _ = try await service.restore(BackupCodec.decode(BackupCodec.encode(snapshot)))
        let unchanged = try await fixture.module.tagDefinitions()
        XCTAssertEqual(unchanged, [tag])

        snapshot.settings[ClipboardHistoryPortableKeys.customTags] = .string("[]")
        _ = try await service.restore(BackupCodec.decode(BackupCodec.encode(snapshot)))
        let cleared = try await fixture.module.tagDefinitions()
        let retained = try await fixture.module.page(.init()).entries.first
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertEqual(retained?.tagIDs, [])
        XCTAssertEqual(retained?.id, entry.entryID)
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup-availability-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeClipboardHistoryDirectoryAfterTest(directory)
        let module = try trackClipboardHistoryModule(ClipboardHistoryModule(
            testingDatabaseURL: directory.appendingPathComponent("history.sqlite"),
            databaseKey: Data(repeating: 0x42, count: 32)))
        let container = try ModelContainer(for: Schema([KeyBinding.self, BuiltinPreference.self, Quicklink.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return Fixture(directory: directory, module: module, container: container,
            defaults: makeTemporaryDefaults())
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let module: ClipboardHistoryModule
        let container: ModelContainer
        let defaults: UserDefaults
        var context: ModelContext { container.mainContext }
    }
}

// The schema-2 reader gate and required payload fields from base 26f705d7.
// Keep its supported version fixed: this represents an already shipped reader.
private enum VersionTwoBackupCodec {
    enum ReadError: Error, Equatable {
        case unsupportedSchemaVersion(Int)
    }

    struct Snapshot: Decodable {
        let schemaVersion: Int
        let exportedAt: Date
        let appVersion: String
        let deviceName: String?
        let appShortcuts: [AppShortcutDTO]
        let builtinPreferences: [BuiltinPreferenceDTO]
        let quicklinks: [QuicklinkDTO]?
        let settings: [String: SettingValue]
    }

    static func decode(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        guard snapshot.schemaVersion <= 2 else {
            throw ReadError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        return snapshot
    }
}
