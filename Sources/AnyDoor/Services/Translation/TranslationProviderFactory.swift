import Foundation

/// Builds the concrete stream `TranslationProvider` instances from the enabled,
/// non-apple service configs (in order). `apple` is intentionally excluded — it
/// is rendered by a dedicated SwiftUI card via `.translationTask`, not as a
/// stream provider. `openAICompatible` reads its secret from the Keychain and is
/// skipped when no key is stored or its baseURL/model are missing.
enum TranslationProviderFactory {
    /// Build the concrete stream provider for a single config, or `nil` when it
    /// has no stream provider (`apple` is rendered by its own card) or is an
    /// incomplete `openAICompatible` (no key / missing baseURL / missing model).
    /// Ignores `manualMode` — an explicit single build always builds.
    @MainActor
    static func makeStreamProvider(
        for config: TranslationServiceConfig,
        keychain: TranslationKeychainStore = TranslationKeychainStore(),
        session: URLSession = .shared
    ) -> (any TranslationProvider)? {
        switch config.kind {
        case .apple:
            return nil // rendered by AppleTranslationCard, not a stream provider
        case .googleFree:
            return GoogleFreeTranslationProvider(id: config.id, session: session)
        case .bingFree:
            return BingFreeTranslationProvider(id: config.id, session: session)
        case .openAICompatible:
            guard let key = keychain.apiKey(for: config.id),
                  !key.isEmpty,
                  let baseURL = config.baseURL, !baseURL.isEmpty,
                  let model = config.model, !model.isEmpty else {
                return nil // no key or incomplete config -> skip silently
            }
            _ = (baseURL, model) // config carries them; provider reads from config
            return OpenAICompatibleProvider(config: config, apiKey: key, session: session)
        case .deepl:
            return nil // DeepL provider not yet implemented
        }
    }

    /// Build the auto fan-out providers: enabled, non-apple, **non-manual**
    /// services in order. Manual services are excluded — they translate on
    /// demand via `TranslationCoordinator.translateOne`, not the fan-out.
    @MainActor
    static func makeStreamProviders(
        settings: TranslationSettings,
        keychain: TranslationKeychainStore = TranslationKeychainStore(),
        session: URLSession = .shared
    ) -> [any TranslationProvider] {
        settings.enabledServicesInOrder
            .filter { !$0.startsManual }
            .compactMap { makeStreamProvider(for: $0, keychain: keychain, session: session) }
    }
}
