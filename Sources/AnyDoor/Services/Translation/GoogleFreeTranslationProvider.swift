import Foundation

/// Key-free Google translate endpoint (`translate.googleapis.com/translate_a/single`,
/// the `client=gtx` web fallback). Yields a single `.final` chunk plus a `.detected`
/// chunk when the response reports a source language. HTTP 429 becomes a typed
/// rate-limit error and a fail-fast cooldown on the injected limiter (production
/// shares ``GoogleFreeRateLimiter/shared`` across provider rebuilds). The wire
/// format is a nested, loosely-typed JSON array, decoded with `JSONSerialization`
/// rather than `Codable`.
struct GoogleFreeTranslationProvider: TranslationProvider {
    let id: String
    var kind: TranslationServiceKind { .googleFree }

    private let session: URLSession
    private let limiter: GoogleFreeRateLimiter

    init(
        id: String,
        session: URLSession = .shared,
        limiter: GoogleFreeRateLimiter = .shared
    ) {
        self.id = id
        self.session = session
        self.limiter = limiter
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

                    let ticket: GoogleFreeRateLimitTicket
                    switch await limiter.admit() {
                    case .throttled(let until):
                        continuation.finish(
                            throwing: TranslationProviderError.rateLimited(retryAfter: until)
                        )
                        return
                    case .allowed(let admitted):
                        ticket = admitted
                    }

                    let source = request.source?.serviceCode(for: .googleFree) ?? "auto"
                    let target = request.target.serviceCode(for: .googleFree)
                    let url = Self.buildURL(text: request.text, source: source, target: target)

                    let (data, response) = try await session.data(from: url)
                    guard let http = response as? HTTPURLResponse else {
                        try Task.checkCancellation()
                        continuation.finish(throwing: TranslationProviderError.badResponse(-1))
                        return
                    }
                    if http.statusCode == 429 {
                        // Record before honoring cancellation so a cancelled 429
                        // still fail-fasts the next Enter instead of retrying.
                        let until = await limiter.noteRateLimited(
                            retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
                        )
                        try Task.checkCancellation()
                        continuation.finish(
                            throwing: TranslationProviderError.rateLimited(retryAfter: until)
                        )
                        return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        try Task.checkCancellation()
                        continuation.finish(throwing: TranslationProviderError.badResponse(http.statusCode))
                        return
                    }

                    await limiter.noteSuccess(ticket: ticket)
                    try Task.checkCancellation()

                    let decoded = try Self.decode(data)
                    if let code = decoded.detectedCode,
                       let language = TranslationLanguage.fromServiceCode(code, for: .googleFree) {
                        continuation.yield(.detected(language))
                    }
                    continuation.yield(.final(decoded.text))
                    continuation.finish()
                } catch {
                    if Self.isCancellation(error) {
                        continuation.finish(throwing: CancellationError())
                    } else if let error = error as? TranslationProviderError {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish(throwing: TranslationProviderError.network(error.localizedDescription))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        return false
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
