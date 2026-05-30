import XCTest
import SwiftData
@testable import AnyDoor

final class BackupServiceTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            KeyBinding.self,
            BuiltinPreference.self,
            ClipboardHistoryItem.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @MainActor
    func testExportCollectsShortcutsPreferencesAndSettings() throws {
        let context = try makeContext()
        context.insert(KeyBinding(keyCode: 4, modifierFlags: 256,
                                  appBundleID: "com.apple.Safari", appName: "Safari",
                                  appPath: "/Applications/Safari.app",
                                  isEnabled: true, isVisible: true, displayOrder: 100))
        context.insert(BuiltinPreference(itemKey: "darkMode", isVisible: true,
                                         displayOrder: 200, keyCode: 2, modifierFlags: 256))
        try context.save()

        let defaults = makeDefaults()
        defaults.set("zh", forKey: "dev.bybee.AnyDoor.language")

        let service = BackupService(context: context, defaults: defaults,
                                    appPathResolver: { _ in nil })
        let snapshot = service.exportSnapshot()

        XCTAssertEqual(snapshot.schemaVersion, BackupSnapshot.currentSchemaVersion)
        XCTAssertEqual(snapshot.appShortcuts.count, 1)
        XCTAssertEqual(snapshot.appShortcuts.first?.appBundleID, "com.apple.Safari")
        XCTAssertEqual(snapshot.builtinPreferences.first?.itemKey, "darkMode")
        XCTAssertEqual(snapshot.settings["dev.bybee.AnyDoor.language"], .string("zh"))
    }

    @MainActor
    func testExportOmitsAppPath() throws {
        // AppShortcutDTO has no appPath property — this is a compile-time guarantee.
        // Behaviorally verify the omission: a machine-specific path must never
        // leak into the serialized snapshot, only the portable bundle ID survives.
        let context = try makeContext()
        context.insert(KeyBinding(keyCode: 4, modifierFlags: 256,
                                  appBundleID: "com.apple.Safari", appName: "Safari",
                                  appPath: "/Users/alice/Applications/Safari.app",
                                  isEnabled: true, isVisible: true, displayOrder: 100))
        try context.save()

        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil })
        let snapshot = service.exportSnapshot()
        XCTAssertEqual(snapshot.appShortcuts.count, 1)
        XCTAssertEqual(snapshot.appShortcuts.first?.appBundleID, "com.apple.Safari")

        // The serialized JSON must contain no trace of the foreign-username path.
        let data = try BackupCodec.encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("/Users/alice"))
        XCTAssertFalse(json.contains("Applications/Safari.app"))
    }

    // MARK: - Import tests

    private func snapshot(
        shortcuts: [AppShortcutDTO] = [],
        prefs: [BuiltinPreferenceDTO] = [],
        settings: [String: SettingValue] = [:]
    ) -> BackupSnapshot {
        BackupSnapshot(
            schemaVersion: BackupSnapshot.currentSchemaVersion,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.0", deviceName: nil,
            appShortcuts: shortcuts, builtinPreferences: prefs, settings: settings
        )
    }

    @MainActor
    func testImportInsertsNewShortcutAndResolvesPath() throws {
        let context = try makeContext()
        let service = BackupService(
            context: context, defaults: makeDefaults(),
            appPathResolver: { id in id == "com.apple.Safari" ? "/Applications/Safari.app" : nil }
        )

        let summary = try service.importSnapshot(snapshot(shortcuts: [
            AppShortcutDTO(appBundleID: "com.apple.Safari", appName: "Safari",
                           keyCode: 4, modifierFlags: 256,
                           isEnabled: true, isVisible: true, displayOrder: 100)
        ]))

        XCTAssertEqual(summary.shortcutsInserted, 1)
        let rows = try context.fetch(FetchDescriptor<KeyBinding>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.appPath, "/Applications/Safari.app")
    }

    @MainActor
    func testImportInsertsShortcutWithEmptyPathWhenAppMissing() throws {
        let context = try makeContext()
        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil })
        let summary = try service.importSnapshot(snapshot(shortcuts: [
            AppShortcutDTO(appBundleID: "com.unknown.App", appName: "Unknown",
                           keyCode: 4, modifierFlags: 256,
                           isEnabled: true, isVisible: true, displayOrder: 100)
        ]))
        XCTAssertEqual(summary.shortcutsInserted, 1)
        let rows = try context.fetch(FetchDescriptor<KeyBinding>())
        XCTAssertEqual(rows.first?.appPath, "")
    }

    @MainActor
    func testImportUpdatesExistingShortcutByBundleIDAndReresolvesPath() throws {
        let context = try makeContext()
        context.insert(KeyBinding(keyCode: 0, modifierFlags: 0,
                                  appBundleID: "com.apple.Safari", appName: "Old Safari",
                                  appPath: "/Users/bob/Applications/Safari.app",
                                  isEnabled: false, isVisible: true, displayOrder: 999))
        try context.save()

        let service = BackupService(
            context: context, defaults: makeDefaults(),
            appPathResolver: { _ in "/Applications/Safari.app" }
        )
        let summary = try service.importSnapshot(snapshot(shortcuts: [
            AppShortcutDTO(appBundleID: "com.apple.Safari", appName: "Safari",
                           keyCode: 4, modifierFlags: 256,
                           isEnabled: true, isVisible: true, displayOrder: 100)
        ]))

        XCTAssertEqual(summary.shortcutsUpdated, 1)
        XCTAssertEqual(summary.shortcutsInserted, 0)
        let rows = try context.fetch(FetchDescriptor<KeyBinding>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.keyCode, 4)
        XCTAssertEqual(rows.first?.appName, "Safari")
        XCTAssertEqual(rows.first?.isEnabled, true)
        XCTAssertEqual(rows.first?.appPath, "/Applications/Safari.app")
    }

    @MainActor
    func testImportKeepsLocalOnlyShortcuts() throws {
        let context = try makeContext()
        context.insert(KeyBinding(keyCode: 5, modifierFlags: 256,
                                  appBundleID: "com.local.Only", appName: "Local",
                                  appPath: "/Applications/Local.app",
                                  isEnabled: true, isVisible: true, displayOrder: 100))
        try context.save()

        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil })
        _ = try service.importSnapshot(snapshot(shortcuts: [
            AppShortcutDTO(appBundleID: "com.other.App", appName: "Other",
                           keyCode: 4, modifierFlags: 256,
                           isEnabled: true, isVisible: true, displayOrder: 200)
        ]))

        let ids = try context.fetch(FetchDescriptor<KeyBinding>()).map(\.appBundleID).sorted()
        XCTAssertEqual(ids, ["com.local.Only", "com.other.App"])
    }

    @MainActor
    func testImportUpdatesExistingPreferenceByItemKey() throws {
        let context = try makeContext()
        context.insert(BuiltinPreference(itemKey: "darkMode", isVisible: false,
                                         displayOrder: 999, keyCode: nil, modifierFlags: nil))
        try context.save()

        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil })
        let summary = try service.importSnapshot(snapshot(prefs: [
            BuiltinPreferenceDTO(itemKey: "darkMode", isVisible: true,
                                 displayOrder: 100, keyCode: 2, modifierFlags: 256)
        ]))

        XCTAssertEqual(summary.preferencesUpdated, 1)
        let pref = try context.fetch(FetchDescriptor<BuiltinPreference>()).first
        XCTAssertEqual(pref?.isVisible, true)
        XCTAssertEqual(pref?.keyCode, 2)
    }

    @MainActor
    func testImportSkipsPreferenceWithUnknownItemKey() throws {
        let context = try makeContext()
        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil })
        let summary = try service.importSnapshot(snapshot(prefs: [
            BuiltinPreferenceDTO(itemKey: "darkMode", isVisible: true,
                                 displayOrder: 100, keyCode: nil, modifierFlags: nil)
        ]))
        XCTAssertEqual(summary.preferencesUpdated, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<BuiltinPreference>()).count, 0)
    }

    @MainActor
    func testImportAppliesSettings() throws {
        let context = try makeContext()
        let defaults = makeDefaults()
        let service = BackupService(context: context, defaults: defaults,
                                    appPathResolver: { _ in nil })
        let summary = try service.importSnapshot(snapshot(
            settings: ["menuBar.iconVisible": .bool(false),
                       "dev.bybee.AnyDoor.language": .string("en")]
        ))
        XCTAssertEqual(summary.settingsApplied, 2)
        XCTAssertEqual(defaults.bool(forKey: "menuBar.iconVisible"), false)
        XCTAssertEqual(defaults.string(forKey: "dev.bybee.AnyDoor.language"), "en")
    }

    @MainActor
    func testImportSettingsAppliedCountExcludesNonWhitelistedKeys() throws {
        let context = try makeContext()
        let defaults = makeDefaults()
        let service = BackupService(context: context, defaults: defaults,
                                    appPathResolver: { _ in nil })
        let summary = try service.importSnapshot(snapshot(
            settings: ["menuBar.iconVisible": .bool(true),
                       "SUSkippedVersion": .string("9.9.9")]
        ))
        XCTAssertEqual(summary.settingsApplied, 1)
        XCTAssertNil(defaults.string(forKey: "SUSkippedVersion"))
    }
}
