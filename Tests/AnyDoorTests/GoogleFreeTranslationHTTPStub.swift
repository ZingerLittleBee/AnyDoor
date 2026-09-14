import Foundation

/// Package-local `URLProtocol` for Google translate stream tests. Isolated from
/// the shared `MockURLProtocol` helper so this package does not edit it.
final class GoogleFreeTranslationHTTPStub: URLProtocol, @unchecked Sendable {
    struct CannedResponse: Sendable {
        var statusCode: Int
        var headerFields: [String: String]
        var body: Data

        static func ok(_ body: Data = GoogleFreeTranslationHTTPStub.successBody) -> CannedResponse {
            CannedResponse(statusCode: 200, headerFields: [:], body: body)
        }

        static func rateLimited(retryAfter: String?, body: Data = Data()) -> CannedResponse {
            var headers: [String: String] = [:]
            if let retryAfter {
                headers["Retry-After"] = retryAfter
            }
            return CannedResponse(statusCode: 429, headerFields: headers, body: body)
        }

        static func status(_ code: Int, body: Data = Data()) -> CannedResponse {
            CannedResponse(statusCode: code, headerFields: [:], body: body)
        }
    }

    static let successBody = Data(#"[[["你好","hello",null,null,10]],null,"en"]"#.utf8)

    private static let lock = NSLock()
    private static var handler: (@Sendable (URLRequest) async -> CannedResponse)?
    private static var requests: [URLRequest] = []

    private var loadTask: Task<Void, Never>?

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GoogleFreeTranslationHTTPStub.self]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    static func reset() {
        lock.lock()
        handler = nil
        requests = []
        lock.unlock()
    }

    static func setHandler(
        _ handler: @escaping @Sendable (URLRequest) async -> CannedResponse
    ) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    static var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        loadTask = Task {
            guard let handler else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let canned = await handler(request)
            guard !Task.isCancelled else { return }
            let url = request.url ?? URL(string: "https://translate.googleapis.com/translate_a/single")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: canned.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: canned.headerFields
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: canned.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        loadTask?.cancel()
    }
}
