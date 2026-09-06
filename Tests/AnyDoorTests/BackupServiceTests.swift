import XCTest
import SwiftData
@testable import AnyDoor

final class BackupServiceTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            KeyBinding.self,
            BuiltinPreference.self,
            Quicklink.self,
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
        let snapshot = try service.exportSnapshot()

        XCTAssertEqual(snapshot.schemaVersion, BackupSnapshot.currentSchemaVersion)
        XCTAssertEqual(snapshot.appShortcuts.count, 1)
        XCTAssertEqual(snapshot.appShortcuts.first?.appBundleID, "com.apple.Safari")
        XCTAssertEqual(snapshot.builtinPreferences.first?.itemKey, "darkMode")
        XCTAssertTrue(snapshot.quicklinks.isEmpty)
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
        let snapshot = try service.exportSnapshot()
        XCTAssertEqual(snapshot.appShortcuts.count, 1)
        XCTAssertEqual(snapshot.appShortcuts.first?.appBundleID, "com.apple.Safari")

        // The serialized JSON must contain no trace of the foreign-username path.
        let data = try BackupCodec.encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("/Users/alice"))
        XCTAssertFalse(json.contains("Applications/Safari.app"))
    }

    @MainActor
    func testClipboardBackupCarriesOnlyPortableDefinitionsAndRules()
        throws
    {
        let context = try makeContext()
        let defaults = makeDefaults()
        defaults.set(
            "[{\"id\":\"work\",\"name\":\"Work\"}]",
            forKey: ClipboardHistoryPortableKeys.customTags
        )
        defaults.set(
            "[\"all\",\"tag:work\"]",
            forKey: ClipboardCategoryOrder.defaultsKey
        )
        defaults.set(
            ["com.apple.Passwords"],
            forKey: ClipboardPreferences.excludedKey
        )
        defaults.set(
            true,
            forKey: ClipboardPreferences.ignoresUniversalClipboardKey
        )
        defaults.set(false, forKey: ClipboardPreferences.monitoringKey)
        defaults.set(true, forKey: ClipboardPreferences.copyOnlyKey)
        defaults.set(1, forKey: ClipboardPreferences.retentionKey)
        defaults.set(
            "device-only-key-material",
            forKey: "clipboard.encryptionKey"
        )
        defaults.set(
            "device-only-migration-state",
            forKey: "clipboard.migrationState"
        )
        defaults.set(
            "device-only-secret",
            forKey: "clipboard.historyPayload"
        )

        let snapshot = try BackupService(
            context: context,
            defaults: defaults,
            appPathResolver: { _ in nil }
        ).exportSnapshot()

        XCTAssertNotNil(
            snapshot.settings[ClipboardHistoryPortableKeys.customTags]
        )
        XCTAssertNotNil(
            snapshot.settings[ClipboardCategoryOrder.defaultsKey]
        )
        XCTAssertNotNil(
            snapshot.settings[ClipboardPreferences.excludedKey]
        )
        XCTAssertEqual(
            snapshot.settings[
                ClipboardPreferences.ignoresUniversalClipboardKey
            ],
            .bool(true)
        )
        XCTAssertNil(
            snapshot.settings[ClipboardPreferences.monitoringKey]
        )
        XCTAssertNil(snapshot.settings[ClipboardPreferences.copyOnlyKey])
        XCTAssertNil(snapshot.settings[ClipboardPreferences.retentionKey])

        let encoded = try BackupCodec.encode(snapshot)
        let json = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)
        )
        XCTAssertFalse(json.contains("device-only-secret"))
        XCTAssertFalse(json.contains("device-only-key-material"))
        XCTAssertFalse(json.contains("device-only-migration-state"))
    }

    @MainActor
    func testRestoreNeverChangesLocalClipboardMonitoringState()
        async throws
    {
        let context = try makeContext()
        let defaults = makeDefaults()
        ClipboardPreferences.setMonitoringEnabled(true, in: defaults)
        let imported = snapshot(
            settings: [
                ClipboardPreferences.monitoringKey: .bool(false),
                ClipboardPreferences.excludedKey:
                    .stringArray(["com.example.Secret"]),
            ]
        )
        let service = BackupService(
            context: context,
            defaults: defaults,
            appPathResolver: { _ in nil },
            reconcileRuntime: {}
        )

        _ = try await service.restore(imported)

        XCTAssertTrue(
            ClipboardPreferences.monitoringEnabled(from: defaults)
        )
        XCTAssertEqual(
            ClipboardPreferences.excludedBundleIDs(from: defaults),
            ["com.example.Secret"]
        )
    }

    @MainActor
    func testExportCollectsQuicklinksWithoutFaviconCache() throws {
        let context = try makeContext()
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_123)
        context.insert(Quicklink(
            id: id,
            name: "GitHub Search",
            keyword: "gh",
            link: "https://github.com/search?q={query}",
            openWithBundleID: "com.apple.Safari",
            keyCode: 5,
            modifierFlags: 786_432,
            isVisible: false,
            displayOrder: 300,
            createdAt: createdAt
        ))
        try context.save()

        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil })
        let snapshot = try service.exportSnapshot()

        let quicklink = try XCTUnwrap(snapshot.quicklinks.first)
        XCTAssertEqual(quicklink.id, id)
        XCTAssertEqual(quicklink.name, "GitHub Search")
        XCTAssertEqual(quicklink.keyword, "gh")
        XCTAssertEqual(quicklink.link, "https://github.com/search?q={query}")
        XCTAssertEqual(quicklink.openWithBundleID, "com.apple.Safari")
        XCTAssertEqual(quicklink.keyCode, 5)
        XCTAssertEqual(quicklink.modifierFlags, 786_432)
        XCTAssertEqual(quicklink.isVisible, false)
        XCTAssertEqual(quicklink.displayOrder, 300)
        XCTAssertEqual(quicklink.createdAt, createdAt)

        let json = try XCTUnwrap(String(data: BackupCodec.encode(snapshot), encoding: .utf8))
        XCTAssertFalse(json.contains("favicon"))
    }

    // MARK: - Import tests

    private func snapshot(
        shortcuts: [AppShortcutDTO] = [],
        prefs: [BuiltinPreferenceDTO] = [],
        quicklinks: [QuicklinkDTO] = [],
        settings: [String: SettingValue] = [:]
    ) -> BackupSnapshot {
        BackupSnapshot(
            schemaVersion: BackupSnapshot.currentSchemaVersion,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.0", deviceName: nil,
            appShortcuts: shortcuts, builtinPreferences: prefs,
            quicklinks: quicklinks, settings: settings
        )
    }

    @MainActor
    func testRestoreWaitsForRuntimeReconciliation() async throws {
        let context = try makeContext()
        var didReconcile = false
        let service = BackupService(
            context: context,
            defaults: makeDefaults(),
            appPathResolver: { _ in nil },
            reconcileRuntime: {
                await Task.yield()
                didReconcile = true
            }
        )

        let summary = try await service.restore(snapshot(shortcuts: [
            AppShortcutDTO(
                appBundleID: "com.example.App",
                appName: "Example",
                keyCode: 4,
                modifierFlags: 256,
                isEnabled: true,
                isVisible: true,
                displayOrder: 100
            ),
        ]))

        XCTAssertTrue(didReconcile)
        XCTAssertEqual(summary.shortcutsInserted, 1)
    }

    @MainActor
    func testRestoreSurfacesRuntimeFailureAfterApplyingSnapshot() async throws {
        struct ReconcileFailure: Error {}

        let context = try makeContext()
        let service = BackupService(
            context: context,
            defaults: makeDefaults(),
            appPathResolver: { _ in nil },
            reconcileRuntime: { throw ReconcileFailure() }
        )

        do {
            _ = try await service.restore(snapshot(shortcuts: [
                AppShortcutDTO(
                    appBundleID: "com.example.App",
                    appName: "Example",
                    keyCode: 4,
                    modifierFlags: 256,
                    isEnabled: true,
                    isVisible: true,
                    displayOrder: 100
                ),
            ]))
            XCTFail("runtime reconciliation failure must be surfaced")
        } catch {
            XCTAssertTrue(error is ReconcileFailure)
        }

        XCTAssertEqual(
            try context.fetch(FetchDescriptor<KeyBinding>()).map(\.appBundleID),
            ["com.example.App"],
            "the persisted import is retained even when a live subsystem cannot converge"
        )
    }

    @MainActor
    func testImportInsertsNewShortcutAndResolvesPath() async throws {
        let context = try makeContext()
        let service = BackupService(
            context: context, defaults: makeDefaults(),
            appPathResolver: { id in id == "com.apple.Safari" ? "/Applications/Safari.app" : nil },
            reconcileRuntime: {}
        )

        let summary = try await service.restore(snapshot(shortcuts: [
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
    func testImportInsertsShortcutWithEmptyPathWhenAppMissing() async throws {
        let context = try makeContext()
        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil }, reconcileRuntime: {})
        let summary = try await service.restore(snapshot(shortcuts: [
            AppShortcutDTO(appBundleID: "com.unknown.App", appName: "Unknown",
                           keyCode: 4, modifierFlags: 256,
                           isEnabled: true, isVisible: true, displayOrder: 100)
        ]))
        XCTAssertEqual(summary.shortcutsInserted, 1)
        let rows = try context.fetch(FetchDescriptor<KeyBinding>())
        XCTAssertEqual(rows.first?.appPath, "")
    }

    @MainActor
    func testImportUpdatesExistingShortcutByBundleIDAndReresolvesPath() async throws {
        let context = try makeContext()
        context.insert(KeyBinding(keyCode: 0, modifierFlags: 0,
                                  appBundleID: "com.apple.Safari", appName: "Old Safari",
                                  appPath: "/Users/bob/Applications/Safari.app",
                                  isEnabled: false, isVisible: true, displayOrder: 999))
        try context.save()

        let service = BackupService(
            context: context, defaults: makeDefaults(),
            appPathResolver: { _ in "/Applications/Safari.app" },
            reconcileRuntime: {}
        )
        let summary = try await service.restore(snapshot(shortcuts: [
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
    func testImportKeepsLocalOnlyShortcuts() async throws {
        let context = try makeContext()
        context.insert(KeyBinding(keyCode: 5, modifierFlags: 256,
                                  appBundleID: "com.local.Only", appName: "Local",
                                  appPath: "/Applications/Local.app",
                                  isEnabled: true, isVisible: true, displayOrder: 100))
        try context.save()

        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil }, reconcileRuntime: {})
        _ = try await service.restore(snapshot(shortcuts: [
            AppShortcutDTO(appBundleID: "com.other.App", appName: "Other",
                           keyCode: 4, modifierFlags: 256,
                           isEnabled: true, isVisible: true, displayOrder: 200)
        ]))

        let ids = try context.fetch(FetchDescriptor<KeyBinding>()).map(\.appBundleID).sorted()
        XCTAssertEqual(ids, ["com.local.Only", "com.other.App"])
    }

    @MainActor
    func testImportUpdatesExistingPreferenceByItemKey() async throws {
        let context = try makeContext()
        context.insert(BuiltinPreference(itemKey: "darkMode", isVisible: false,
                                         displayOrder: 999, keyCode: nil, modifierFlags: nil))
        try context.save()

        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil }, reconcileRuntime: {})
        let summary = try await service.restore(snapshot(prefs: [
            BuiltinPreferenceDTO(itemKey: "darkMode", isVisible: true,
                                 displayOrder: 100, keyCode: 2, modifierFlags: 256)
        ]))

        XCTAssertEqual(summary.preferencesUpdated, 1)
        let pref = try context.fetch(FetchDescriptor<BuiltinPreference>()).first
        XCTAssertEqual(pref?.isVisible, true)
        XCTAssertEqual(pref?.keyCode, 2)
    }

    @MainActor
    func testImportSkipsPreferenceWithUnknownItemKey() async throws {
        let context = try makeContext()
        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil }, reconcileRuntime: {})
        let summary = try await service.restore(snapshot(prefs: [
            BuiltinPreferenceDTO(itemKey: "darkMode", isVisible: true,
                                 displayOrder: 100, keyCode: nil, modifierFlags: nil)
        ]))
        XCTAssertEqual(summary.preferencesUpdated, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<BuiltinPreference>()).count, 0)
    }

    @MainActor
    func testImportUpdatesExistingQuicklinkByIDAndKeepsLocalOnlyRows() async throws {
        let context = try makeContext()
        let importedID = UUID()
        let localOnlyID = UUID()
        let importedCreatedAt = Date(timeIntervalSince1970: 1_700_000_200)
        context.insert(Quicklink(
            id: importedID,
            name: "Old",
            keyword: "old",
            link: "https://old.example",
            openWithBundleID: nil,
            keyCode: nil,
            modifierFlags: nil,
            isVisible: true,
            displayOrder: 999,
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        context.insert(Quicklink(
            id: localOnlyID,
            name: "Local Only",
            keyword: "local",
            link: "https://local.example",
            openWithBundleID: nil,
            keyCode: nil,
            modifierFlags: nil,
            isVisible: true,
            displayOrder: 200,
            createdAt: Date(timeIntervalSince1970: 2)
        ))
        try context.save()

        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil }, reconcileRuntime: {})
        let summary = try await service.restore(snapshot(quicklinks: [
            QuicklinkDTO(
                id: importedID,
                name: "GitHub Search",
                keyword: "gh",
                link: "https://github.com/search?q={query}",
                openWithBundleID: "com.apple.Safari",
                keyCode: 5,
                modifierFlags: 786_432,
                isVisible: false,
                displayOrder: 100,
                createdAt: importedCreatedAt
            )
        ]))

        XCTAssertEqual(summary.quicklinksUpdated, 1)
        XCTAssertEqual(summary.quicklinksInserted, 0)
        let rows = try context.fetch(FetchDescriptor<Quicklink>())
        XCTAssertEqual(rows.count, 2)
        let imported = try XCTUnwrap(rows.first { $0.id == importedID })
        XCTAssertEqual(imported.name, "GitHub Search")
        XCTAssertEqual(imported.keyword, "gh")
        XCTAssertEqual(imported.link, "https://github.com/search?q={query}")
        XCTAssertEqual(imported.openWithBundleID, "com.apple.Safari")
        XCTAssertEqual(imported.keyCode, 5)
        XCTAssertEqual(imported.modifierFlags, 786_432)
        XCTAssertFalse(imported.isVisible)
        XCTAssertEqual(imported.displayOrder, 100)
        XCTAssertEqual(imported.createdAt, importedCreatedAt)
        let localOnly = try XCTUnwrap(rows.first { $0.id == localOnlyID })
        XCTAssertEqual(localOnly.name, "Local Only")
        XCTAssertEqual(localOnly.keyword, "local")
    }

    @MainActor
    func testImportQuicklinkKeywordCollisionClearsLocalKeywordAndKeepsBothRows() async throws {
        let context = try makeContext()
        let importedID = UUID()
        let localID = UUID()
        context.insert(Quicklink(
            id: localID,
            name: "Local",
            keyword: "GH",
            link: "https://local.example",
            displayOrder: 100
        ))
        try context.save()

        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil }, reconcileRuntime: {})
        let summary = try await service.restore(snapshot(quicklinks: [
            QuicklinkDTO(
                id: importedID,
                name: "Imported",
                keyword: "gh",
                link: "https://imported.example",
                openWithBundleID: nil,
                keyCode: nil,
                modifierFlags: nil,
                isVisible: true,
                displayOrder: 200,
                createdAt: Date(timeIntervalSince1970: 3)
            )
        ]))

        XCTAssertEqual(summary.quicklinksInserted, 1)
        let rows = try context.fetch(FetchDescriptor<Quicklink>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.id == importedID }?.keyword, "gh")
        XCTAssertNil(rows.first { $0.id == localID }?.keyword)
    }

    @MainActor
    func testImportedQuicklinkHotkeyCompilesWithoutRelaunch() async throws {
        let context = try makeContext()
        let id = UUID()
        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil }, reconcileRuntime: {})
        _ = try await service.restore(snapshot(quicklinks: [
            QuicklinkDTO(
                id: id,
                name: "Docs",
                keyword: nil,
                link: "https://docs.example",
                openWithBundleID: nil,
                keyCode: 11,
                modifierFlags: 786_432,
                isVisible: false,
                displayOrder: 100,
                createdAt: Date(timeIntervalSince1970: 4)
            )
        ]))

        let quicklinks = try context.fetch(FetchDescriptor<Quicklink>())
        let snapshots = HotkeyCoordinator.compile(
            bindings: [],
            prefs: [],
            quicklinks: quicklinks,
            paletteHotkey: nil
        )
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.action, .openQuicklink(id: id))
    }

    @MainActor
    func testOldSchemaImportLeavesLocalQuicklinksUntouched() async throws {
        let context = try makeContext()
        let localID = UUID()
        context.insert(Quicklink(
            id: localID,
            name: "Local",
            keyword: "local",
            link: "https://local.example",
            displayOrder: 100
        ))
        try context.save()

        let json = """
        {
          "appShortcuts": [],
          "appVersion": "1.0",
          "builtinPreferences": [],
          "deviceName": "Old-Mac",
          "exportedAt": "2023-11-14T22:13:20Z",
          "schemaVersion": 1,
          "settings": {}
        }
        """
        let oldSnapshot = try BackupCodec.decode(Data(json.utf8))
        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil }, reconcileRuntime: {})
        _ = try await service.restore(oldSnapshot)

        let rows = try context.fetch(FetchDescriptor<Quicklink>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, localID)
        XCTAssertEqual(rows.first?.keyword, "local")
    }

    @MainActor
    func testImportAppliesSettings() async throws {
        let context = try makeContext()
        let defaults = makeDefaults()
        let service = BackupService(context: context, defaults: defaults,
                                    appPathResolver: { _ in nil }, reconcileRuntime: {})
        let summary = try await service.restore(snapshot(
            settings: ["menuBar.iconVisible": .bool(false),
                       "dev.bybee.AnyDoor.language": .string("en")]
        ))
        XCTAssertEqual(summary.settingsApplied, 2)
        XCTAssertEqual(defaults.bool(forKey: "menuBar.iconVisible"), false)
        XCTAssertEqual(defaults.string(forKey: "dev.bybee.AnyDoor.language"), "en")
    }

    @MainActor
    func testExportIncludesInstalledPluginSet() throws {
        let context = try makeContext()
        let defaults = makeDefaults()
        defaults.set(["hosts"], forKey: PluginRegistry.installStateKey)

        let service = BackupService(context: context, defaults: defaults,
                                    appPathResolver: { _ in nil })
        let snapshot = try service.exportSnapshot()

        XCTAssertEqual(snapshot.settings[PluginRegistry.installStateKey],
                       .stringArray(["hosts"]))
    }

    @MainActor
    func testImportWritesInstalledPluginSet() async throws {
        let context = try makeContext()
        let defaults = makeDefaults()
        let service = BackupService(context: context, defaults: defaults,
                                    appPathResolver: { _ in nil }, reconcileRuntime: {})

        _ = try await service.restore(snapshot(
            settings: [PluginRegistry.installStateKey: .stringArray(["hosts"])]
        ))

        XCTAssertEqual(defaults.stringArray(forKey: PluginRegistry.installStateKey),
                       ["hosts"])
    }

    @MainActor
    func testImportSettingsAppliedCountExcludesNonWhitelistedKeys() async throws {
        let context = try makeContext()
        let defaults = makeDefaults()
        let service = BackupService(context: context, defaults: defaults,
                                    appPathResolver: { _ in nil }, reconcileRuntime: {})
        let summary = try await service.restore(snapshot(
            settings: ["menuBar.iconVisible": .bool(true),
                       "SUSkippedVersion": .string("9.9.9")]
        ))
        XCTAssertEqual(summary.settingsApplied, 1)
        XCTAssertNil(defaults.string(forKey: "SUSkippedVersion"))
    }

    @MainActor
    func testCommandPaletteReloadFromDefaultsPicksUpWrittenHotkey() {
        UserDefaults.standard.removeObject(forKey: "commandPalette.hotkey.keyCode")
        UserDefaults.standard.removeObject(forKey: "commandPalette.hotkey.modifierFlags")
        defer {
            UserDefaults.standard.removeObject(forKey: "commandPalette.hotkey.keyCode")
            UserDefaults.standard.removeObject(forKey: "commandPalette.hotkey.modifierFlags")
        }
        UserDefaults.standard.set(49, forKey: "commandPalette.hotkey.keyCode")
        UserDefaults.standard.set(256, forKey: "commandPalette.hotkey.modifierFlags")

        CommandPaletteService.shared.reloadFromDefaults()

        XCTAssertEqual(CommandPaletteService.shared.hotkey?.keyCode, 49)
        XCTAssertEqual(CommandPaletteService.shared.hotkey?.modifierFlags, 256)
    }
}
