import XCTest
@testable import AnyDoor

@MainActor
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

    private func makeSettings(_ configs: [TranslationServiceConfig]) -> TranslationSettings {
        let d = UserDefaults(suiteName: defaultsSuite)!
        let s = TranslationSettings(defaults: d)
        s.setServices(configs)
        return s
    }

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
}
