import XCTest
@testable import AnyDoor

final class DeepLLanguageTests: XCTestCase {
    func testOfficialTargetUsesVariantCodes() {
        XCTAssertEqual(DeepLLanguage.targetCode(.simplifiedChinese, deeplx: false), "ZH-HANS")
        XCTAssertEqual(DeepLLanguage.targetCode(.english, deeplx: false), "EN-US")
        let hant = TranslationLanguage.named("zh-Hant")!
        XCTAssertEqual(DeepLLanguage.targetCode(hant, deeplx: false), "ZH-HANT")
        let pt = TranslationLanguage.named("pt")!
        XCTAssertEqual(DeepLLanguage.targetCode(pt, deeplx: false), "PT-PT")
        let ja = TranslationLanguage.named("ja")!
        XCTAssertEqual(DeepLLanguage.targetCode(ja, deeplx: false), "JA")
    }

    func testDeepLXTargetUsesBaseCodes() {
        XCTAssertEqual(DeepLLanguage.targetCode(.simplifiedChinese, deeplx: true), "ZH")
        XCTAssertEqual(DeepLLanguage.targetCode(.english, deeplx: true), "EN")
        let pt = TranslationLanguage.named("pt")!
        XCTAssertEqual(DeepLLanguage.targetCode(pt, deeplx: true), "PT")
    }

    func testSourceUsesBaseCodesAndNilHandling() {
        XCTAssertEqual(DeepLLanguage.sourceCode(.simplifiedChinese, deeplx: false), "ZH")
        XCTAssertEqual(DeepLLanguage.sourceCode(.english, deeplx: false), "EN")
        XCTAssertNil(DeepLLanguage.sourceCode(nil, deeplx: false))
        XCTAssertEqual(DeepLLanguage.sourceCode(nil, deeplx: true), "auto")
    }

    func testLanguageFromDetected() {
        XCTAssertEqual(DeepLLanguage.language(fromDetected: "EN"), .english)
        XCTAssertEqual(DeepLLanguage.language(fromDetected: "ZH"), .simplifiedChinese)
        XCTAssertEqual(DeepLLanguage.language(fromDetected: "JA"), TranslationLanguage.named("ja"))
    }
}
