import AVFoundation
import Foundation

/// AVSpeechSynthesizer wrapper for TTS playback of source / translated text.
/// `@MainActor`: AVSpeechSynthesizer is not Sendable and is driven from the UI.
@MainActor
final class SpeechService {
    static let shared = SpeechService()

    private let synthesizer = AVSpeechSynthesizer()

    var isSpeaking: Bool { synthesizer.isSpeaking }

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
        let code = Self.voiceLanguageCode(for: language, fallbackDetectedCode: nil)
        utterance.voice = AVSpeechSynthesisVoice(language: code)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Pick a BCP-47 voice code. The explicit language wins; otherwise a
    /// non-blank detected code; otherwise English.
    static func voiceLanguageCode(
        for language: TranslationLanguage?,
        fallbackDetectedCode: String?
    ) -> String {
        if let language { return language.code }
        if let fallback = fallbackDetectedCode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty {
            return fallback
        }
        return "en"
    }
}
