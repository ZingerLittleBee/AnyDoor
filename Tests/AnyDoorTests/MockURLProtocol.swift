import Foundation

/// Test `URLProtocol` that replays a canned HTTP response + body for any request,
/// so provider network paths (status handling, SSE accumulation, error-body
/// parsing) can be exercised without a live endpoint. Install via
/// `MockURLProtocol.session()`; set `responder` before each request.
final class MockURLProtocol: URLProtocol {
    /// Produces the `(response, body)` for a request. Replaced per test; the
    /// access is single-threaded in practice (one request at a time per test).
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    /// A `URLSession` wired to this protocol. Ephemeral so nothing is cached.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
