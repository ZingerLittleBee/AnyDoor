import XCTest
@testable import AnyDoor

final class TranslationServiceConfigTests: XCTestCase {
    func testServiceKindCaseCoverage() {
        XCTAssertEqual(
            Set(TranslationServiceKind.allCases),
            [.apple, .googleFree, .bingFree, .openAICompatible, .deepl]
        )
    }

    func testDeepLRawValueIsStable() {
        XCTAssertEqual(TranslationServiceKind.deepl.rawValue, "deepl")
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

    // MARK: - manualMode / startsManual

    func testManualModeDefaultsToNilAndStartsManualFalse() {
        let config = TranslationServiceConfig(
            id: "x", kind: .openAICompatible, displayName: "X", iconName: "brain",
            enabled: true, order: 0, baseURL: "https://a.com/v1", model: "m",
            promptTemplate: nil)
        XCTAssertNil(config.manualMode)
        XCTAssertFalse(config.startsManual)
    }

    func testStartsManualTrueOnlyForLLMWithManualMode() {
        var llm = TranslationServiceConfig(
            id: "llm", kind: .openAICompatible, displayName: "L", iconName: "brain",
            enabled: true, order: 0, baseURL: "https://a.com/v1", model: "m",
            promptTemplate: nil)
        llm.manualMode = true
        XCTAssertTrue(llm.startsManual)

        var google = TranslationServiceConfig(
            id: "g", kind: .googleFree, displayName: "G", iconName: "globe",
            enabled: true, order: 0, baseURL: nil, model: nil, promptTemplate: nil)
        google.manualMode = true // ignored for non-LLM kinds
        XCTAssertFalse(google.startsManual)
    }

    func testManualModeCodableRoundTripAndLegacyDecodesNil() throws {
        var config = TranslationServiceConfig(
            id: "llm", kind: .openAICompatible, displayName: "L", iconName: "brain",
            enabled: true, order: 0, baseURL: "https://a.com/v1", model: "m",
            promptTemplate: nil)
        config.manualMode = true
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(TranslationServiceConfig.self, from: data), config)

        // Legacy JSON (pre-feature) omits the key; must decode to nil, not throw.
        let legacy = #"{"id":"old","kind":"openAICompatible","displayName":"O","iconName":"brain","enabled":true,"order":0}"#
        let decoded = try JSONDecoder().decode(TranslationServiceConfig.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.manualMode)
        XCTAssertFalse(decoded.startsManual)
    }

    // MARK: - extraBodyJSON

    func testExtraBodyJSONCodableRoundTripAndLegacyDecodesNil() throws {
        var config = TranslationServiceConfig(
            id: "llm", kind: .openAICompatible, displayName: "L", iconName: "brain",
            enabled: true, order: 0, baseURL: "https://a.com/v1", model: "m", promptTemplate: nil)
        config.extraBodyJSON = #"{"thinking":{"type":"disabled"}}"#
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(TranslationServiceConfig.self, from: data), config)

        let legacy = #"{"id":"old","kind":"openAICompatible","displayName":"O","iconName":"brain","enabled":true,"order":0}"#
        let decoded = try JSONDecoder().decode(TranslationServiceConfig.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.extraBodyJSON)
    }

    func testIsValidExtraBody() {
        XCTAssertTrue(TranslationServiceConfig.isValidExtraBody(nil))
        XCTAssertTrue(TranslationServiceConfig.isValidExtraBody(""))
        XCTAssertTrue(TranslationServiceConfig.isValidExtraBody("   "))
        XCTAssertTrue(TranslationServiceConfig.isValidExtraBody(#"{"thinking":{"type":"disabled"}}"#))
        XCTAssertFalse(TranslationServiceConfig.isValidExtraBody("[1,2,3]"))
        XCTAssertFalse(TranslationServiceConfig.isValidExtraBody("42"))
        XCTAssertFalse(TranslationServiceConfig.isValidExtraBody("{not json"))
    }

    func testParseExtraBodyObject() {
        XCTAssertNil(TranslationServiceConfig.parseExtraBodyObject(nil))
        XCTAssertNil(TranslationServiceConfig.parseExtraBodyObject(""))
        XCTAssertNil(TranslationServiceConfig.parseExtraBodyObject("[1]"))
        let obj = TranslationServiceConfig.parseExtraBodyObject(#"{"a":1}"#)
        XCTAssertEqual(obj?["a"] as? Int, 1)
    }
}
