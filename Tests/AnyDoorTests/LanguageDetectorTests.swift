import XCTest
@testable import AnyDoor

final class LanguageDetectorTests: XCTestCase {

    func testDetectsEnglish() {
        let detected = LanguageDetector.detect("The quick brown fox jumps over the lazy dog.")
        XCTAssertEqual(detected?.code, "en", "got: \(String(describing: detected?.code))")
    }

    func testDetectsSimplifiedChinese() {
        let detected = LanguageDetector.detect("今天天气很好，我们一起去公园散步吧。")
        // NLLanguageRecognizer reports zh-Hans for simplified script; the catalog
        // maps it to the canonical "zh-Hans" entry.
        XCTAssertEqual(detected?.code, "zh-Hans", "got: \(String(describing: detected?.code))")
    }

    func testDetectsJapanese() {
        let detected = LanguageDetector.detect("今日はとても良い天気ですね。一緒に公園へ散歩に行きましょう。")
        XCTAssertEqual(detected?.code, "ja", "got: \(String(describing: detected?.code))")
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(LanguageDetector.detect(""))
    }

    func testWhitespaceOnlyReturnsNil() {
        XCTAssertNil(LanguageDetector.detect("   \n\t  "))
    }

    func testDetectedLanguageIsInCatalog() {
        let detected = LanguageDetector.detect("Bonjour, comment allez-vous aujourd'hui ?")
        guard let detected else {
            // French may or may not be in the ~25-language catalog; if absent,
            // detect() returns nil rather than an off-catalog value. Either way
            // the contract holds: a non-nil result must be a catalog member.
            return
        }
        XCTAssertTrue(
            TranslationLanguage.catalog.contains(detected),
            "detected language must be a catalog member; got: \(detected.code)"
        )
    }
}
