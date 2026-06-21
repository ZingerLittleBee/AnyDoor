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

    /// Default LLM prompt template carrying the three placeholders.
    static let defaultPromptTemplate = """
    You are a professional translation engine. Translate the text from {{source}} \
    into {{target}}. Output only the translated text, with no explanations, \
    quotes, or additional commentary.

    {{text}}
    """
}
