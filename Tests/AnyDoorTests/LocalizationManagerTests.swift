import XCTest
@testable import AnyDoor

@MainActor
final class LocalizationManagerTests: XCTestCase {
    private let defaultsKey = "dev.bybee.AnyDoor.language"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    func test_defaultPreferenceIsSystem() {
        let manager = LocalizationManager()
        XCTAssertEqual(manager.preference, .system)
    }

    func test_settingPreferencePersists() {
        let manager = LocalizationManager()
        manager.preference = .zh
        let reloaded = LocalizationManager()
        XCTAssertEqual(reloaded.preference, .zh)
    }

    func test_zhPreferenceResolvesToZhHans() {
        let manager = LocalizationManager()
        manager.preference = .zh
        XCTAssertEqual(manager.effectiveLocale.identifier, "zh-Hans")
    }

    func test_enPreferenceResolvesToEn() {
        let manager = LocalizationManager()
        manager.preference = .en
        XCTAssertEqual(manager.effectiveLocale.identifier, "en")
    }

    func test_systemFallsBackToEnForUnsupportedLanguage() {
        let manager = LocalizationManager(preferredLanguagesProvider: { ["ja"] })
        XCTAssertEqual(manager.effectiveLocale.identifier, "en")
    }

    func test_systemResolvesZhPreferredLanguage() {
        let manager = LocalizationManager(preferredLanguagesProvider: { ["zh-Hans-CN", "en"] })
        XCTAssertEqual(manager.effectiveLocale.identifier, "zh-Hans")
    }

    func test_bundleChangesWhenPreferenceChanges() throws {
        try XCTSkipIf(true, "re-enable after Task 12 populates lproj resources")
        let manager = LocalizationManager()
        manager.preference = .en
        let enBundle = manager.bundle
        manager.preference = .zh
        let zhBundle = manager.bundle
        XCTAssertNotEqual(enBundle.bundlePath, zhBundle.bundlePath)
    }
}
