import XCTest

@testable import AnyDoor

final class ClipboardPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ClipboardPreferencesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFirstDefaultExclusionMergeSeedsPasswordsAndKeychainAccess() {
        ClipboardPreferences.mergeDefaultExclusionsIfNeeded(in: defaults)

        XCTAssertEqual(
            ClipboardPreferences.excludedBundleIDs(from: defaults),
            ["com.apple.Passwords", "com.apple.keychainaccess"]
        )
    }

    func testAddingExcludedBundleIDAppendsOnceAndPreservesOrder() {
        ClipboardPreferences.addExcludedBundleID(" com.apple.Safari ", to: defaults)
        ClipboardPreferences.addExcludedBundleID("com.apple.finder", to: defaults)
        ClipboardPreferences.addExcludedBundleID("com.apple.Safari", to: defaults)
        ClipboardPreferences.addExcludedBundleID("   ", to: defaults)

        XCTAssertEqual(
            ClipboardPreferences.excludedBundleIDs(from: defaults),
            ["com.apple.Safari", "com.apple.finder"]
        )
    }

    func testRemovingExcludedBundleIDPersists() {
        ClipboardPreferences.mergeDefaultExclusionsIfNeeded(in: defaults)
        ClipboardPreferences.addExcludedBundleID("com.apple.Safari", to: defaults)
        ClipboardPreferences.removeExcludedBundleID(
            "com.apple.Passwords",
            from: defaults
        )

        ClipboardPreferences.mergeDefaultExclusionsIfNeeded(in: defaults)

        XCTAssertEqual(
            ClipboardPreferences.excludedBundleIDs(from: defaults),
            ["com.apple.keychainaccess", "com.apple.Safari"]
        )
    }

    func testUpgradeDefaultMergePreservesExistingExclusions() {
        defaults.set(
            ["com.example.Bank"],
            forKey: ClipboardPreferences.excludedKey
        )

        ClipboardPreferences.mergeDefaultExclusionsIfNeeded(in: defaults)

        XCTAssertEqual(
            ClipboardPreferences.excludedBundleIDs(from: defaults),
            [
                "com.example.Bank",
                "com.apple.Passwords",
                "com.apple.keychainaccess",
            ]
        )
    }

    func testUniversalClipboardRuleDefaultsOffAndIsPortable() {
        XCTAssertFalse(
            ClipboardPreferences.ignoresUniversalClipboard(from: defaults)
        )

        ClipboardPreferences.setIgnoresUniversalClipboard(
            true,
            in: defaults
        )

        XCTAssertTrue(
            ClipboardPreferences.ignoresUniversalClipboard(from: defaults)
        )
    }

    func testDeviceLocalDefaultsMatchClipboardHistoryContract() {
        XCTAssertTrue(
            ClipboardPreferences.monitoringEnabled(from: defaults)
        )
        XCTAssertFalse(ClipboardPreferences.copyOnly(from: defaults))
    }
}
