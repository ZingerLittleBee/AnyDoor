import XCTest
@testable import AnyDoor

final class BingFreeTranslationProviderTests: XCTestCase {
    /// Captured 2026-09-14T14:57:54Z from
    /// `POST https://edge.microsoft.com/translate/translatetext?from=&to=zh-CN&isEnterpriseClient=false`
    /// body `["Mythos"]`.
    private static let mythosProbeJSON = Data(
        #"""
        [{"detectedLanguage":{"language":"de","score":0.91},"translations":[{"text":"神话","to":"zh-Hans","sentLen":{"srcSentLen":[6],"transSentLen":[2]}}]}]
        """#.utf8
    )

    override func setUp() {
        super.setUp()
        BingTranslateHTTPStub.reset()
    }

    override func tearDown() {
        BingTranslateHTTPStub.reset()
        super.tearDown()
    }

    // MARK: - request construction

    func testBuildTranslateRequestAutoSourceMatchesObservedQueryAndBody() throws {
        let request = BingFreeTranslationProvider.buildTranslateRequest(
            text: "Mythos",
            source: nil,
            target: "zh-CN"
        )
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "edge.microsoft.com")
        XCTAssertEqual(components.path, "/translate/translatetext")
        XCTAssertEqual(components.percentEncodedQuery, "from=&to=zh-CN&isEnterpriseClient=false")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String]
        XCTAssertEqual(decoded, ["Mythos"])
    }

    func testBuildTranslateRequestExplicitSourceSetsFrom() throws {
        let request = BingFreeTranslationProvider.buildTranslateRequest(
            text: "hello",
            source: "en",
            target: "zh-CN"
        )
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedQuery, "from=en&to=zh-CN&isEnterpriseClient=false")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String]
        XCTAssertEqual(decoded, ["hello"])
    }

    // MARK: - decode

    func testDecodeReadsTextAndDetectedLanguage() throws {
        let result = try BingFreeTranslationProvider.decode(Self.mythosProbeJSON)
        XCTAssertEqual(result.text, "神话")
        XCTAssertEqual(result.detectedCode, "de")
    }

    func testDecodeWithoutDetectedLanguageIsNil() throws {
        let json = #"""
        [{"translations":[{"text":"hola","to":"es"}]}]
        """#
        let result = try BingFreeTranslationProvider.decode(Data(json.utf8))
        XCTAssertEqual(result.text, "hola")
        XCTAssertNil(result.detectedCode)
    }

    func testDecodeEmptyArrayThrows() {
        XCTAssertThrowsError(try BingFreeTranslationProvider.decode(Data("[]".utf8))) { error in
            XCTAssertEqual(error as? TranslationProviderError, .decodeFailed)
        }
    }

    func testDecodeEmptyDataThrows() {
        XCTAssertThrowsError(try BingFreeTranslationProvider.decode(Data())) { error in
            XCTAssertEqual(error as? TranslationProviderError, .decodeFailed)
        }
    }

    func testDecodeReadsChineseServiceDetectedCode() throws {
        // Bing reports the service code "zh-CN" (not the catalog "zh-Hans") when
        // Simplified Chinese is auto-detected as the source.
        let json = #"""
        [{"detectedLanguage":{"language":"zh-CN","score":1.0},"translations":[{"text":"hello","to":"en"}]}]
        """#
        let result = try BingFreeTranslationProvider.decode(Data(json.utf8))
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.detectedCode, "zh-CN")
        XCTAssertEqual(
            TranslationLanguage.fromServiceCode(try XCTUnwrap(result.detectedCode), for: .bingFree),
            TranslationLanguage.simplifiedChinese
        )
    }

    // MARK: - translate() over an injected URLSession

    func testAutoSourceTranslateYieldsDetectedAndFinalWithOneRequestAndNoAuth() async throws {
        BingTranslateHTTPStub.behavior = .respond(status: 200, body: Self.mythosProbeJSON)
        let request = TranslationRequest(text: "Mythos", source: nil, target: .simplifiedChinese)
        let result = try await collect(makeProvider().translate(request))

        XCTAssertEqual(result.detected, TranslationLanguage.named("de"))
        XCTAssertEqual(result.final, "神话")
        try assertSingleTranslateRequest(
            expectedQuery: "from=&to=zh-CN&isEnterpriseClient=false",
            expectedBody: ["Mythos"]
        )
    }

    func testExplicitSourceTranslateSendsFromAndNoAuth() async throws {
        let json = Data(#"""
        [{"translations":[{"text":"你好","to":"zh-Hans"}]}]
        """#.utf8)
        BingTranslateHTTPStub.behavior = .respond(status: 200, body: json)
        let request = TranslationRequest(text: "hello", source: .english, target: .simplifiedChinese)
        let result = try await collect(makeProvider().translate(request))

        XCTAssertNil(result.detected)
        XCTAssertEqual(result.final, "你好")
        try assertSingleTranslateRequest(
            expectedQuery: "from=en&to=zh-CN&isEnterpriseClient=false",
            expectedBody: ["hello"]
        )
    }

    func testTranslateMapsChineseServiceDetectedCode() async throws {
        let json = Data(#"""
        [{"detectedLanguage":{"language":"zh-CN","score":1.0},"translations":[{"text":"hello","to":"en"}]}]
        """#.utf8)
        BingTranslateHTTPStub.behavior = .respond(status: 200, body: json)
        let request = TranslationRequest(text: "你好", source: nil, target: .english)
        let result = try await collect(makeProvider().translate(request))

        XCTAssertEqual(result.detected, .simplifiedChinese)
        XCTAssertEqual(result.final, "hello")
        try assertSingleTranslateRequest(
            expectedQuery: "from=&to=en&isEnterpriseClient=false",
            expectedBody: ["你好"]
        )
    }

    func testMalformedResponseIsDecodeFailed() async {
        BingTranslateHTTPStub.behavior = .respond(status: 200, body: Data(#"{"nope":true}"#.utf8))
        let request = TranslationRequest(text: "Mythos", source: nil, target: .simplifiedChinese)
        let error = await firstError(makeProvider().translate(request))
        XCTAssertEqual(error, .decodeFailed)
        XCTAssertEqual(BingTranslateHTTPStub.recorded.count, 1)
        XCTAssertFalse(BingTranslateHTTPStub.recorded.contains { $0.url.path.hasSuffix("/auth") })
    }

    func testEmptyResponseIsDecodeFailed() async {
        BingTranslateHTTPStub.behavior = .respond(status: 200, body: Data())
        let request = TranslationRequest(text: "Mythos", source: nil, target: .simplifiedChinese)
        let error = await firstError(makeProvider().translate(request))
        XCTAssertEqual(error, .decodeFailed)
        XCTAssertEqual(BingTranslateHTTPStub.recorded.count, 1)
        XCTAssertFalse(BingTranslateHTTPStub.recorded.contains { $0.url.path.hasSuffix("/auth") })
    }

    func testNon2xxStatusIsBadResponse() async {
        BingTranslateHTTPStub.behavior = .respond(status: 404, body: Data())
        let request = TranslationRequest(text: "Mythos", source: nil, target: .simplifiedChinese)
        let error = await firstError(makeProvider().translate(request))
        XCTAssertEqual(error, .badResponse(404))
        XCTAssertEqual(BingTranslateHTTPStub.recorded.count, 1)
        XCTAssertFalse(BingTranslateHTTPStub.recorded.contains { $0.url.path.hasSuffix("/auth") })
    }

    func testCancellationStopsInFlightTranslateAndSkipsAuth() async throws {
        BingTranslateHTTPStub.behavior = .hang
        let session = BingTranslateHTTPStub.session()
        defer { session.invalidateAndCancel() }
        let provider = BingFreeTranslationProvider(id: "bingFree", session: session)
        let request = TranslationRequest(text: "Mythos", source: nil, target: .simplifiedChinese)

        let consumer = Task {
            for try await _ in provider.translate(request) {}
        }
        let started = await BingTranslateHTTPStub.waitUntil { BingTranslateHTTPStub.recorded.count == 1 }
        XCTAssertTrue(started, "expected the translate request to start")
        consumer.cancel()

        do {
            try await consumer.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // Consumer cancelled the stream.
        } catch {
            XCTFail("unexpected \(error)")
        }

        let cancelled = await BingTranslateHTTPStub.waitUntil { BingTranslateHTTPStub.cancelledCount >= 1 }
        XCTAssertTrue(cancelled, "expected URLSession to cancel the in-flight request")
        XCTAssertEqual(BingTranslateHTTPStub.recorded.count, 1)
        let url = try XCTUnwrap(BingTranslateHTTPStub.recorded.first?.url)
        XCTAssertEqual(url.path, "/translate/translatetext")
        XCTAssertFalse(BingTranslateHTTPStub.recorded.contains { $0.url.path.hasSuffix("/auth") })
        XCTAssertNil(BingTranslateHTTPStub.recorded.first?.authorization)
    }

    func testProviderExposesKindAndID() {
        let provider = BingFreeTranslationProvider(id: "bingFree")
        XCTAssertEqual(provider.id, "bingFree")
        XCTAssertEqual(provider.kind, .bingFree)
    }

    // MARK: - helpers

    private func makeProvider() -> BingFreeTranslationProvider {
        BingFreeTranslationProvider(id: "bingFree", session: BingTranslateHTTPStub.session())
    }

    private func collect(_ stream: AsyncThrowingStream<TranslationChunk, Error>) async throws
        -> (detected: TranslationLanguage?, final: String?) {
        var detected: TranslationLanguage?
        var finalText: String?
        for try await chunk in stream {
            switch chunk {
            case .detected(let language): detected = language
            case .final(let text): finalText = text
            case .delta: break
            }
        }
        return (detected, finalText)
    }

    private func firstError(_ stream: AsyncThrowingStream<TranslationChunk, Error>) async -> TranslationProviderError? {
        do {
            for try await _ in stream {}
            return nil
        } catch let error as TranslationProviderError {
            return error
        } catch {
            return nil
        }
    }

    private func assertSingleTranslateRequest(
        expectedQuery: String,
        expectedBody: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let recorded = BingTranslateHTTPStub.recorded
        XCTAssertEqual(recorded.count, 1, "expected a single translate request", file: file, line: line)
        XCTAssertFalse(
            recorded.contains { $0.url.path.hasSuffix("/auth") },
            "auth endpoint must not be called",
            file: file,
            line: line
        )
        let hit = try XCTUnwrap(recorded.first, file: file, line: line)
        XCTAssertEqual(hit.method, "POST", file: file, line: line)
        XCTAssertEqual(hit.url.host, "edge.microsoft.com", file: file, line: line)
        XCTAssertEqual(hit.url.path, "/translate/translatetext", file: file, line: line)
        let components = try XCTUnwrap(
            URLComponents(url: hit.url, resolvingAgainstBaseURL: false),
            file: file,
            line: line
        )
        XCTAssertEqual(components.percentEncodedQuery, expectedQuery, file: file, line: line)
        XCTAssertEqual(hit.contentType, "application/json", file: file, line: line)
        XCTAssertNil(hit.authorization, file: file, line: line)
        let body = try XCTUnwrap(hit.body, file: file, line: line)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String]
        XCTAssertEqual(decoded, expectedBody, file: file, line: line)
    }
}
