import XCTest

@testable import AnyDoor

/// Pins the Script Plugin `translate` capability policy (ADR-0009 amendment):
/// the provider is the first enabled non-manual service with no fallback (an
/// unattended plugin call must never spend a manual-only paid quota), the
/// direction is forced to the user's target language, and the stream-collapse
/// rule mirrors the coordinator's accumulation (deltas accumulate, a non-empty
/// `.final` is authoritative, `.detected` is ignored).
@MainActor
final class PluginTranslatorTests: XCTestCase {

    private func stream(_ chunks: [TranslationChunk]) -> AsyncThrowingStream<TranslationChunk, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    // MARK: - Service-selection policy

    /// Records every request it receives; `@unchecked Sendable` is sound here
    /// because these tests build and consume it on the MainActor only.
    private final class StubProvider: TranslationProvider, @unchecked Sendable {
        let id: String
        let kind: TranslationServiceKind
        private let chunks: [TranslationChunk]
        private let failure: TranslationProviderError?
        private(set) var requests: [TranslationRequest] = []

        init(
            id: String,
            kind: TranslationServiceKind = .googleFree,
            chunks: [TranslationChunk],
            failure: TranslationProviderError? = nil
        ) {
            self.id = id
            self.kind = kind
            self.chunks = chunks
            self.failure = failure
        }

        func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationChunk, Error> {
            requests.append(request)
            let chunks = chunks
            let failure = failure
            return AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    private func service(
        _ id: String,
        kind: TranslationServiceKind = .googleFree,
        enabled: Bool = true,
        order: Int,
        manual: Bool = false
    ) -> TranslationServiceConfig {
        TranslationServiceConfig(
            id: id,
            kind: kind,
            displayName: id,
            iconName: "globe",
            enabled: enabled,
            order: order,
            baseURL: nil,
            model: nil,
            promptTemplate: nil,
            manualMode: manual
        )
    }

    private func makeSettings(
        services: [TranslationServiceConfig],
        target: TranslationLanguage = .simplifiedChinese
    ) -> TranslationSettings {
        let suite = "plugin-translator.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = TranslationSettings(defaults: defaults)
        settings.setServices(services)
        settings.setTargetLanguageCode(target.code)
        return settings
    }

    func testManualServicesAreNeverConsulted() async throws {
        let settings = makeSettings(services: [
            service("llm", kind: .openAICompatible, order: 0, manual: true),
            service("google", order: 1),
        ])
        let google = StubProvider(id: "google", chunks: [.final("你好")])
        var asked: [String] = []
        let result = try await PluginTranslator.translate("hello", settings: settings) { config in
            asked.append(config.id)
            return config.id == "google" ? google : nil
        }
        XCTAssertEqual(asked, ["google"], "the manual service must not even reach the factory")
        XCTAssertEqual(result, "你好")
    }

    func testDisabledServicesAreSkipped() async throws {
        let settings = makeSettings(services: [
            service("google", enabled: false, order: 0),
            service("bing", kind: .bingFree, order: 1),
        ])
        let bing = StubProvider(id: "bing", kind: .bingFree, chunks: [.final("译文")])
        var asked: [String] = []
        _ = try await PluginTranslator.translate("hello", settings: settings) { config in
            asked.append(config.id)
            return config.id == "bing" ? bing : nil
        }
        XCTAssertEqual(asked, ["bing"])
    }

    func testFactoryDeclinedServiceFallsThroughToNextAtSelectionTime() async throws {
        // Apple (no headless path) and incomplete configs surface as a nil
        // build; selection moves on, unlike a *runtime* failure which must not.
        let settings = makeSettings(services: [
            service("apple", kind: .apple, order: 0),
            service("google", order: 1),
        ])
        let google = StubProvider(id: "google", chunks: [.final("译文")])
        var asked: [String] = []
        let result = try await PluginTranslator.translate("hello", settings: settings) { config in
            asked.append(config.id)
            return config.id == "google" ? google : nil
        }
        XCTAssertEqual(asked, ["apple", "google"])
        XCTAssertEqual(result, "译文")
    }

    func testRuntimeFailureDoesNotFallBackToTheNextService() async {
        let settings = makeSettings(services: [
            service("google", order: 0),
            service("bing", kind: .bingFree, order: 1),
        ])
        let google = StubProvider(id: "google", chunks: [], failure: .badResponse(500))
        let bing = StubProvider(id: "bing", kind: .bingFree, chunks: [.final("译文")])
        var asked: [String] = []
        do {
            _ = try await PluginTranslator.translate("hello", settings: settings) { config in
                asked.append(config.id)
                return config.id == "google" ? google : bing
            }
            XCTFail("expected the first provider's failure to surface")
        } catch let error as PluginTranslationError {
            guard case .provider(let message) = error else {
                return XCTFail("unexpected error case: \(error)")
            }
            XCTAssertEqual(message, translationErrorMessage(TranslationProviderError.badResponse(500)))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(asked, ["google"], "no second provider may be built after a runtime failure")
        XCTAssertTrue(bing.requests.isEmpty, "the failure must not spend the next service's quota")
    }

    func testRequestForcesSettingsTargetAndAutoDetectSource() async throws {
        let settings = makeSettings(services: [service("google", order: 0)], target: .english)
        let google = StubProvider(id: "google", chunks: [.final("hello")])
        _ = try await PluginTranslator.translate("你好", settings: settings) { _ in google }
        XCTAssertEqual(
            google.requests,
            [TranslationRequest(text: "你好", source: nil, target: .english)]
        )
    }

    func testThrowsNoUsableServiceWhenOnlyManualServicesExist() async {
        let settings = makeSettings(services: [
            service("llm", kind: .openAICompatible, order: 0, manual: true),
        ])
        do {
            _ = try await PluginTranslator.translate("hello", settings: settings) { _ in
                XCTFail("no service should be built")
                return nil
            }
            XCTFail("expected noUsableService")
        } catch let error as PluginTranslationError {
            guard case .noUsableService = error else {
                return XCTFail("unexpected error case: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testWhitespaceInputReturnsUnchangedWithoutConsultingServices() async throws {
        let settings = makeSettings(services: [service("google", order: 0)])
        let input = "  \n\t"
        let result = try await PluginTranslator.translate(input, settings: settings) { _ in
            XCTFail("whitespace input must not build a provider")
            return nil
        }
        XCTAssertEqual(result, input)
    }

    func testEmptyTranslationSurfacesEmptyResponse() async {
        let settings = makeSettings(services: [service("google", order: 0)])
        let google = StubProvider(id: "google", chunks: [.final("")])
        do {
            _ = try await PluginTranslator.translate("hello", settings: settings) { _ in google }
            XCTFail("expected an empty translation to surface as a failure")
        } catch let error as PluginTranslationError {
            guard case .provider(let message) = error else {
                return XCTFail("unexpected error case: \(error)")
            }
            XCTAssertEqual(message, translationErrorMessage(TranslationProviderError.emptyResponse))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Stream collapse

    func testDeltasAccumulateInOrder() async throws {
        let text = try await PluginTranslator.collect(stream([
            .delta("你"), .delta("好"), .final(""),
        ]))
        XCTAssertEqual(text, "你好")
    }

    func testNonEmptyFinalOverridesAccumulatedDeltas() async throws {
        let text = try await PluginTranslator.collect(stream([
            .delta("partial"), .final("complete translation"),
        ]))
        XCTAssertEqual(text, "complete translation")
    }

    func testOneShotProviderSingleFinal() async throws {
        let text = try await PluginTranslator.collect(stream([
            .detected(.systemDefault), .final("翻译结果"),
        ]))
        XCTAssertEqual(text, "翻译结果")
    }

    func testThrowingStreamPropagates() async {
        let failing = AsyncThrowingStream<TranslationChunk, Error> { continuation in
            continuation.yield(.delta("half"))
            continuation.finish(throwing: TranslationProviderError.badResponse(500))
        }
        do {
            _ = try await PluginTranslator.collect(failing)
            XCTFail("expected the stream failure to propagate")
        } catch let error as TranslationProviderError {
            XCTAssertEqual(error, .badResponse(500))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
