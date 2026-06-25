import XCTest
@testable import AnyDoor

final class TranslationProviderFactoryTests: XCTestCase {
    private var defaultsSuite = ""
    private var keychainService = ""

    override func setUp() {
        super.setUp()
        defaultsSuite = "translation.factory.tests.\(UUID().uuidString)"
        keychainService = "dev.bybee.AnyDoor.translation.factory.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        let keychain = TranslationKeychainStore(service: keychainService)
        keychain.deleteAPIKey(for: "llm-keyed")
        keychain.deleteAPIKey(for: "llm-keyless")
        keychain.deleteAPIKey(for: "single-llm")
        keychain.deleteAPIKey(for: "manual")
        keychain.deleteAPIKey(for: "auto")
        keychain.deleteAPIKey(for: "deepl")
        keychain.deleteAPIKey(for: "deeplx")
        super.tearDown()
    }

    private func makeConfig(id: String,
                            kind: TranslationServiceKind,
                            order: Int,
                            enabled: Bool = true,
                            baseURL: String? = nil,
                            model: String? = nil) -> TranslationServiceConfig {
        TranslationServiceConfig(
            id: id,
            kind: kind,
            displayName: id,
            iconName: "globe",
            enabled: enabled,
            order: order,
            baseURL: baseURL,
            model: model,
            promptTemplate: TranslationServiceConfig.defaultPromptTemplate
        )
    }

    @MainActor
    private func makeSettings(_ configs: [TranslationServiceConfig]) -> TranslationSettings {
        let d = UserDefaults(suiteName: defaultsSuite)!
        let s = TranslationSettings(defaults: d)
        s.setServices(configs)
        return s
    }

    @MainActor
    func testBuildsNonAppleStreamProvidersInOrder() {
        let keychain = TranslationKeychainStore(service: keychainService)
        keychain.setAPIKey("sk-123", for: "llm-keyed")
        let settings = makeSettings([
            makeConfig(id: "apple", kind: .apple, order: 0),
            makeConfig(id: "google", kind: .googleFree, order: 1),
            makeConfig(id: "bing", kind: .bingFree, order: 2),
            makeConfig(id: "llm-keyed", kind: .openAICompatible, order: 3,
                       baseURL: "https://api.example.com/v1", model: "gpt-x"),
        ])
        let providers = TranslationProviderFactory.makeStreamProviders(
            settings: settings, keychain: keychain)
        XCTAssertEqual(providers.map(\.kind), [.googleFree, .bingFree, .openAICompatible])
        XCTAssertEqual(providers.map(\.id), ["google", "bing", "llm-keyed"])
    }

    @MainActor
    func testSkipsAppleAndDisabledServices() {
        let settings = makeSettings([
            makeConfig(id: "apple", kind: .apple, order: 0),
            makeConfig(id: "google", kind: .googleFree, order: 1, enabled: false),
            makeConfig(id: "bing", kind: .bingFree, order: 2),
        ])
        let providers = TranslationProviderFactory.makeStreamProviders(
            settings: settings, keychain: TranslationKeychainStore(service: keychainService))
        XCTAssertEqual(providers.map(\.id), ["bing"])
    }

    @MainActor
    func testSkipsOpenAIWithoutKeychainKey() {
        let keychain = TranslationKeychainStore(service: keychainService)
        keychain.setAPIKey("sk-123", for: "llm-keyed")
        // "llm-keyless" intentionally has NO key stored.
        let settings = makeSettings([
            makeConfig(id: "llm-keyed", kind: .openAICompatible, order: 0,
                       baseURL: "https://api.example.com/v1", model: "gpt-x"),
            makeConfig(id: "llm-keyless", kind: .openAICompatible, order: 1,
                       baseURL: "https://api.example.com/v1", model: "gpt-x"),
        ])
        let providers = TranslationProviderFactory.makeStreamProviders(
            settings: settings, keychain: keychain)
        XCTAssertEqual(providers.map(\.id), ["llm-keyed"])
    }

    @MainActor
    func testMakeStreamProviderBuildsSingleSkipsAppleAndIncomplete() {
        let keychain = TranslationKeychainStore(service: keychainService)
        keychain.setAPIKey("sk-1", for: "single-llm")

        XCTAssertNil(TranslationProviderFactory.makeStreamProvider(
            for: makeConfig(id: "apple", kind: .apple, order: 0), keychain: keychain))

        XCTAssertNotNil(TranslationProviderFactory.makeStreamProvider(
            for: makeConfig(id: "google", kind: .googleFree, order: 0), keychain: keychain))

        XCTAssertNotNil(TranslationProviderFactory.makeStreamProvider(
            for: makeConfig(id: "single-llm", kind: .openAICompatible, order: 0,
                            baseURL: "https://api.example.com/v1", model: "gpt-x"),
            keychain: keychain))

        // Incomplete LLM config (no model) -> nil
        XCTAssertNil(TranslationProviderFactory.makeStreamProvider(
            for: makeConfig(id: "single-llm", kind: .openAICompatible, order: 0,
                            baseURL: "https://api.example.com/v1", model: nil),
            keychain: keychain))
    }

    @MainActor
    func testBuildsDeepLOfficialWhenKeyed() {
        let keychain = TranslationKeychainStore(service: keychainService)
        keychain.setAPIKey("dk:fx", for: "deepl")
        let config = makeConfig(id: "deepl", kind: .deepl, order: 0)
        let provider = TranslationProviderFactory.makeStreamProvider(
            for: config, keychain: keychain, session: .shared)
        XCTAssertEqual(provider?.kind, .deepl)
    }

    @MainActor
    func testSkipsDeepLOfficialWithoutKey() {
        let keychain = TranslationKeychainStore(service: keychainService)
        let config = makeConfig(id: "deepl", kind: .deepl, order: 0)
        XCTAssertNil(TranslationProviderFactory.makeStreamProvider(
            for: config, keychain: keychain, session: .shared))
    }

    @MainActor
    func testBuildsDeepLXWithBaseURLAndNoKey() {
        let keychain = TranslationKeychainStore(service: keychainService)
        let config = makeConfig(id: "deeplx", kind: .deepl, order: 0, baseURL: "http://localhost:1188")
        let provider = TranslationProviderFactory.makeStreamProvider(
            for: config, keychain: keychain, session: .shared)
        XCTAssertEqual(provider?.kind, .deepl)
    }

    @MainActor
    func testSkipsDeepLXWithInvalidBaseURL() {
        let keychain = TranslationKeychainStore(service: keychainService)
        let config = makeConfig(id: "deeplx", kind: .deepl, order: 0, baseURL: "not-a-url")
        XCTAssertNil(TranslationProviderFactory.makeStreamProvider(
            for: config, keychain: keychain, session: .shared))
    }

    @MainActor
    func testMakeStreamProvidersExcludesManualServices() {
        let keychain = TranslationKeychainStore(service: keychainService)
        keychain.setAPIKey("sk-1", for: "manual")
        keychain.setAPIKey("sk-2", for: "auto")
        var manual = makeConfig(id: "manual", kind: .openAICompatible, order: 0,
                                baseURL: "https://api.example.com/v1", model: "gpt-x")
        manual.manualMode = true
        let auto = makeConfig(id: "auto", kind: .openAICompatible, order: 1,
                              baseURL: "https://api.example.com/v1", model: "gpt-x")
        let settings = makeSettings([manual, auto])
        let providers = TranslationProviderFactory.makeStreamProviders(
            settings: settings, keychain: keychain)
        XCTAssertEqual(providers.map(\.id), ["auto"])
    }
}
