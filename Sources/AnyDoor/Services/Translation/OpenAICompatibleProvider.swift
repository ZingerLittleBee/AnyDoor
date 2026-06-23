import Foundation

/// Translates via an OpenAI-compatible `/chat/completions` endpoint with SSE
/// streaming. The configured prompt template (placeholders `{{source}}`
/// `{{target}}` `{{text}}`) becomes a single user message; each `delta.content`
/// chunk is yielded as `.delta`, and the accumulated text is yielded as `.final`.
struct OpenAICompatibleProvider: TranslationProvider {
    let id: String
    var kind: TranslationServiceKind { .openAICompatible }

    private let config: TranslationServiceConfig
    private let apiKey: String
    private let session: URLSession

    init(config: TranslationServiceConfig, apiKey: String, session: URLSession = .shared) {
        self.id = config.id
        self.config = config
        self.apiKey = apiKey
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
                    guard !apiKey.isEmpty else {
                        continuation.finish(throwing: TranslationProviderError.missingAPIKey)
                        return
                    }
                    guard let baseURL = config.baseURL, !baseURL.isEmpty else {
                        continuation.finish(
                            throwing: TranslationProviderError.missingConfiguration("missing base URL")
                        )
                        return
                    }
                    guard let model = config.model, !model.isEmpty else {
                        continuation.finish(
                            throwing: TranslationProviderError.missingConfiguration("missing model")
                        )
                        return
                    }

                    let template = config.promptTemplate ?? TranslationServiceConfig.defaultPromptTemplate
                    let prompt = Self.renderPrompt(
                        template: template,
                        source: request.source,
                        target: request.target,
                        text: request.text
                    )
                    let urlRequest = try Self.buildRequest(
                        baseURL: baseURL,
                        model: model,
                        apiKey: apiKey,
                        prompt: prompt
                    )

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: TranslationProviderError.badResponse(-1))
                        return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // Drain a bounded slice of the error body so the backend's
                        // own message ("Incorrect API key provided", "model not
                        // found", "insufficient quota") reaches the user instead of
                        // a bare status code.
                        let body = try? await Self.collectBody(bytes, limit: 8 * 1024)
                        if let body, let message = Self.parseErrorMessage(body) {
                            continuation.finish(
                                throwing: TranslationProviderError.apiError(status: http.statusCode, message: message)
                            )
                        } else {
                            continuation.finish(throwing: TranslationProviderError.badResponse(http.statusCode))
                        }
                        return
                    }

                    var accumulated = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let delta = Self.parseSSELine(line), !delta.isEmpty {
                            accumulated += delta
                            continuation.yield(.delta(delta))
                        }
                    }
                    // A 2xx response that produced no content (non-SSE body, or a
                    // stream of role/keep-alive-only deltas) would otherwise finish
                    // as a blank success card; surface it as a failure instead.
                    guard !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continuation.finish(throwing: TranslationProviderError.emptyResponse)
                        return
                    }
                    continuation.yield(.final(accumulated))
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

    /// Substitutes the three template placeholders. A nil source renders the literal
    /// "auto" so the model performs detection.
    static func renderPrompt(
        template: String,
        source: TranslationLanguage?,
        target: TranslationLanguage,
        text: String
    ) -> String {
        let sourceName = source?.englishName ?? "auto"
        return template
            .replacingOccurrences(of: "{{source}}", with: sourceName)
            .replacingOccurrences(of: "{{target}}", with: target.englishName)
            .replacingOccurrences(of: "{{text}}", with: text)
    }

    /// Builds the streaming `POST {baseURL}/chat/completions` request. A trailing
    /// slash on `baseURL` is trimmed so the path joins cleanly.
    static func buildRequest(baseURL: String, model: String, apiKey: String, prompt: String) throws -> URLRequest {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBase = trimmedBase.hasSuffix("/") ? String(trimmedBase.dropLast()) : trimmedBase
        guard !normalizedBase.isEmpty, let url = URL(string: normalizedBase + "/chat/completions") else {
            throw TranslationProviderError.network("invalid base URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Reads up to `limit` bytes from a non-2xx response so the backend's JSON
    /// error message can be surfaced. Capped so a large error page can't grow
    /// memory without bound.
    static func collectBody(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }

    /// Pulls a human-readable message out of an error body. Handles OpenAI's
    /// `{"error":{"message":...}}`, the simpler `{"error":"..."}` / `{"message":...}`
    /// shapes, and falls back to a trimmed slice of the raw body. Returns nil only
    /// when the body carries nothing usable.
    static func parseErrorMessage(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = root["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let message = root["error"] as? String, !message.isEmpty { return message }
            if let message = root["message"] as? String, !message.isEmpty { return message }
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(500))
    }

    /// Extracts `choices[0].delta.content` from one SSE line. Returns nil for
    /// non-`data:` lines, the `[DONE]` sentinel, and content-less deltas.
    static func parseSSELine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", !payload.isEmpty else { return nil }
        guard
            let data = payload.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [Any],
            let choice = choices.first as? [String: Any],
            let delta = choice["delta"] as? [String: Any],
            let content = delta["content"] as? String
        else {
            return nil
        }
        return content
    }
}
