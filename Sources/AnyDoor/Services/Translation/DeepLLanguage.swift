import Foundation

/// DeepL language-code mapping, kept pure so it can be unit-tested without a
/// network or UI. DeepL's source side uses variant-agnostic base codes (`ZH`,
/// `EN`) while its target side prefers variant codes (`ZH-HANS`, `EN-US`); the
/// unofficial DeepLX proxy mirrors the older API and wants base codes for both.
/// The dictionary is keyed explicitly by every `TranslationLanguage.catalog`
/// code so regional-variant languages are pinned, never gambled.
enum DeepLLanguage {
    /// Official DeepL `target_lang` per catalog code. Variant-sensitive languages
    /// (`en`, `zh-*`, `pt`) are pinned; the rest are their uppercased base, listed
    /// so a reviewer can audit every language rather than trusting a fallback.
    private static let officialTarget: [String: String] = [
        "en": "EN-US", "zh-Hans": "ZH-HANS", "zh-Hant": "ZH-HANT",
        "ja": "JA", "ko": "KO", "fr": "FR", "de": "DE", "es": "ES",
        "pt": "PT-PT", "it": "IT", "ru": "RU", "ar": "AR", "hi": "HI",
        "th": "TH", "vi": "VI", "id": "ID", "tr": "TR", "nl": "NL",
        "pl": "PL", "uk": "UK", "sv": "SV", "cs": "CS", "el": "EL",
        "he": "HE", "ro": "RO", "da": "DA", "fi": "FI",
    ]

    /// `target_lang` for a translation. DeepLX wants base codes (`ZH`, `EN`, `PT`)
    /// where official prefers variants.
    static func targetCode(_ lang: TranslationLanguage, deeplx: Bool) -> String {
        if deeplx {
            switch lang.code {
            case "en": return "EN"
            case "zh-Hans", "zh-Hant": return "ZH"
            case "pt": return "PT"
            default:
                // DeepLX wants base codes, so strip any region variant rather
                // than reusing the variant-oriented officialTarget map (which
                // would leak e.g. EN-US if a new variant code joined the catalog
                // without its own case above).
                let base = lang.code.split(separator: "-").first.map(String.init) ?? lang.code
                return base.uppercased()
            }
        }
        return officialTarget[lang.code] ?? lang.code.uppercased()
    }

    /// `source_lang` for a translation — always a base code. Returns nil to omit
    /// for auto-detect (official) or "auto" (DeepLX, which wants an explicit value).
    static func sourceCode(_ lang: TranslationLanguage?, deeplx: Bool) -> String? {
        guard let lang else { return deeplx ? "auto" : nil }
        switch lang.code {
        case "zh-Hans", "zh-Hant": return "ZH"
        default:
            let base = lang.code.split(separator: "-").first.map(String.init) ?? lang.code
            return base.uppercased()
        }
    }

    /// Resolves a DeepL detected-source code (e.g. "EN", "ZH", "JA") back to a
    /// catalog language. DeepL detection does not distinguish Hans/Hant, so "ZH"
    /// defaults to Simplified.
    static func language(fromDetected code: String) -> TranslationLanguage? {
        let upper = code.uppercased()
        if upper.hasPrefix("ZH") { return .simplifiedChinese }
        if upper.hasPrefix("EN") { return .english }
        return TranslationLanguage.named(code.lowercased())
            ?? TranslationLanguage.named(String(code.prefix(2)).lowercased())
    }
}
