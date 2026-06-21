import XCTest
@testable import AnyDoor

@MainActor
final class SpeechServiceTests: XCTestCase {
    func testLanguageWinsOverFallback() {
        let code = SpeechService.voiceLanguageCode(
            for: .simplifiedChinese,
            fallbackDetectedCode: "ja"
        )
        XCTAssertEqual(code, TranslationLanguage.simplifiedChinese.code)
    }

    func testNilLanguageUsesFallbackDetectedCode() {
        let code = SpeechService.voiceLanguageCode(for: nil, fallbackDetectedCode: "ja")
        XCTAssertEqual(code, "ja")
    }

    func testBlankFallbackIsTreatedAsAbsent() {
        let code = SpeechService.voiceLanguageCode(for: nil, fallbackDetectedCode: "   ")
        XCTAssertEqual(code, "en")
    }

    func testBothAbsentDefaultsToEnglish() {
        XCTAssertEqual(SpeechService.voiceLanguageCode(for: nil, fallbackDetectedCode: nil), "en")
    }
}
