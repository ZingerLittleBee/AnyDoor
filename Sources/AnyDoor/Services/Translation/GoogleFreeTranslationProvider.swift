import Foundation

/// Key-free Google translate endpoint (`translate.googleapis.com/translate_a/single`,
/// the `client=gtx` web fallback). Yields a single `.final` chunk plus a `.detected`
/// chunk when the response reports a source language. The wire format is a nested,
/// loosely-typed JSON array, decoded with `JSONSerialization` rather than `Codable`.
struct GoogleFreeTranslationProvider: TranslationProvider {
    let id: String
    var kind: TranslationServiceKind { .googleFree }

    private let session: URLSession

    init(id: String, session: URLSession = .shared) {
        self.id = id
        self.session = session
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        continuation.finish(throwing: TranslationProviderError.emptyInput)
                        return
                    }
                    let source = request.source?.serviceCode(for: .googleFree) ?? "auto"
                    let target = request.target.serviceCode(for: .googleFree)
                    let url = Self.buildURL(text: request.text, source: source, target: target)

                    let (data, response) = try await session.data(from: url)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: TranslationProviderError.badResponse(-1))
                        return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        continuation.finish(throwing: TranslationProviderError.badResponse(http.statusCode))
                        return
                    }

                    let decoded = try Self.decode(data)
                    if let code = decoded.detectedCode, let language = TranslationLanguage.named(code) {
                        continuation.yield(.detected(language))
                    }
                    continuation.yield(.final(decoded.text))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as TranslationProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: TranslationProviderError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Builds the `translate_a/single` GET URL. `dt=t` requests translated text;
    /// `client=gtx` selects the unauthenticated web fallback.
    static func buildURL(text: String, source: String, target: String) -> URL {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        return components.url!
    }

    /// Parses the nested array: `outer[0]` is the list of `[translated, original, …]`
    /// segments (joined in order); `outer[2]` is the detected source language code.
    static func decode(_ data: Data) throws -> (text: String, detectedCode: String?) {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let outer = root as? [Any], let segments = outer.first as? [Any] else {
            throw TranslationProviderError.decodeFailed
        }
        var text = ""
        for segment in segments {
            if let pair = segment as? [Any], let translated = pair.first as? String {
                text += translated
            }
        }
        let detectedCode: String? = (outer.count > 2 ? outer[2] as? String : nil)
        return (text, detectedCode)
    }
}
