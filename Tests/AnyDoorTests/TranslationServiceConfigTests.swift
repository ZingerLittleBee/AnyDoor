import XCTest
@testable import AnyDoor

final class TranslationServiceConfigTests: XCTestCase {
    func testServiceKindCaseCoverage() {
        XCTAssertEqual(
            Set(TranslationServiceKind.allCases),
            [.apple, .googleFree, .bingFree, .openAICompatible]
        )
    }

    func testServiceKindRawValuesAreStable() {
        XCTAssertEqual(TranslationServiceKind.apple.rawValue, "apple")
        XCTAssertEqual(TranslationServiceKind.googleFree.rawValue, "googleFree")
        XCTAssertEqual(TranslationServiceKind.bingFree.rawValue, "bingFree")
        XCTAssertEqual(TranslationServiceKind.openAICompatible.rawValue, "openAICompatible")
    }

    func testSeededDefaultsProvideAppleGoogleBing() {
        let defaults = TranslationServiceConfig.seededDefaults()
        XCTAssertEqual(defaults.map(\.kind), [.apple, .googleFree, .bingFree])
    }

    func testSeededDefaultsOrderingIsZeroBasedAndAscending() {
        let defaults = TranslationServiceConfig.seededDefaults()
        XCTAssertEqual(defaults.map(\.order), [0, 1, 2])
    }

    func testSeededDefaultsAreAllEnabledWithDistinctIDs() {
        let defaults = TranslationServiceConfig.seededDefaults()
        XCTAssertTrue(defaults.allSatisfy(\.enabled))
        XCTAssertEqual(Set(defaults.map(\.id)).count, defaults.count)
    }

    func testDefaultPromptTemplateContainsAllPlaceholders() {
        let template = TranslationServiceConfig.defaultPromptTemplate
        XCTAssertTrue(template.contains("{{source}}"))
        XCTAssertTrue(template.contains("{{target}}"))
        XCTAssertTrue(template.contains("{{text}}"))
    }

    func testCodableRoundTrip() throws {
        let config = TranslationServiceConfig(
            id: "abc",
            kind: .openAICompatible,
            displayName: "My LLM",
            iconName: "brain",
            enabled: true,
            order: 7,
            baseURL: "https://example.com/v1",
            model: "gpt-test",
            promptTemplate: TranslationServiceConfig.defaultPromptTemplate
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TranslationServiceConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testNonLLMFieldsAreNilInSeededDefaults() {
        for config in TranslationServiceConfig.seededDefaults() {
            XCTAssertNil(config.baseURL)
            XCTAssertNil(config.model)
            XCTAssertNil(config.promptTemplate)
        }
    }

    // MARK: - isValidBaseURL

    func testIsValidBaseURLAcceptsHTTPS() {
        XCTAssertTrue(TranslationServiceConfig.isValidBaseURL("https://api.openai.com/v1"))
    }

    func testIsValidBaseURLAcceptsHTTPLocalhost() {
        XCTAssertTrue(TranslationServiceConfig.isValidBaseURL("http://localhost:11434/v1"))
    }

    func testIsValidBaseURLTrimsWhitespace() {
        XCTAssertTrue(TranslationServiceConfig.isValidBaseURL("  https://api.example.com/v1  "))
    }

    func testIsValidBaseURLRejectsEmpty() {
        XCTAssertFalse(TranslationServiceConfig.isValidBaseURL(""))
        XCTAssertFalse(TranslationServiceConfig.isValidBaseURL("   "))
    }

    func testIsValidBaseURLRejectsMissingScheme() {
        XCTAssertFalse(TranslationServiceConfig.isValidBaseURL("api.openai.com/v1"))
    }

    func testIsValidBaseURLRejectsNonHTTPScheme() {
        XCTAssertFalse(TranslationServiceConfig.isValidBaseURL("ftp://example.com"))
    }

    func testIsValidBaseURLRejectsSchemeWithoutHost() {
        XCTAssertFalse(TranslationServiceConfig.isValidBaseURL("https://"))
    }

    // MARK: - promptContainsText

    func testPromptContainsTextTrueForDefaultTemplate() {
        XCTAssertTrue(TranslationServiceConfig.promptContainsText(TranslationServiceConfig.defaultPromptTemplate))
    }

    func testPromptContainsTextFalseWhenPlaceholderRemoved() {
        XCTAssertFalse(TranslationServiceConfig.promptContainsText("Translate from {{source}} to {{target}}."))
        XCTAssertFalse(TranslationServiceConfig.promptContainsText(""))
    }
}
