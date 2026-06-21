import XCTest
@testable import AnyDoor

final class BingFreeTranslationProviderTests: XCTestCase {
    func testBuildTranslateRequestURLAndQuery() throws {
        let request = BingFreeTranslationProvider.buildTranslateRequest(
            token: "JWT.TOKEN.VALUE",
            text: "hello",
            source: nil,
            target: "zh-Hans"
        )
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "api-edge.cognitive.microsofttranslator.com")
        XCTAssertEqual(components.path, "/translate")
        let items = try XCTUnwrap(components.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("api-version"), "3.0")
        XCTAssertEqual(value("to"), "zh-Hans")
        // No explicit source -> auto-detect, no `from` query item.
        XCTAssertNil(value("from"))
    }

    func testBuildTranslateRequestHeadersAndBody() throws {
        let request = BingFreeTranslationProvider.buildTranslateRequest(
            token: "JWT.TOKEN.VALUE",
            text: "hello",
            source: "en",
            target: "zh-Hans"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer JWT.TOKEN.VALUE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let url = try XCTUnwrap(request.url)
        let from = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "from" }?.value
        XCTAssertEqual(from, "en")

        // Body must be a JSON array of `{ "Text": "..." }` objects.
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [[String: String]]
        XCTAssertEqual(decoded?.first?["Text"], "hello")
    }

    func testDecodeReadsTextAndDetectedLanguage() throws {
        // Captured Microsoft Translator v3 shape.
        let json = #"""
        [{"detectedLanguage":{"language":"en","score":1.0},"translations":[{"text":"你好","to":"zh-Hans"}]}]
        """#
        let result = try BingFreeTranslationProvider.decode(Data(json.utf8))
        XCTAssertEqual(result.text, "你好")
        XCTAssertEqual(result.detectedCode, "en")
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
        XCTAssertThrowsError(try BingFreeTranslationProvider.decode(Data("[]".utf8)))
    }
}
