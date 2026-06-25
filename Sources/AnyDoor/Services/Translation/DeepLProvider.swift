import Foundation

/// DeepL backend. One-shot JSON (no streaming): performs a single POST then
/// yields a `.detected` chunk (mapped source) and a single `.final` chunk, or
/// finishes throwing. `config.baseURL` selects the mode — empty/nil uses the
/// official DeepL API (host chosen by the key's `:fx` suffix); a non-empty value
/// targets a user-hosted DeepLX proxy. The secret in `apiKey` is the DeepL
/// auth key (official, required) or the optional DeepLX access token.
struct DeepLProvider: TranslationProvider {
    let id: String
    var kind: TranslationServiceKind { .deepl }

    private let config: TranslationServiceConfig
    private let apiKey: String
    private let session: URLSession

    init(config: TranslationServiceConfig, apiKey: String, session: URLSession = .shared) {
        self.id = config.id
        self.config = config
        self.apiKey = apiKey
        self.session = session
    }

    private var deeplxBase: String? {
        guard let base = config.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !base.isEmpty else { return nil }
        return base
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

                    let isDeepLX = deeplxBase != nil
                    let urlRequest: URLRequest
                    if let base = deeplxBase {
                        urlRequest = try Self.buildDeepLXRequest(
                            baseURL: base,
                            token: apiKey,
                            text: request.text,
                            source: DeepLLanguage.sourceCode(request.source, deeplx: true) ?? "auto",
                            target: DeepLLanguage.targetCode(request.target, deeplx: true))
                    } else {
                        guard !apiKey.isEmpty else {
                            continuation.finish(throwing: TranslationProviderError.missingAPIKey)
                            return
                        }
                        urlRequest = try Self.buildOfficialRequest(
                            apiKey: apiKey,
                            text: request.text,
                            source: DeepLLanguage.sourceCode(request.source, deeplx: false),
                            target: DeepLLanguage.targetCode(request.target, deeplx: false))
                    }

                    let (data, response) = try await session.data(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: TranslationProviderError.badResponse(-1))
                        return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        if let message = Self.parseErrorMessage(data) {
                            continuation.finish(throwing: TranslationProviderError.apiError(status: http.statusCode, message: message))
                        } else {
                            continuation.finish(throwing: TranslationProviderError.badResponse(http.statusCode))
                        }
                        return
                    }

                    let parsed: (text: String, detectedCode: String?)
                    if isDeepLX {
                        let r = try Self.parseDeepLX(data)
                        guard r.code == 200 else {
                            if let message = Self.parseErrorMessage(data) {
                                continuation.finish(throwing: TranslationProviderError.apiError(status: r.code, message: message))
                            } else {
                                continuation.finish(throwing: TranslationProviderError.badResponse(r.code))
                            }
                            return
                        }
                        parsed = (r.text, r.detectedCode)
                    } else {
                        parsed = try Self.parseOfficial(data)
                    }

                    if Task.isCancelled { return }
                    guard !parsed.text.isEmpty else {
                        continuation.finish(throwing: TranslationProviderError.emptyResponse)
                        return
                    }
                    if let code = parsed.detectedCode, let lang = DeepLLanguage.language(fromDetected: code) {
                        continuation.yield(.detected(lang))
                    }
                    continuation.yield(.final(parsed.text))
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

    // MARK: - Official

    /// A DeepL API Free key ends in `:fx` and must hit the Free host; everything
    /// else is a Pro key on the Pro host.
    static func officialHost(forKey key: String) -> String {
        key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
    }

    static func buildOfficialRequest(apiKey: String, text: String, source: String?, target: String) throws -> URLRequest {
        guard let url = URL(string: officialHost(forKey: apiKey) + "/v2/translate") else {
            throw TranslationProviderError.network("invalid DeepL endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": [text], "target_lang": target]
        if let source { body["source_lang"] = source }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseOfficial(_ data: Data) throws -> (text: String, detectedCode: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = root["translations"] as? [[String: Any]],
              let first = translations.first,
              let text = first["text"] as? String else {
            throw TranslationProviderError.decodeFailed
        }
        return (text, first["detected_source_language"] as? String)
    }

    // MARK: - DeepLX

    /// Trims whitespace and a trailing `/`, and drops a trailing `/translate` so a
    /// user who pasted the full endpoint isn't double-suffixed.
    static func normalizeDeepLXBase(_ baseURL: String) -> String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/translate") { s.removeLast("/translate".count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func buildDeepLXRequest(baseURL: String, token: String, text: String, source: String, target: String) throws -> URLRequest {
        guard let url = URL(string: normalizeDeepLXBase(baseURL) + "/translate") else {
            throw TranslationProviderError.network("invalid DeepLX base URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["text": text, "source_lang": source, "target_lang": target]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseDeepLX(_ data: Data) throws -> (text: String, code: Int, detectedCode: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root["code"] as? Int else {
            throw TranslationProviderError.decodeFailed
        }
        return (root["data"] as? String ?? "", code, root["source_lang"] as? String)
    }

    // MARK: - Errors

    /// DeepL official and DeepLX both surface a human-readable `message` field on
    /// error bodies; pull it so the user sees the backend's own note.
    static func parseErrorMessage(_ data: Data) -> String? {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? String, !message.isEmpty else { return nil }
        return message
    }
}
