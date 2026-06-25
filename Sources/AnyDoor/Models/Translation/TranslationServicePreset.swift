import Foundation

/// A one-click "add by provider" template. Selecting a preset pre-fills a new
/// `TranslationServiceConfig` so the user only supplies an API key. Pure data +
/// a draft builder; the menu and editor live in the views layer. Brand display
/// names are intentionally not localized; the "custom" sentinel renders its menu
/// label from `L10n` in the view.
struct TranslationServicePreset: Identifiable, Sendable {
    let id: String
    let displayName: String
    let iconName: String
    let kind: TranslationServiceKind
    let baseURL: String?
    let model: String?
    let promptTemplate: String?
    let extraBodyJSON: String?
    let defaultAPIKey: String?

    /// Builds a fresh draft config from this preset. `id` is injected (the view
    /// passes a new UUID) so the builder stays pure and testable. Returns the
    /// config plus the editor's initial key (empty unless the preset pre-fills one).
    func makeDraft(order: Int, id: String) -> (config: TranslationServiceConfig, apiKey: String) {
        let config = TranslationServiceConfig(
            id: id,
            kind: kind,
            displayName: displayName,
            iconName: iconName,
            enabled: true,
            order: order,
            baseURL: baseURL,
            model: model,
            promptTemplate: promptTemplate,
            extraBodyJSON: extraBodyJSON
        )
        return (config, defaultAPIKey ?? "")
    }

    /// DeepL first, then the LLM providers, then a blank custom sentinel. Model
    /// ids/base URLs are the spec's verified values (2026-06).
    static let catalog: [TranslationServicePreset] = [
        TranslationServicePreset(id: "deepl", displayName: "DeepL", iconName: "character.book.closed",
            kind: .deepl, baseURL: nil, model: nil, promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
        TranslationServicePreset(id: "openai", displayName: "OpenAI", iconName: "brain",
            kind: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-5.4-mini",
            promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
        TranslationServicePreset(id: "deepseek", displayName: "DeepSeek", iconName: "brain",
            kind: .openAICompatible, baseURL: "https://api.deepseek.com", model: "deepseek-v4-flash",
            promptTemplate: nil, extraBodyJSON: #"{"thinking":{"type":"disabled"}}"#, defaultAPIKey: nil),
        TranslationServicePreset(id: "dashscope", displayName: "通义千问 Qwen", iconName: "brain",
            kind: .openAICompatible, baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            model: "qwen-plus", promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
        TranslationServicePreset(id: "gemini", displayName: "Gemini", iconName: "sparkles",
            kind: .openAICompatible, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
            model: "gemini-3.5-flash", promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
        TranslationServicePreset(id: "moonshot", displayName: "Kimi", iconName: "brain",
            kind: .openAICompatible, baseURL: "https://api.moonshot.ai/v1", model: "kimi-k2.6",
            promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
        TranslationServicePreset(id: "zhipu", displayName: "智谱 GLM", iconName: "brain",
            kind: .openAICompatible, baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4.7-flash",
            promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
        TranslationServicePreset(id: "openrouter", displayName: "OpenRouter", iconName: "arrow.triangle.branch",
            kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1", model: "google/gemini-3.5-flash",
            promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
        TranslationServicePreset(id: "ollama", displayName: "Ollama", iconName: "desktopcomputer",
            kind: .openAICompatible, baseURL: "http://localhost:11434/v1/", model: "qwen3:4b",
            promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: "ollama"),
        TranslationServicePreset(id: "custom", displayName: "", iconName: "slider.horizontal.3",
            kind: .openAICompatible, baseURL: nil, model: nil, promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
    ]
}
