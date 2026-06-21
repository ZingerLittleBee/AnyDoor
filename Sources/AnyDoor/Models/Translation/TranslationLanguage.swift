import Foundation
import NaturalLanguage

/// A translation language identified by canonical BCP-47, with the metadata the
/// translation subsystem needs: an English fallback name, the matching
/// `NLLanguage` (for detection / TTS), and per-service code remapping.
struct TranslationLanguage: Hashable, Codable, Sendable, Identifiable {
    /// Canonical BCP-47 code, e.g. "en", "zh-Hans", "ja".
    let code: String
    /// English display name, used as a fallback when localization is unavailable.
    let englishName: String
    /// `NLLanguage` raw value, nil when no natural-language mapping applies.
    let nlLanguageRaw: String?

    var id: String { code }

    var nlLanguage: NLLanguage? { nlLanguageRaw.map { NLLanguage(rawValue: $0) } }

    /// Localized language name for the given locale, falling back to `englishName`.
    func displayName(in locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: code) ?? englishName
    }

    /// The code a given service expects. Google / Bing diverge from BCP-47 for a
    /// few languages (notably `zh-Hans` -> `zh-CN`, `zh-Hant` -> `zh-TW`).
    func serviceCode(for kind: TranslationServiceKind) -> String {
        switch kind {
        case .googleFree, .bingFree:
            return Self.serviceCodeRemap[code] ?? code
        case .apple, .openAICompatible:
            return code
        }
    }

    /// Overrides applied for Google / Bing free endpoints. Anything not listed
    /// passes through unchanged.
    private static let serviceCodeRemap: [String: String] = [
        "zh-Hans": "zh-CN",
        "zh-Hant": "zh-TW",
    ]

    /// Reverse of `serviceCodeRemap`: maps a service-specific code back to its
    /// canonical BCP-47 catalog code (e.g. "zh-CN" -> "zh-Hans").
    private static let serviceCodeReverseRemap: [String: String] = [
        "zh-CN": "zh-Hans",
        "zh-TW": "zh-Hant",
    ]

    /// Resolves a code returned by a service's detection response into a catalog
    /// `TranslationLanguage`. Google / Bing report service codes (e.g. "zh-CN" /
    /// "zh-TW") that diverge from the catalog's canonical BCP-47 codes, so the
    /// service code is remapped before lookup. Codes already in canonical form
    /// (e.g. "en") pass through unchanged.
    static func fromServiceCode(_ code: String, for kind: TranslationServiceKind) -> TranslationLanguage? {
        switch kind {
        case .googleFree, .bingFree:
            let canonical = serviceCodeReverseRemap[code] ?? code
            return named(canonical)
        case .apple, .openAICompatible:
            return named(code)
        }
    }
}

extension TranslationLanguage {
    /// ~25 common languages covering the default service surface.
    static let catalog: [TranslationLanguage] = [
        TranslationLanguage(code: "en", englishName: "English", nlLanguageRaw: NLLanguage.english.rawValue),
        TranslationLanguage(code: "zh-Hans", englishName: "Chinese (Simplified)", nlLanguageRaw: NLLanguage.simplifiedChinese.rawValue),
        TranslationLanguage(code: "zh-Hant", englishName: "Chinese (Traditional)", nlLanguageRaw: NLLanguage.traditionalChinese.rawValue),
        TranslationLanguage(code: "ja", englishName: "Japanese", nlLanguageRaw: NLLanguage.japanese.rawValue),
        TranslationLanguage(code: "ko", englishName: "Korean", nlLanguageRaw: NLLanguage.korean.rawValue),
        TranslationLanguage(code: "fr", englishName: "French", nlLanguageRaw: NLLanguage.french.rawValue),
        TranslationLanguage(code: "de", englishName: "German", nlLanguageRaw: NLLanguage.german.rawValue),
        TranslationLanguage(code: "es", englishName: "Spanish", nlLanguageRaw: NLLanguage.spanish.rawValue),
        TranslationLanguage(code: "pt", englishName: "Portuguese", nlLanguageRaw: NLLanguage.portuguese.rawValue),
        TranslationLanguage(code: "it", englishName: "Italian", nlLanguageRaw: NLLanguage.italian.rawValue),
        TranslationLanguage(code: "ru", englishName: "Russian", nlLanguageRaw: NLLanguage.russian.rawValue),
        TranslationLanguage(code: "ar", englishName: "Arabic", nlLanguageRaw: NLLanguage.arabic.rawValue),
        TranslationLanguage(code: "hi", englishName: "Hindi", nlLanguageRaw: NLLanguage.hindi.rawValue),
        TranslationLanguage(code: "th", englishName: "Thai", nlLanguageRaw: NLLanguage.thai.rawValue),
        TranslationLanguage(code: "vi", englishName: "Vietnamese", nlLanguageRaw: NLLanguage.vietnamese.rawValue),
        TranslationLanguage(code: "id", englishName: "Indonesian", nlLanguageRaw: NLLanguage.indonesian.rawValue),
        TranslationLanguage(code: "tr", englishName: "Turkish", nlLanguageRaw: NLLanguage.turkish.rawValue),
        TranslationLanguage(code: "nl", englishName: "Dutch", nlLanguageRaw: NLLanguage.dutch.rawValue),
        TranslationLanguage(code: "pl", englishName: "Polish", nlLanguageRaw: NLLanguage.polish.rawValue),
        TranslationLanguage(code: "uk", englishName: "Ukrainian", nlLanguageRaw: NLLanguage.ukrainian.rawValue),
        TranslationLanguage(code: "sv", englishName: "Swedish", nlLanguageRaw: NLLanguage.swedish.rawValue),
        TranslationLanguage(code: "cs", englishName: "Czech", nlLanguageRaw: NLLanguage.czech.rawValue),
        TranslationLanguage(code: "el", englishName: "Greek", nlLanguageRaw: NLLanguage.greek.rawValue),
        TranslationLanguage(code: "he", englishName: "Hebrew", nlLanguageRaw: NLLanguage.hebrew.rawValue),
        TranslationLanguage(code: "ro", englishName: "Romanian", nlLanguageRaw: NLLanguage.romanian.rawValue),
        TranslationLanguage(code: "da", englishName: "Danish", nlLanguageRaw: NLLanguage.danish.rawValue),
        TranslationLanguage(code: "fi", englishName: "Finnish", nlLanguageRaw: NLLanguage.finnish.rawValue),
    ]

    static func named(_ code: String) -> TranslationLanguage? {
        catalog.first { $0.code == code }
    }

    static let english = TranslationLanguage(
        code: "en",
        englishName: "English",
        nlLanguageRaw: NLLanguage.english.rawValue
    )

    static let simplifiedChinese = TranslationLanguage(
        code: "zh-Hans",
        englishName: "Chinese (Simplified)",
        nlLanguageRaw: NLLanguage.simplifiedChinese.rawValue
    )

    /// The first of `Locale.preferredLanguages` that maps into the catalog,
    /// falling back to English.
    static var systemDefault: TranslationLanguage {
        for preferred in Locale.preferredLanguages {
            let canonical = Locale(identifier: preferred)
            if let language = canonical.language.languageCode?.identifier {
                let script = canonical.language.script?.identifier
                if let script,
                   let match = named("\(language)-\(script)") {
                    return match
                }
                if let match = named(language) {
                    return match
                }
            }
            if let match = named(preferred) {
                return match
            }
        }
        return english
    }
}
