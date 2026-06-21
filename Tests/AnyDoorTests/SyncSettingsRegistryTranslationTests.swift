import XCTest
@testable import AnyDoor

final class SyncSettingsRegistryTranslationTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "SyncRegistryTranslation.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testTranslationKeysAreWhitelisted() {
        let keys = Set(SyncSettingsRegistry.entries.map(\.key))
        XCTAssertTrue(keys.contains("translation.targetLanguage"))
        XCTAssertTrue(keys.contains("translation.secondTargetLanguage"))
        XCTAssertTrue(keys.contains("translation.autoSpeak"))
        XCTAssertTrue(keys.contains("translation.services"))
    }

    func testTranslationKeysHaveExpectedTypes() {
        let byKey = Dictionary(uniqueKeysWithValues: SyncSettingsRegistry.entries.map { ($0.key, $0.type) })
        XCTAssertEqual(byKey["translation.targetLanguage"], .string)
        XCTAssertEqual(byKey["translation.secondTargetLanguage"], .string)
        XCTAssertEqual(byKey["translation.autoSpeak"], .bool)
        XCTAssertEqual(byKey["translation.services"], .string)
    }

    func testTranslationKeysRoundTrip() {
        let source = makeDefaults()
        source.set("ja", forKey: "translation.targetLanguage")
        source.set("en", forKey: "translation.secondTargetLanguage")
        source.set(true, forKey: "translation.autoSpeak")
        source.set("[{\"id\":\"x\"}]", forKey: "translation.services")

        let captured = SyncSettingsRegistry.read(from: source)
        XCTAssertEqual(captured["translation.targetLanguage"], .string("ja"))
        XCTAssertEqual(captured["translation.secondTargetLanguage"], .string("en"))
        XCTAssertEqual(captured["translation.autoSpeak"], .bool(true))
        XCTAssertEqual(captured["translation.services"], .string("[{\"id\":\"x\"}]"))

        let destination = makeDefaults()
        let applied = SyncSettingsRegistry.write(captured, to: destination)
        XCTAssertEqual(applied, 4)
        XCTAssertEqual(destination.string(forKey: "translation.targetLanguage"), "ja")
        XCTAssertEqual(destination.string(forKey: "translation.secondTargetLanguage"), "en")
        XCTAssertTrue(destination.bool(forKey: "translation.autoSpeak"))
        XCTAssertEqual(destination.string(forKey: "translation.services"), "[{\"id\":\"x\"}]")
    }
}
