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

    func testExcludedBundleIDsDefaultToEmpty() {
        XCTAssertEqual(ClipboardPreferences.excludedBundleIDs(from: defaults), [])
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
        ClipboardPreferences.addExcludedBundleID("com.apple.Safari", to: defaults)
        ClipboardPreferences.addExcludedBundleID("com.apple.finder", to: defaults)

        ClipboardPreferences.removeExcludedBundleID("com.apple.Safari", from: defaults)

        XCTAssertEqual(ClipboardPreferences.excludedBundleIDs(from: defaults), ["com.apple.finder"])
    }
}
