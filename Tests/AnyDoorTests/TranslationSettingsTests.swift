import XCTest
@testable import AnyDoor

@MainActor
final class TranslationSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "translation.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testDefaultsWhenUnset() {
        let s = TranslationSettings(defaults: makeDefaults())
        XCTAssertEqual(s.targetLanguageCode, TranslationLanguage.systemDefault.code)
        XCTAssertEqual(s.secondTargetLanguageCode, TranslationLanguage.english.code)
        XCTAssertFalse(s.autoSpeak)
        XCTAssertEqual(s.services.map(\.kind), TranslationServiceConfig.seededDefaults().map(\.kind))
    }

    func testGarbageServicesJSONFallsBackToSeeded() {
        let d = makeDefaults()
        d.set("not-json", forKey: TranslationSettings.servicesKey)
        let s = TranslationSettings(defaults: d)
        XCTAssertEqual(s.services.map(\.id), TranslationServiceConfig.seededDefaults().map(\.id))
    }

    func testEmptyServicesArrayFallsBackToSeeded() {
        let d = makeDefaults()
        let empty = try! JSONEncoder().encode([TranslationServiceConfig]())
        d.set(empty, forKey: TranslationSettings.servicesKey)
        let s = TranslationSettings(defaults: d)
        XCTAssertEqual(s.services.map(\.id), TranslationServiceConfig.seededDefaults().map(\.id))
    }

    func testScalarSettersPersist() {
        let d = makeDefaults()
        let s = TranslationSettings(defaults: d)
        s.setTargetLanguageCode("ja")
        s.setSecondTargetLanguageCode("fr")
        s.setAutoSpeak(true)
        let reloaded = TranslationSettings(defaults: d)
        XCTAssertEqual(reloaded.targetLanguageCode, "ja")
        XCTAssertEqual(reloaded.secondTargetLanguageCode, "fr")
        XCTAssertTrue(reloaded.autoSpeak)
    }

    func testSetServicesSortsByOrderAndPersists() {
        let d = makeDefaults()
        let s = TranslationSettings(defaults: d)
        var a = TranslationServiceConfig.seededDefaults()[0]; a.id = "a"; a.order = 5
        var b = TranslationServiceConfig.seededDefaults()[1]; b.id = "b"; b.order = 1
        s.setServices([a, b])
        XCTAssertEqual(s.services.map(\.id), ["b", "a"])
        let reloaded = TranslationSettings(defaults: d)
        XCTAssertEqual(reloaded.services.map(\.id), ["b", "a"])
    }

    func testUpsertReplacesByID() {
        let s = TranslationSettings(defaults: makeDefaults())
        let seeded = s.services
        var changed = seeded[0]
        changed.displayName = "Renamed"
        s.upsertService(changed)
        XCTAssertEqual(s.services.count, seeded.count)
        XCTAssertEqual(s.services.first(where: { $0.id == changed.id })?.displayName, "Renamed")
    }

    func testUpsertAppendsNewID() {
        let s = TranslationSettings(defaults: makeDefaults())
        let count = s.services.count
        var added = TranslationServiceConfig.seededDefaults()[0]
        added.id = "brand-new"; added.order = 99
        s.upsertService(added)
        XCTAssertEqual(s.services.count, count + 1)
        XCTAssertTrue(s.services.contains(where: { $0.id == "brand-new" }))
    }

    func testRemoveService() {
        let s = TranslationSettings(defaults: makeDefaults())
        let target = s.services[0].id
        s.removeService(id: target)
        XCTAssertFalse(s.services.contains(where: { $0.id == target }))
    }

    func testComputedLanguages() {
        let d = makeDefaults()
        let s = TranslationSettings(defaults: d)
        s.setTargetLanguageCode("ja")
        s.setSecondTargetLanguageCode("en")
        XCTAssertEqual(s.targetLanguage.code, "ja")
        XCTAssertEqual(s.secondTargetLanguage.code, "en")
        // Unknown codes fall back.
        s.setTargetLanguageCode("zzz")
        s.setSecondTargetLanguageCode("zzz")
        XCTAssertEqual(s.targetLanguage.code, TranslationLanguage.systemDefault.code)
        XCTAssertEqual(s.secondTargetLanguage.code, TranslationLanguage.english.code)
    }

    func testEnabledServicesInOrderFiltersAndSorts() {
        let s = TranslationSettings(defaults: makeDefaults())
        var first = TranslationServiceConfig.seededDefaults()[0]
        first.id = "x"; first.enabled = true; first.order = 2
        var second = TranslationServiceConfig.seededDefaults()[1]
        second.id = "y"; second.enabled = false; second.order = 0
        var third = TranslationServiceConfig.seededDefaults()[2]
        third.id = "z"; third.enabled = true; third.order = 1
        s.setServices([first, second, third])
        XCTAssertEqual(s.enabledServicesInOrder.map(\.id), ["z", "x"])
    }

    func testReloadFromDefaultsReReads() {
        let d = makeDefaults()
        let s = TranslationSettings(defaults: d)
        // Mutate the backing store behind the instance's back.
        d.set("ko", forKey: TranslationSettings.targetLanguageKey)
        d.set(true, forKey: TranslationSettings.autoSpeakKey)
        s.reloadFromDefaults()
        XCTAssertEqual(s.targetLanguageCode, "ko")
        XCTAssertTrue(s.autoSpeak)
    }
}
