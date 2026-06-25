import XCTest
@testable import AnyDoor

final class TranslationServicePresetTests: XCTestCase {
    func testCatalogHasUniqueIDsAndStartsWithDeepL() {
        let catalog = TranslationServicePreset.catalog
        XCTAssertEqual(catalog.first?.id, "deepl")
        XCTAssertEqual(catalog.first?.kind, .deepl)
        XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count)
        XCTAssertEqual(catalog.last?.id, "custom")
    }

    func testLLMPresetsCarryBaseURLAndModel() {
        // Every openAICompatible preset except the blank "custom" sentinel must
        // carry a base URL + model so it is runnable after just a key.
        for preset in TranslationServicePreset.catalog
        where preset.kind == .openAICompatible && preset.id != "custom" {
            XCTAssertFalse(preset.baseURL?.isEmpty ?? true, "\(preset.id) missing baseURL")
            XCTAssertFalse(preset.model?.isEmpty ?? true, "\(preset.id) missing model")
        }
    }

    func testDeepSeekPresetDisablesThinking() {
        let deepseek = TranslationServicePreset.catalog.first { $0.id == "deepseek" }
        XCTAssertEqual(deepseek?.model, "deepseek-v4-flash")
        XCTAssertTrue(TranslationServiceConfig.isValidExtraBody(deepseek?.extraBodyJSON))
        XCTAssertNotNil(deepseek?.extraBodyJSON)
    }

    func testOllamaPresetPrefillsKey() {
        let ollama = TranslationServicePreset.catalog.first { $0.id == "ollama" }
        XCTAssertEqual(ollama?.defaultAPIKey, "ollama")
    }

    func testMakeDraftAssignsIDOrderAndKey() {
        let ollama = TranslationServicePreset.catalog.first { $0.id == "ollama" }!
        let (config, key) = ollama.makeDraft(order: 5, id: "fixed-id")
        XCTAssertEqual(config.id, "fixed-id")
        XCTAssertEqual(config.order, 5)
        XCTAssertEqual(config.kind, .openAICompatible)
        XCTAssertEqual(config.baseURL, "http://localhost:11434/v1/")
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(key, "ollama")
    }

    func testMakeDraftDeepLHasNoModelOrKey() {
        let deepl = TranslationServicePreset.catalog.first { $0.id == "deepl" }!
        let (config, key) = deepl.makeDraft(order: 0, id: "x")
        XCTAssertEqual(config.kind, .deepl)
        XCTAssertNil(config.baseURL)
        XCTAssertNil(config.model)
        XCTAssertEqual(key, "")
    }
}
