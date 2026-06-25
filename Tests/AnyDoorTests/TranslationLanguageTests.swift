import XCTest
@testable import AnyDoor

final class TranslationLanguageTests: XCTestCase {
    func testCatalogHasReasonableSize() {
        XCTAssertGreaterThanOrEqual(TranslationLanguage.catalog.count, 25)
    }

    func testCatalogCodesAreUnique() {
        let codes = TranslationLanguage.catalog.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count, "Catalog codes must be unique")
    }

    func testNamedFindsKnownLanguage() {
        XCTAssertEqual(TranslationLanguage.named("en"), TranslationLanguage.english)
        XCTAssertEqual(TranslationLanguage.named("zh-Hans"), TranslationLanguage.simplifiedChinese)
    }

    func testNamedReturnsNilForUnknown() {
        XCTAssertNil(TranslationLanguage.named("zz-Unknown"))
    }

    func testEnglishAndSimplifiedChineseConstants() {
        XCTAssertEqual(TranslationLanguage.english.code, "en")
        XCTAssertEqual(TranslationLanguage.simplifiedChinese.code, "zh-Hans")
    }

    func testIdentifiableIDIsCode() {
        XCTAssertEqual(TranslationLanguage.english.id, "en")
    }

    func testServiceCodeMapsSimplifiedChineseForGoogleAndBing() {
        let zh = TranslationLanguage.simplifiedChinese
        XCTAssertEqual(zh.serviceCode(for: .googleFree), "zh-CN")
        XCTAssertEqual(zh.serviceCode(for: .bingFree), "zh-CN")
    }

    func testServiceCodePassesThroughForApple() {
        let zh = TranslationLanguage.simplifiedChinese
        XCTAssertEqual(zh.serviceCode(for: .apple), "zh-Hans")
        XCTAssertEqual(zh.serviceCode(for: .openAICompatible), "zh-Hans")
    }

    func testServiceCodeDefaultsToCanonicalCode() {
        XCTAssertEqual(TranslationLanguage.english.serviceCode(for: .googleFree), "en")
    }

    func testFromServiceCodeRemapsChineseForGoogleAndBing() {
        XCTAssertEqual(
            TranslationLanguage.fromServiceCode("zh-CN", for: .googleFree),
            TranslationLanguage.simplifiedChinese
        )
        XCTAssertEqual(
            TranslationLanguage.fromServiceCode("zh-TW", for: .bingFree),
            TranslationLanguage.named("zh-Hant")
        )
    }

    func testFromServiceCodePassesThroughCanonicalCode() {
        XCTAssertEqual(
            TranslationLanguage.fromServiceCode("en", for: .googleFree),
            TranslationLanguage.english
        )
    }

    func testFromServiceCodeDoesNotRemapForApple() {
        // Apple / OpenAI codes are already canonical; "zh-CN" is not a catalog code there.
        XCTAssertNil(TranslationLanguage.fromServiceCode("zh-CN", for: .apple))
        XCTAssertEqual(
            TranslationLanguage.fromServiceCode("zh-Hans", for: .openAICompatible),
            TranslationLanguage.simplifiedChinese
        )
    }

    func testFromServiceCodeReturnsNilForUnknown() {
        XCTAssertNil(TranslationLanguage.fromServiceCode("zz-Unknown", for: .googleFree))
    }

    func testNLLanguageRoundTrip() {
        XCTAssertEqual(TranslationLanguage.english.nlLanguage?.rawValue, "en")
        XCTAssertNotNil(TranslationLanguage.simplifiedChinese.nlLanguage)
    }

    func testDisplayNameFallsBackToEnglishName() {
        let invented = TranslationLanguage(code: "qa-Test", englishName: "Quux", nlLanguageRaw: nil)
        XCTAssertEqual(invented.displayName(in: Locale(identifier: "en")), "Quux")
    }

    func testSystemDefaultIsInCatalog() {
        let def = TranslationLanguage.systemDefault
        XCTAssertTrue(TranslationLanguage.catalog.contains(def))
    }
}
