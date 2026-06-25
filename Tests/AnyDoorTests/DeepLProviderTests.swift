import XCTest
@testable import AnyDoor

final class DeepLProviderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.responder = nil
        super.tearDown()
    }

    private func config(baseURL: String?) -> TranslationServiceConfig {
        TranslationServiceConfig(
            id: "deepl", kind: .deepl, displayName: "DeepL", iconName: "character.book.closed",
            enabled: true, order: 0, baseURL: baseURL, model: nil, promptTemplate: nil)
    }

    // MARK: - host + request construction

    func testOfficialHostSelectedByFXSuffix() {
        XCTAssertEqual(DeepLProvider.officialHost(forKey: "abc:fx"), "https://api-free.deepl.com")
        XCTAssertEqual(DeepLProvider.officialHost(forKey: "abc"), "https://api.deepl.com")
    }

    func testBuildOfficialRequest() throws {
        let req = try DeepLProvider.buildOfficialRequest(
            apiKey: "key:fx", text: "hello", source: "EN", target: "ZH-HANS")
        XCTAssertEqual(req.url?.absoluteString, "https://api-free.deepl.com/v2/translate")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "DeepL-Auth-Key key:fx")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(json["text"] as? [String], ["hello"])
        XCTAssertEqual(json["target_lang"] as? String, "ZH-HANS")
        XCTAssertEqual(json["source_lang"] as? String, "EN")
    }

    func testBuildOfficialRequestOmitsSourceWhenNil() throws {
        let req = try DeepLProvider.buildOfficialRequest(
            apiKey: "key", text: "hi", source: nil, target: "EN-US")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertNil(json["source_lang"])
    }

    func testNormalizeDeepLXBase() {
        XCTAssertEqual(DeepLProvider.normalizeDeepLXBase("http://x:1188/"), "http://x:1188")
        XCTAssertEqual(DeepLProvider.normalizeDeepLXBase("http://x:1188/translate"), "http://x:1188")
        XCTAssertEqual(DeepLProvider.normalizeDeepLXBase("  http://x:1188/translate/  "), "http://x:1188")
    }

    func testBuildDeepLXRequestStringBodyAndBearer() throws {
        let req = try DeepLProvider.buildDeepLXRequest(
            baseURL: "http://x:1188/translate", token: "tok", text: "hello", source: "auto", target: "ZH")
        XCTAssertEqual(req.url?.absoluteString, "http://x:1188/translate")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "hello")
        XCTAssertEqual(json["source_lang"] as? String, "auto")
        XCTAssertEqual(json["target_lang"] as? String, "ZH")
    }

    func testBuildDeepLXRequestNoAuthWhenTokenEmpty() throws {
        let req = try DeepLProvider.buildDeepLXRequest(
            baseURL: "http://x:1188", token: "", text: "hi", source: "auto", target: "EN")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - response parsing

    func testParseOfficial() throws {
        let data = Data(#"{"translations":[{"detected_source_language":"EN","text":"你好"}]}"#.utf8)
        let r = try DeepLProvider.parseOfficial(data)
        XCTAssertEqual(r.text, "你好")
        XCTAssertEqual(r.detectedCode, "EN")
    }

    func testParseDeepLX() throws {
        let data = Data(#"{"code":200,"data":"你好","source_lang":"EN","target_lang":"ZH"}"#.utf8)
        let r = try DeepLProvider.parseDeepLX(data)
        XCTAssertEqual(r.code, 200)
        XCTAssertEqual(r.text, "你好")
        XCTAssertEqual(r.detectedCode, "EN")
    }

    // MARK: - translate() over a mocked session

    private func mock(_ config: TranslationServiceConfig, key: String) -> DeepLProvider {
        DeepLProvider(config: config, apiKey: key, session: MockURLProtocol.session())
    }

    private func collect(_ stream: AsyncThrowingStream<TranslationChunk, Error>) async throws
        -> (detected: TranslationLanguage?, final: String?) {
        var detected: TranslationLanguage?
        var finalText: String?
        for try await chunk in stream {
            switch chunk {
            case .detected(let l): detected = l
            case .final(let s): finalText = s
            case .delta: break
            }
        }
        return (detected, finalText)
    }

    private func firstError(_ stream: AsyncThrowingStream<TranslationChunk, Error>) async -> TranslationProviderError? {
        do { for try await _ in stream {}; return nil }
        catch let e as TranslationProviderError { return e }
        catch { return nil }
    }

    func testOfficialTranslateYieldsDetectedAndFinal() async throws {
        MockURLProtocol.responder = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"translations":[{"detected_source_language":"EN","text":"你好"}]}"#.utf8))
        }
        let request = TranslationRequest(text: "hello", source: .english, target: .simplifiedChinese)
        let r = try await collect(mock(config(baseURL: nil), key: "key:fx").translate(request))
        XCTAssertEqual(r.detected, .english)
        XCTAssertEqual(r.final, "你好")
    }

    func testOfficialMissingKeyReportsMissingAPIKey() async {
        let request = TranslationRequest(text: "hello", source: nil, target: .simplifiedChinese)
        let error = await firstError(mock(config(baseURL: nil), key: "").translate(request))
        XCTAssertEqual(error, .missingAPIKey)
    }

    func testOfficial403SurfacesMessage() async {
        MockURLProtocol.responder = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"message":"Authorization failure"}"#.utf8))
        }
        let request = TranslationRequest(text: "hello", source: nil, target: .simplifiedChinese)
        let error = await firstError(mock(config(baseURL: nil), key: "key").translate(request))
        XCTAssertEqual(error, .apiError(status: 403, message: "Authorization failure"))
    }

    func testDeepLXTranslateReadsData() async throws {
        MockURLProtocol.responder = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"code":200,"data":"你好","source_lang":"EN","target_lang":"ZH"}"#.utf8))
        }
        let request = TranslationRequest(text: "hello", source: nil, target: .simplifiedChinese)
        let r = try await collect(mock(config(baseURL: "http://x:1188"), key: "").translate(request))
        XCTAssertEqual(r.detected, .english)
        XCTAssertEqual(r.final, "你好")
    }

    func testDeepLXNon200JSONCodeIsError() async {
        MockURLProtocol.responder = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"code":429,"data":"","message":"Too many requests"}"#.utf8))
        }
        let request = TranslationRequest(text: "hello", source: nil, target: .simplifiedChinese)
        let error = await firstError(mock(config(baseURL: "http://x:1188"), key: "").translate(request))
        XCTAssertEqual(error, .apiError(status: 429, message: "Too many requests"))
    }

    func testEmptyInputReportsEmptyInput() async {
        let request = TranslationRequest(text: "   ", source: nil, target: .simplifiedChinese)
        let error = await firstError(mock(config(baseURL: nil), key: "key").translate(request))
        XCTAssertEqual(error, .emptyInput)
    }
}
