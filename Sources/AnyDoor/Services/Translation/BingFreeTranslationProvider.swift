import Foundation

/// Key-free Microsoft/Bing translate path. POSTs to the undocumented Edge
/// `translatetext` endpoint without an auth token. The route is unofficial and
/// may change without notice; failures stay isolated to this adapter.
/// Yields a `.detected` chunk (when reported) plus one `.final` chunk.
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
                    let source = request.source?.serviceCode(for: .bingFree)
                    let target = request.target.serviceCode(for: .bingFree)
                    let urlRequest = Self.buildTranslateRequest(
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
                    if let code = decoded.detectedCode,
                       let language = TranslationLanguage.fromServiceCode(code, for: .bingFree) {
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

    /// Builds the Edge `translatetext` POST. Auto-detect sends an empty `from`
    /// query item (`from=&to=…&isEnterpriseClient=false`). The body is a JSON
    /// array of strings, not the v3 `{ "Text": … }` objects.
    static func buildTranslateRequest(text: String, source: String?, target: String) -> URLRequest {
        var components = URLComponents(string: "https://edge.microsoft.com/translate/translatetext")!
        let from = percentEncodeQueryValue(source ?? "")
        let to = percentEncodeQueryValue(target)
        components.percentEncodedQuery = "from=\(from)&to=\(to)&isEnterpriseClient=false"

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [text])
        return request
    }

    /// Parses the v3 response array: `[0].translations[0].text` is the result;
    /// `[0].detectedLanguage.language` (optional) is the detected source code.
    static func decode(_ data: Data) throws -> (text: String, detectedCode: String?) {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TranslationProviderError.decodeFailed
        }
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

    private static func percentEncodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
