import XCTest
@testable import AnyDoor

final class OpenAICompatibleProviderTests: XCTestCase {
    func testRenderPromptSubstitutesAllPlaceholders() {
        let template = "Translate from {{source}} to {{target}}:\n{{text}}"
        let rendered = OpenAICompatibleProvider.renderPrompt(
            template: template,
            source: .english,
            target: .simplifiedChinese,
            text: "hello"
        )
        XCTAssertEqual(rendered, "Translate from English to Chinese (Simplified):\nhello")
    }

    func testRenderPromptAutoSourceUsesAutoLabel() {
        let template = "{{source}}->{{target}}: {{text}}"
        let rendered = OpenAICompatibleProvider.renderPrompt(
            template: template,
            source: nil,
            target: .english,
            text: "你好"
        )
        // A nil source renders the literal "auto" so the model auto-detects.
        XCTAssertEqual(rendered, "auto->English: 你好")
    }

    func testBuildRequestHeadersAndBody() throws {
        let request = try OpenAICompatibleProvider.buildRequest(
            baseURL: "https://api.example.com/v1",
            model: "gpt-4o-mini",
            apiKey: "sk-test-123",
            prompt: "translate this"
        )
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(json["stream"] as? Bool, true)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "translate this")
    }

    func testBuildRequestTrimsTrailingSlashOnBaseURL() throws {
        let request = try OpenAICompatibleProvider.buildRequest(
            baseURL: "https://api.example.com/v1/",
            model: "m",
            apiKey: "k",
            prompt: "p"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
    }

    func testBuildRequestRejectsInvalidBaseURL() {
        XCTAssertThrowsError(
            try OpenAICompatibleProvider.buildRequest(baseURL: "", model: "m", apiKey: "k", prompt: "p")
        )
    }

    func testParseSSELineExtractsDeltaContent() {
        let line = #"data: {"choices":[{"delta":{"content":"你好"}}]}"#
        XCTAssertEqual(OpenAICompatibleProvider.parseSSELine(line), "你好")
    }

    func testParseSSELineDoneReturnsNil() {
        XCTAssertNil(OpenAICompatibleProvider.parseSSELine("data: [DONE]"))
    }

    func testParseSSELineNonContentReturnsNil() {
        // Role-only opening delta carries no content.
        let line = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        XCTAssertNil(OpenAICompatibleProvider.parseSSELine(line))
    }

    func testParseSSELineNonDataLineReturnsNil() {
        XCTAssertNil(OpenAICompatibleProvider.parseSSELine(""))
        XCTAssertNil(OpenAICompatibleProvider.parseSSELine(": keep-alive"))
    }

    private func makeConfig(baseURL: String?, model: String?) -> TranslationServiceConfig {
        TranslationServiceConfig(
            id: "llm",
            kind: .openAICompatible,
            displayName: "LLM",
            iconName: "brain",
            enabled: true,
            order: 0,
            baseURL: baseURL,
            model: model,
            promptTemplate: nil
        )
    }

    private func firstError(
        from stream: AsyncThrowingStream<TranslationChunk, Error>
    ) async -> TranslationProviderError? {
        do {
            for try await _ in stream {}
            return nil
        } catch let error as TranslationProviderError {
            return error
        } catch {
            return nil
        }
    }

    func testTranslateMissingBaseURLReportsMissingConfiguration() async {
        let provider = OpenAICompatibleProvider(
            config: makeConfig(baseURL: nil, model: "gpt-4o-mini"),
            apiKey: "sk-test"
        )
        let request = TranslationRequest(text: "hello", source: nil, target: .english)
        let error = await firstError(from: provider.translate(request))
        XCTAssertEqual(error, .missingConfiguration("missing base URL"))
    }

    func testTranslateMissingModelReportsMissingConfiguration() async {
        let provider = OpenAICompatibleProvider(
            config: makeConfig(baseURL: "https://api.example.com/v1", model: nil),
            apiKey: "sk-test"
        )
        let request = TranslationRequest(text: "hello", source: nil, target: .english)
        let error = await firstError(from: provider.translate(request))
        XCTAssertEqual(error, .missingConfiguration("missing model"))
    }

    // MARK: - parseErrorMessage

    func testParseErrorMessageOpenAIShape() {
        let data = Data(#"{"error":{"message":"Incorrect API key provided","code":"invalid_api_key"}}"#.utf8)
        XCTAssertEqual(OpenAICompatibleProvider.parseErrorMessage(data), "Incorrect API key provided")
    }

    func testParseErrorMessageStringErrorShape() {
        let data = Data(#"{"error":"model not found"}"#.utf8)
        XCTAssertEqual(OpenAICompatibleProvider.parseErrorMessage(data), "model not found")
    }

    func testParseErrorMessageFallsBackToRawText() {
        XCTAssertEqual(OpenAICompatibleProvider.parseErrorMessage(Data("Bad Gateway".utf8)), "Bad Gateway")
    }

    func testParseErrorMessageEmptyReturnsNil() {
        XCTAssertNil(OpenAICompatibleProvider.parseErrorMessage(Data()))
    }

    // MARK: - translate() over a mocked URLSession

    override func tearDown() {
        MockURLProtocol.responder = nil
        super.tearDown()
    }

    private func mockProvider() -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            config: makeConfig(baseURL: "https://api.example.com/v1", model: "gpt-4o-mini"),
            apiKey: "sk-test",
            session: MockURLProtocol.session()
        )
    }

    private func collectChunks(
        from stream: AsyncThrowingStream<TranslationChunk, Error>
    ) async throws -> (deltas: [String], final: String?) {
        var deltas: [String] = []
        var finalText: String?
        for try await chunk in stream {
            switch chunk {
            case .delta(let piece): deltas.append(piece)
            case .final(let full): finalText = full
            case .detected: break
            }
        }
        return (deltas, finalText)
    }

    func testTranslateStreamAccumulatesContentDeltas() async throws {
        MockURLProtocol.responder = { request in
            let body = """
            data: {"choices":[{"delta":{"role":"assistant"}}]}

            data: {"choices":[{"delta":{"content":"你"}}]}

            data: {"choices":[{"delta":{"content":"好"}}]}

            data: [DONE]

            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(body.utf8))
        }
        let request = TranslationRequest(text: "hello", source: .english, target: .simplifiedChinese)
        let result = try await collectChunks(from: mockProvider().translate(request))
        XCTAssertEqual(result.deltas, ["你", "好"])
        XCTAssertEqual(result.final, "你好")
    }

    func testTranslateSurfacesAPIErrorMessageOnNon2xx() async {
        MockURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"error":{"message":"Incorrect API key provided"}}"#.utf8))
        }
        let request = TranslationRequest(text: "hello", source: nil, target: .english)
        let error = await firstError(from: mockProvider().translate(request))
        XCTAssertEqual(error, .apiError(status: 401, message: "Incorrect API key provided"))
    }

    func testTranslateNon2xxWithoutBodyReportsBadResponse() async {
        MockURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data())
        }
        let request = TranslationRequest(text: "hello", source: nil, target: .english)
        let error = await firstError(from: mockProvider().translate(request))
        XCTAssertEqual(error, .badResponse(500))
    }

    func testTranslateContentlessStreamReportsEmptyResponse() async {
        MockURLProtocol.responder = { request in
            let body = """
            data: {"choices":[{"delta":{"role":"assistant"}}]}

            data: [DONE]

            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(body.utf8))
        }
        let request = TranslationRequest(text: "hello", source: nil, target: .english)
        let error = await firstError(from: mockProvider().translate(request))
        XCTAssertEqual(error, .emptyResponse)
    }

    func testBuildRequestMergesExtraBodyTopLevelKeys() throws {
        let request = try OpenAICompatibleProvider.buildRequest(
            baseURL: "https://api.example.com", model: "m", apiKey: "k", prompt: "p",
            extraBodyJSON: #"{"thinking":{"type":"disabled"},"temperature":0.2}"#)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual((json["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertEqual(json["temperature"] as? Double, 0.2)
        // Base keys remain intact.
        XCTAssertEqual(json["model"] as? String, "m")
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testBuildRequestExtraBodyDoesNotOverrideBaseKeys() throws {
        let request = try OpenAICompatibleProvider.buildRequest(
            baseURL: "https://api.example.com", model: "real", apiKey: "k", prompt: "p",
            extraBodyJSON: #"{"model":"evil","stream":false}"#)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "real")
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testBuildRequestIgnoresInvalidExtraBody() throws {
        let request = try OpenAICompatibleProvider.buildRequest(
            baseURL: "https://api.example.com", model: "m", apiKey: "k", prompt: "p",
            extraBodyJSON: "[not an object]")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        // Degrades to the plain request: only the three base keys.
        XCTAssertEqual(Set(json.keys), ["model", "stream", "messages"])
    }
}
