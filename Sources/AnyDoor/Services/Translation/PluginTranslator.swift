import Foundation

/// Headless translation backing the Script Plugin `translate` capability
/// (`anydoor.translate`): translate text into the user's configured target
/// language through the user's own translation services.
///
/// Policy (grilled decisions):
/// - The target language is always `TranslationSettings.targetLanguage` — a
///   plugin cannot choose the direction. Source is provider auto-detect.
/// - The provider is the *first* enabled service (user order) that builds a
///   stream provider. Apple is skipped structurally (it has no headless path,
///   only the SwiftUI card), incomplete configs are skipped by the factory,
///   and manual-mode services are skipped deliberately: the user marked them
///   translate-only-when-I-ask, and an unattended plugin call is exactly the
///   spending that flag exists to prevent.
/// - No automatic fallback to the next service on a runtime failure — chaining
///   would spend multiple paid quotas per call; a failure should be
///   predictable and attributable.
/// - Nothing is written to `TranslationRecord` history and no toast is shown;
///   the result and the failure both belong to the calling plugin.
@MainActor
enum PluginTranslator {
    static func translate(
        _ text: String,
        settings: TranslationSettings = .shared
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let provider = settings.enabledServicesInOrder
            .filter { !$0.startsManual }
            .lazy
            .compactMap { TranslationProviderFactory.makeStreamProvider(for: $0) }
            .first
        guard let provider else {
            throw PluginTranslationError.noUsableService
        }

        let request = TranslationRequest(text: text, source: nil, target: settings.targetLanguage)
        do {
            let translated = try await collect(provider.translate(request))
            guard !translated.isEmpty else {
                throw TranslationProviderError.emptyResponse
            }
            return translated
        } catch let error as TranslationProviderError {
            // Map provider errors through the shared human-readable text so the
            // plugin's rejection message matches what the translation panel
            // would have shown.
            throw PluginTranslationError.provider(translationErrorMessage(error))
        }
    }

    /// Collapse a provider's chunk stream into the final translated text,
    /// mirroring the coordinator's accumulation rule: deltas append, and a
    /// non-empty `.final` is authoritative over whatever accumulated.
    static func collect(
        _ stream: AsyncThrowingStream<TranslationChunk, Error>
    ) async throws -> String {
        var accumulated = ""
        for try await chunk in stream {
            switch chunk {
            case .detected:
                break
            case .delta(let piece):
                accumulated += piece
            case .final(let full):
                if !full.isEmpty { accumulated = full }
            }
        }
        return accumulated
    }
}

/// Failures of the plugin translate capability, surfaced to the calling plugin
/// as its promise-rejection message.
enum PluginTranslationError: LocalizedError {
    /// No enabled, buildable, non-manual translation service exists.
    case noUsableService
    /// The chosen provider failed; carries the shared human-readable message.
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .noUsableService:
            return "no usable translation service is configured in Settings"
        case .provider(let message):
            return message
        }
    }
}
