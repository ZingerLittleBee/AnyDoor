import Foundation
import NaturalLanguage

/// Detects the dominant natural language of a piece of text and maps it to a
/// `TranslationLanguage` in the app catalog. Returns `nil` for empty input or
/// when the recognizer's result has no catalog equivalent.
enum LanguageDetector {
    /// Detects the dominant language of `text`. Whitespace-only or empty input
    /// yields `nil`. A non-nil result is always a member of
    /// `TranslationLanguage.catalog`.
    static func detect(_ text: String) -> TranslationLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage else { return nil }

        return catalogLanguage(for: language)
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
}
