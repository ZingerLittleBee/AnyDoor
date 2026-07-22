import XCTest

@testable import AnyDoor

/// Pins the stream-collapse rule backing the Script Plugin `translate`
/// capability: deltas accumulate, a non-empty `.final` is authoritative, and
/// `.detected` is ignored — mirroring the coordinator's accumulation.
@MainActor
final class PluginTranslatorTests: XCTestCase {

    private func stream(_ chunks: [TranslationChunk]) -> AsyncThrowingStream<TranslationChunk, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

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
