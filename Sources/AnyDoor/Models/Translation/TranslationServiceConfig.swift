import Foundation

/// A configured translation service instance. The first three kinds are seeded
/// zero-config; `openAICompatible` instances are user-added and carry the LLM
/// connection fields (the API key itself lives in the Keychain, not here).
struct TranslationServiceConfig: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var kind: TranslationServiceKind
    var displayName: String
    /// SF Symbol name shown on the service card.
    var iconName: String
    var enabled: Bool
    var order: Int
    /// `openAICompatible` only: base URL, e.g. "https://api.openai.com/v1".
    var baseURL: String?
    /// `openAICompatible` only: model identifier.
    var model: String?
    /// `openAICompatible` only: prompt with `{{source}}`, `{{target}}`, `{{text}}`.
    var promptTemplate: String?
}

extension TranslationServiceConfig {
    /// The built-in, zero-config services: Apple on-device, Google free, Bing free.
    static func seededDefaults() -> [TranslationServiceConfig] {
        [
            TranslationServiceConfig(
                id: TranslationServiceKind.apple.rawValue,
                kind: .apple,
                displayName: "Apple",
                iconName: "apple.logo",
                enabled: true,
                order: 0,
                baseURL: nil,
                model: nil,
                promptTemplate: nil
            ),
            TranslationServiceConfig(
                id: TranslationServiceKind.googleFree.rawValue,
                kind: .googleFree,
                displayName: "Google",
                iconName: "globe",
                enabled: true,
                order: 1,
                baseURL: nil,
                model: nil,
                promptTemplate: nil
            ),
            TranslationServiceConfig(
                id: TranslationServiceKind.bingFree.rawValue,
                kind: .bingFree,
                displayName: "Bing",
                iconName: "b.square",
                enabled: true,
                order: 2,
                baseURL: nil,
                model: nil,
                promptTemplate: nil
            ),
        ]
    }

    /// Whether `string` is a syntactically valid http(s) endpoint with a host.
    /// Used to gate Save in the editor sheet so an LLM service can't be saved
    /// with a base URL that would only fail later at request time (and then make
    /// the service silently vanish from the panel). Empty is invalid.
    static func isValidBaseURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return false
        }
        return true
    }

    /// Whether a prompt template still carries the `{{text}}` placeholder. A
    /// template without it would send the model an instruction with no source
    /// text, so the editor warns when it is missing.
    static func promptContainsText(_ template: String) -> Bool {
        template.contains("{{text}}")
    }

    /// Default LLM prompt template carrying the three placeholders.
    static let defaultPromptTemplate = """
    You are a professional translation engine. Translate the text from {{source}} \
    into {{target}}. Output only the translated text, with no explanations, \
    quotes, or additional commentary.

    {{text}}
    """
}
