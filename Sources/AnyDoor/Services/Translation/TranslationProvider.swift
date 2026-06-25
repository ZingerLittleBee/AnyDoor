import Foundation

/// A translation backend. Every provider exposes a single unified streaming
/// API: LLM providers emit many `.delta` chunks then a `.success`-equivalent
/// `.final`, while one-shot providers (Google/Bing/etc.) yield a single
/// `.final` chunk. `detected` source-language information arrives as a
/// `.detected` chunk when the backend reports it.
protocol TranslationProvider: Sendable {
    /// Stable identifier matching the owning `TranslationServiceConfig.id`.
    var id: String { get }
    /// The backend family this provider implements.
    var kind: TranslationServiceKind { get }
    /// Translates `request`, streaming chunks until completion. The stream
    /// finishes normally on success or finishes throwing on failure.
    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationChunk, Error>
}

/// Errors a `TranslationProvider` can fail with. Equatable so call sites and
/// tests can assert on specific cases.
enum TranslationProviderError: Error, Sendable, Equatable {
    /// The request carried no translatable text.
    case emptyInput
    /// The backend returned a non-success HTTP status code with no decodable
    /// error body.
    case badResponse(Int)
    /// The backend returned a non-success HTTP status code and a decodable error
    /// message (e.g. OpenAI's `{"error":{"message":...}}`). The message is the
    /// backend's own text and is surfaced verbatim as the most actionable hint.
    case apiError(status: Int, message: String)
    /// A required API key was not configured (OpenAI-compatible only).
    case missingAPIKey
    /// A required connection field (base URL or model) was not configured
    /// (OpenAI-compatible only). The associated value is a human-readable note.
    case missingConfiguration(String)
    /// The response body could not be decoded into the expected shape.
    case decodeFailed
    /// The backend reported success but produced no translated text (e.g. a 2xx
    /// stream that yielded no content deltas). Surfaced as a failure instead of a
    /// blank "success" card.
    case emptyResponse
    /// A transport-level failure; the associated value is a human-readable note.
    case network(String)
}

extension AsyncThrowingStream where Element == TranslationChunk, Failure == Error {
    /// Builds a stream that emits a single `.final` chunk and finishes. Used by
    /// one-shot (non-streaming) providers so they share the streaming contract.
    /// When `detected` is non-nil a `.detected` chunk precedes the `.final`.
    static func single(
        _ text: String,
        detected: TranslationLanguage? = nil
    ) -> AsyncThrowingStream<TranslationChunk, Error> {
        AsyncThrowingStream { continuation in
            if let detected {
                continuation.yield(.detected(detected))
            }
            continuation.yield(.final(text))
            continuation.finish()
        }
    }

    /// Builds a stream that immediately finishes by throwing `error`. Used by
    /// providers that fail before producing any output.
    static func failing(_ error: Error) -> AsyncThrowingStream<TranslationChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }
}
