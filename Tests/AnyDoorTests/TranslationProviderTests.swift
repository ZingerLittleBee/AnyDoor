import XCTest
@testable import AnyDoor

/// A minimal provider used only to prove the `TranslationProvider` stream
/// contract: it either yields a single `.final` chunk or throws.
private struct FakeProvider: TranslationProvider {
    let id: String
    let kind: TranslationServiceKind
    let finalText: String?
    let failure: TranslationProviderError?

    init(
        id: String = "fake",
        kind: TranslationServiceKind = .googleFree,
        finalText: String? = nil,
        failure: TranslationProviderError? = nil
    ) {
        self.id = id
        self.kind = kind
        self.finalText = finalText
        self.failure = failure
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationChunk, Error> {
        AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            if let finalText {
                continuation.yield(.final(finalText))
            }
            continuation.finish()
        }
    }
}

final class TranslationProviderTests: XCTestCase {

    private func makeRequest(_ text: String) -> TranslationRequest {
        TranslationRequest(text: text, source: nil, target: .english)
    }

    func testProviderYieldsFinalChunk() async throws {
        let provider = FakeProvider(finalText: "Hello")
        var chunks: [TranslationChunk] = []
        for try await chunk in provider.translate(makeRequest("你好")) {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks, [.final("Hello")])
    }

    func testProviderPropagatesError() async {
        let provider = FakeProvider(failure: .emptyInput)
        do {
            for try await _ in provider.translate(makeRequest("")) {}
            XCTFail("expected the stream to throw")
        } catch let error as TranslationProviderError {
            XCTAssertEqual(error, .emptyInput)
        } catch {
            XCTFail("expected TranslationProviderError, got: \(error)")
        }
    }

    func testProviderExposesKindAndID() {
        let provider = FakeProvider(id: "abc", kind: .bingFree, finalText: "x")
        XCTAssertEqual(provider.id, "abc")
        XCTAssertEqual(provider.kind, .bingFree)
    }

    func testErrorEquatableCases() {
        XCTAssertEqual(TranslationProviderError.badResponse(503), .badResponse(503))
        XCTAssertNotEqual(TranslationProviderError.badResponse(503), .badResponse(500))
        XCTAssertEqual(TranslationProviderError.network("offline"), .network("offline"))
        XCTAssertNotEqual(TranslationProviderError.missingAPIKey, .decodeFailed)
    }
}
