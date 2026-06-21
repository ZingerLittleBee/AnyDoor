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
}
