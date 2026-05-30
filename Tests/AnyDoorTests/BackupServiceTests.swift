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
}
