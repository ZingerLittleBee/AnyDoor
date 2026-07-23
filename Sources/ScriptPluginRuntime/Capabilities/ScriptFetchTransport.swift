import Foundation

/// A network request issued by a plugin's `anydoor.fetch`.
public struct ScriptFetchRequest: Sendable, Equatable {
    public let url: String
    public let method: String
    public let headers: [String: String]
    public let body: String?

    public init(url: String, method: String = "GET", headers: [String: String] = [:], body: String? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// The response handed back to a plugin's `anydoor.fetch`.
public struct ScriptFetchResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: String

    public init(status: Int, headers: [String: String] = [:], body: String) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// The single true external boundary of the runtime (the repo's no-mocking
/// philosophy: everything else runs for real). Production uses
/// ``URLSessionFetchTransport``; tests inject a stub or point a real transport
/// at a local server, and observe fetch behavior at this seam alone.
public protocol ScriptFetchTransport: Sendable {
    func fetch(_ request: ScriptFetchRequest) async throws -> ScriptFetchResponse
}

/// The production transport, backed by `URLSession`.
///
/// Deliberately cache-free: palette rows rebuild on every open, so a plugin's
/// `fetch` must observe the live network — some APIs (V2EX sends
/// `Cache-Control: max-age=432000`, five days) would otherwise pin a plugin's
/// rows to the first response served from the local `URLCache`. The ephemeral
/// session also keeps plugin responses (which may carry personal tokens) out
/// of the shared on-disk cache and cookie store.
public struct URLSessionFetchTransport: ScriptFetchTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func fetch(_ request: ScriptFetchRequest) async throws -> ScriptFetchResponse {
        guard let url = URL(string: request.url) else {
            throw ScriptPluginError.capabilityFailed("fetch: invalid URL \(request.url)")
        }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        urlRequest.httpMethod = request.method
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = request.body?.data(using: .utf8)

        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var headers: [String: String] = [:]
        if let http = response as? HTTPURLResponse {
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key] = value
                }
            }
        }
        return ScriptFetchResponse(
            status: status,
            headers: headers,
            body: String(data: data, encoding: .utf8) ?? ""
        )
    }
}
