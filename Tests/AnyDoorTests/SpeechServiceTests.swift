import XCTest
@testable import AnyDoor

@MainActor
final class SpeechServiceTests: XCTestCase {
    func testSimplifiedChineseUsesMainlandVoiceCode() {
        XCTAssertEqual(SpeechService.voiceLanguageCode(for: .simplifiedChinese), "zh-CN")
    }

    func testTraditionalChineseUsesTaiwanVoiceCode() throws {
        let language = try XCTUnwrap(TranslationLanguage.named("zh-Hant"))
        let code = SpeechService.voiceLanguageCode(for: language)
        XCTAssertEqual(code, "zh-TW")
    }

    func testOtherLanguageCodesPassThrough() throws {
        let japanese = try XCTUnwrap(TranslationLanguage.named("ja"))
        XCTAssertEqual(SpeechService.voiceLanguageCode(for: japanese), "ja")
    }

    func testNilLanguageDefaultsToEnglish() {
        XCTAssertEqual(SpeechService.voiceLanguageCode(for: nil), "en")
    }
}
