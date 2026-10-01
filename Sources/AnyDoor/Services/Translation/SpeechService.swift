import AVFoundation
import Foundation

/// AVSpeechSynthesizer wrapper for TTS playback of source / translated text.
/// `@MainActor`: AVSpeechSynthesizer is not Sendable and is driven from the UI.
@MainActor
final class SpeechService {
    static let shared = SpeechService()

    private let synthesizer = AVSpeechSynthesizer()

    /// Speak `text` in `language` (or, when nil, a best-effort voice). Any
    /// in-flight utterance is cut immediately so back-to-back speaker taps don't
    /// queue up.
    func speak(_ text: String, language: TranslationLanguage?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        let code = Self.voiceLanguageCode(for: language)
        utterance.voice = AVSpeechSynthesisVoice(language: code)
        synthesizer.speak(utterance)
    }

    /// Pick a BCP-47 voice code for `language` (Chinese scripts mapped to the
    /// region codes the speech engine expects), or English when nil.
    static func voiceLanguageCode(for language: TranslationLanguage?) -> String {
        guard let language else { return "en" }
        return speechCode(for: language.code)
    }

    private static func speechCode(for code: String) -> String {
        switch code {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        default: return code
        }
    }
}
