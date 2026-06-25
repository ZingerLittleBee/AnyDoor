import Foundation
import NaturalLanguage

/// Detects the natural language of a piece of text and maps it to a
/// `TranslationLanguage` in the app catalog. Returns `nil` for empty input,
/// unsupported catalog entries, or low-confidence Latin-script snippets.
enum LanguageDetector {
    /// Detects the language of `text`. Whitespace-only or empty input yields
    /// `nil`. A non-nil result is always a member of `TranslationLanguage.catalog`.
    static func detect(_ text: String) -> TranslationLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let ranked = recognizer.languageHypotheses(withMaximum: 3)
            .sorted { $0.value > $1.value }
        guard let top = ranked.first else { return nil }
        guard isReliable(text: trimmed, topScore: top.value, secondScore: ranked.dropFirst().first?.value) else {
            return nil
        }

        return catalogLanguage(for: top.key)
    }

    /// Maps an `NLLanguage` to a catalog entry. First tries an exact match on
    /// the catalog's recorded `nlLanguageRaw`; then falls back to matching the
    /// BCP-47 base code (the substring before the first "-"), which collapses
    /// region/script variants like "en-GB" onto "en".
    private static func catalogLanguage(for language: NLLanguage) -> TranslationLanguage? {
        let raw = language.rawValue

        if let exact = TranslationLanguage.catalog.first(where: { $0.nlLanguageRaw == raw }) {
            return exact
        }

        // NLLanguage rawValues are BCP-47-ish (e.g. "zh-Hans", "en", "ja").
        // Try the full raw code, then its base, against the catalog's own codes.
        if let direct = TranslationLanguage.named(raw) {
            return direct
        }

        let base = raw.split(separator: "-").first.map(String.init) ?? raw
        return TranslationLanguage.named(base)
            ?? TranslationLanguage.catalog.first { $0.code.hasPrefix(base) }
    }

    /// Latin-only snippets are the dangerous case for translation UX: many short
    /// words are shared across languages, so only accept them when the recognizer
    /// is both confident and clearly ahead of the runner-up.
    private static func isReliable(text: String, topScore: Double, secondScore: Double?) -> Bool {
        guard isLatinOnlyText(text) else { return true }

        let margin = topScore - (secondScore ?? 0)
        if wordCount(text) <= 2 {
            return topScore >= 0.85 && margin >= 0.35
        }
        return topScore >= 0.75 && margin >= 0.25
    }

    private static func wordCount(_ text: String) -> Int {
        text.unicodeScalars.split { !CharacterSet.letters.contains($0) }.count
    }

    private static func isLatinOnlyText(_ text: String) -> Bool {
        var latinLetters = 0
        var nonLatinLetters = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            if isLatinLetter(scalar) {
                latinLetters += 1
            } else {
                nonLatinLetters += 1
            }
        }
        return latinLetters > 0 && nonLatinLetters == 0
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A, // Basic Latin uppercase
             0x0061...0x007A, // Basic Latin lowercase
             0x00C0...0x024F, // Latin-1 Supplement + Latin Extended-A/B
             0x1E00...0x1EFF: // Latin Extended Additional
            return true
        default:
            return false
        }
    }
}
