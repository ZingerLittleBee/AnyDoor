import XCTest
@testable import AnyDoor

final class SyncSettingsRegistryTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "SyncSettingsRegistryTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testExcludesMachineSpecificKeys() {
        let keys = Set(SyncSettingsRegistry.entries.map(\.key))
        XCTAssertFalse(keys.contains("hyperKey.ownedSignatures"))
        XCTAssertFalse(keys.contains("PortInventory.viewMode"))
        XCTAssertFalse(keys.contains("SUSkippedVersion"))
    }

    func testIncludesExpectedPortableKeys() {
        let keys = Set(SyncSettingsRegistry.entries.map(\.key))
        XCTAssertTrue(keys.contains("menuBar.iconVisible"))
        XCTAssertTrue(keys.contains("hyperKey.trigger"))
        XCTAssertTrue(keys.contains("dev.bybee.AnyDoor.language"))
        XCTAssertTrue(keys.contains("clipboard.excludedBundleIDs"))
    }

    func testIncludesInstalledPluginSet() {
        let entry = SyncSettingsRegistry.entries.first {
            $0.key == PluginRegistry.installStateKey
        }
        XCTAssertEqual(entry?.type, .stringArray,
                       "the installed-plugin set travels in config backup")
    }

    func testExcludesPrivilegedHelperState() {
        // Helper registration/approval is machine-local security state and
        // must never travel in a backup (PRD user story 24).
        let keys = SyncSettingsRegistry.entries.map(\.key)
        XCTAssertFalse(keys.contains { $0.localizedCaseInsensitiveContains("helper") })
    }

    func testReadCollectsOnlyPresentKeysWithCorrectTypes() {
        let d = makeDefaults()
        d.set(false, forKey: "menuBar.iconVisible")
        d.set(48, forKey: "commandPalette.hotkey.keyCode")
        d.set("zh", forKey: "dev.bybee.AnyDoor.language")
        d.set(["com.apple.Safari", "com.apple.finder"], forKey: "clipboard.excludedBundleIDs")
        // hyperKey.trigger deliberately not set → absent from result

        let result = SyncSettingsRegistry.read(from: d)

        XCTAssertEqual(result["menuBar.iconVisible"], .bool(false))
        XCTAssertEqual(result["commandPalette.hotkey.keyCode"], .int(48))
        XCTAssertEqual(result["dev.bybee.AnyDoor.language"], .string("zh"))
        XCTAssertEqual(result["clipboard.excludedBundleIDs"], .stringArray(["com.apple.Safari", "com.apple.finder"]))
        XCTAssertNil(result["hyperKey.trigger"])
    }

    func testWriteAppliesValuesWithCorrectTypes() {
        let d = makeDefaults()
        SyncSettingsRegistry.write(
            ["menuBar.iconVisible": .bool(false),
             "commandPalette.hotkey.keyCode": .int(48),
             "dev.bybee.AnyDoor.language": .string("en"),
             "clipboard.excludedBundleIDs": .stringArray(["com.apple.Safari"])],
            to: d
        )
        XCTAssertEqual(d.bool(forKey: "menuBar.iconVisible"), false)
        XCTAssertEqual(d.integer(forKey: "commandPalette.hotkey.keyCode"), 48)
        XCTAssertEqual(d.string(forKey: "dev.bybee.AnyDoor.language"), "en")
        XCTAssertEqual(d.stringArray(forKey: "clipboard.excludedBundleIDs"), ["com.apple.Safari"])
    }

    func testWriteIgnoresKeysOutsideWhitelist() {
        let d = makeDefaults()
        SyncSettingsRegistry.write(["SUSkippedVersion": .string("9.9.9")], to: d)
        XCTAssertNil(d.string(forKey: "SUSkippedVersion"))
    }

    func testWriteIgnoresTypeMismatch() {
        let d = makeDefaults()
        // menuBar.iconVisible expects bool; an int payload must be ignored.
        SyncSettingsRegistry.write(["menuBar.iconVisible": .int(1)], to: d)
        XCTAssertNil(d.object(forKey: "menuBar.iconVisible"))
    }
}
