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

    /// Drive the *real* `TranslationSettings` storage codec end-to-end: configure
    /// services through `setServices` on a source instance, export via the
    /// registry, import into a destination's defaults, then assert a fresh
    /// `TranslationSettings` over the destination reads the same services back.
    /// This guards the actual production path (registry type <-> storage format),
    /// unlike asserting against a hand-rolled string the app never writes.
    @MainActor
    func testTranslationKeysRoundTrip() {
        let source = makeDefaults()
        let sourceSettings = TranslationSettings(defaults: source)
        sourceSettings.setTargetLanguageCode("ja")
        sourceSettings.setSecondTargetLanguageCode("en")
        sourceSettings.setAutoSpeak(true)

        let customServices = [
            TranslationServiceConfig(
                id: "openai-custom",
                kind: .openAICompatible,
                displayName: "My LLM",
                iconName: "sparkles",
                enabled: true,
                order: 0,
                baseURL: "https://api.example.com/v1",
                model: "gpt-test",
                promptTemplate: "Translate {{text}} to {{target}}"
            ),
            TranslationServiceConfig(
                id: TranslationServiceKind.googleFree.rawValue,
                kind: .googleFree,
                displayName: "Google",
                iconName: "globe",
                enabled: false,
                order: 1,
                baseURL: nil,
                model: nil,
                promptTemplate: nil
            ),
        ]
        sourceSettings.setServices(customServices)

        let captured = SyncSettingsRegistry.read(from: source)
        XCTAssertEqual(captured["translation.targetLanguage"], .string("ja"))
        XCTAssertEqual(captured["translation.secondTargetLanguage"], .string("en"))
        XCTAssertEqual(captured["translation.autoSpeak"], .bool(true))
        // Services must be captured (the bug: a Data-stored value yields nil here).
        guard case .string(let servicesJSON)? = captured["translation.services"] else {
            return XCTFail("translation.services was not captured into the snapshot")
        }
        XCTAssertFalse(servicesJSON.isEmpty)

        let destination = makeDefaults()
        let applied = SyncSettingsRegistry.write(captured, to: destination)
        XCTAssertEqual(applied, 4)

        // A fresh settings instance over the imported defaults must decode the
        // exact services the user configured (no fallback to seededDefaults()).
        let destinationSettings = TranslationSettings(defaults: destination)
        XCTAssertEqual(destinationSettings.targetLanguageCode, "ja")
        XCTAssertEqual(destinationSettings.secondTargetLanguageCode, "en")
        XCTAssertTrue(destinationSettings.autoSpeak)
        XCTAssertEqual(destinationSettings.services, customServices)

        // reloadFromDefaults (the import reconcile path) must agree too.
        sourceSettings.reloadFromDefaults()
        XCTAssertEqual(sourceSettings.services, customServices)
    }
}
