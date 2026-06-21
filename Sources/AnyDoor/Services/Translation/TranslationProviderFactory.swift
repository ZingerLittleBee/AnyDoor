import Foundation

/// Builds the concrete stream `TranslationProvider` instances from the enabled,
/// non-apple service configs (in order). `apple` is intentionally excluded — it
/// is rendered by a dedicated SwiftUI card via `.translationTask`, not as a
/// stream provider. `openAICompatible` reads its secret from the Keychain and is
/// skipped when no key is stored or its baseURL/model are missing.
enum TranslationProviderFactory {
    @MainActor
    static func makeStreamProviders(
        settings: TranslationSettings,
        keychain: TranslationKeychainStore = TranslationKeychainStore(),
        session: URLSession = .shared
    ) -> [any TranslationProvider] {
        var providers: [any TranslationProvider] = []
        for config in settings.enabledServicesInOrder {
            switch config.kind {
            case .apple:
                continue // rendered by AppleTranslationCard, not a stream provider
            case .googleFree:
                providers.append(GoogleFreeTranslationProvider(id: config.id, session: session))
            case .bingFree:
                providers.append(BingFreeTranslationProvider(id: config.id, session: session))
            case .openAICompatible:
                guard let key = keychain.apiKey(for: config.id),
                      !key.isEmpty,
                      let baseURL = config.baseURL, !baseURL.isEmpty,
                      let model = config.model, !model.isEmpty else {
                    continue // no key or incomplete config -> skip silently
                }
                _ = (baseURL, model) // config carries them; provider reads from config
                providers.append(OpenAICompatibleProvider(config: config, apiKey: key, session: session))
            }
        }
        return providers
    }
}
