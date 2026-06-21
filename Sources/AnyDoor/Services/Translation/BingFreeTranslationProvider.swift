import Foundation

/// Key-free Microsoft/Bing translate path. First fetches a short-lived JWT from
/// `edge.microsoft.com/translate/auth`, then POSTs to the edge Translator v3
/// endpoint. Yields a `.detected` chunk (when reported) plus one `.final` chunk.
struct BingFreeTranslationProvider: TranslationProvider {
    let id: String
    var kind: TranslationServiceKind { .bingFree }

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
                    let token = try await Self.fetchAuthToken(session: session)
                    let source = request.source?.serviceCode(for: .bingFree)
                    let target = request.target.serviceCode(for: .bingFree)
                    let urlRequest = Self.buildTranslateRequest(
                        token: token,
                        text: request.text,
                        source: source,
                        target: target
                    )

                    let (data, response) = try await session.data(for: urlRequest)
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

    /// GETs a bearer JWT used to authorize the translate call. The endpoint returns
    /// the raw token string as its body.
    static func fetchAuthToken(session: URLSession) async throws -> String {
        let url = URL(string: "https://edge.microsoft.com/translate/auth")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranslationProviderError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw TranslationProviderError.decodeFailed }
        return token
    }

    /// Builds the v3 `translate` POST. `source == nil` requests auto-detection by
    /// omitting the `from` query item. The body is a JSON array of `{ "Text": … }`.
    static func buildTranslateRequest(token: String, text: String, source: String?, target: String) -> URLRequest {
        var components = URLComponents(string: "https://api-edge.cognitive.microsofttranslator.com/translate")!
        var queryItems = [
            URLQueryItem(name: "api-version", value: "3.0"),
            URLQueryItem(name: "to", value: target),
        ]
        if let source { queryItems.append(URLQueryItem(name: "from", value: source)) }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = [["Text": text]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Parses the v3 response array: `[0].translations[0].text` is the result;
    /// `[0].detectedLanguage.language` (optional) is the detected source code.
    static func decode(_ data: Data) throws -> (text: String, detectedCode: String?) {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let array = root as? [Any], let first = array.first as? [String: Any] else {
            throw TranslationProviderError.decodeFailed
        }
        guard
            let translations = first["translations"] as? [Any],
            let translation = translations.first as? [String: Any],
            let text = translation["text"] as? String
        else {
            throw TranslationProviderError.decodeFailed
        }
        let detectedCode = (first["detectedLanguage"] as? [String: Any])?["language"] as? String
        return (text, detectedCode)
    }
}
