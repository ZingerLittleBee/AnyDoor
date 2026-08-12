import SwiftData
import XCTest
@testable import AnyDoor

/// Script Plugin install state and private storage are machine-local: their
/// packages exist only on the local disk, so a restore on another machine must
/// never claim to restore them (user story 17). This pins the exclusion at the
/// two seams a backup flows through — the settings whitelist and the exported
/// snapshot.
final class ScriptPluginBackupExclusionTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "ScriptBackupExclusion.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testScriptInstallStateKeyIsNotWhitelisted() {
        let keys = Set(SyncSettingsRegistry.entries.map(\.key))
        XCTAssertFalse(keys.contains(ScriptPluginRegistry.installStateKey))
        // The Native install-state key stays whitelisted — only the Script kind
        // is excluded.
        XCTAssertTrue(keys.contains(PluginRegistry.installStateKey))
    }

    func testWhitelistNeitherReadsNorWritesTheScriptKey() {
        let source = makeDefaults()
        source.set(["com.acme.rows"], forKey: ScriptPluginRegistry.installStateKey)

        // Export path: read never captures a non-whitelisted key.
        let captured = SyncSettingsRegistry.read(from: source)
        XCTAssertNil(captured[ScriptPluginRegistry.installStateKey])

        // Import path: even if a crafted snapshot carried the key, write ignores it.
        let destination = makeDefaults()
        SyncSettingsRegistry.write(
            [ScriptPluginRegistry.installStateKey: .stringArray(["com.acme.rows"])],
            to: destination
        )
        XCTAssertNil(destination.stringArray(forKey: ScriptPluginRegistry.installStateKey))
    }

    @MainActor
    func testExportedSnapshotNeverContainsScriptInstallState() throws {
        let container = try ModelContainer(
            for: Schema([
                KeyBinding.self,
                BuiltinPreference.self,
                Quicklink.self,
            ]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
        )
        let context = ModelContext(container)

        let defaults = makeDefaults()
        // Both keys set; only the Native one may travel.
        defaults.set(["hosts"], forKey: PluginRegistry.installStateKey)
        defaults.set(["com.acme.rows"], forKey: ScriptPluginRegistry.installStateKey)

        let service = BackupService(context: context, defaults: defaults, appPathResolver: { _ in nil })
        let snapshot = try service.exportSnapshot()

        XCTAssertNil(snapshot.settings[ScriptPluginRegistry.installStateKey])
        XCTAssertEqual(snapshot.settings[PluginRegistry.installStateKey], .stringArray(["hosts"]))
    }
}
