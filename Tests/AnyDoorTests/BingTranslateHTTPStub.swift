import Foundation

/// Package-local `URLProtocol` for Bing stream tests. Isolated from the shared
/// `MockURLProtocol` helper so this package does not share that global responder.
final class BingTranslateHTTPStub: URLProtocol {
    struct RecordedRequest: Sendable {
        let url: URL
        let method: String?
        let authorization: String?
        let contentType: String?
        let body: Data?
    }

    enum Behavior: Sendable {
        case respond(status: Int, body: Data)
        case hang
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _behavior: Behavior = .respond(status: 500, body: Data())
    nonisolated(unsafe) private static var _recorded: [RecordedRequest] = []
    nonisolated(unsafe) private static var _cancelledCount = 0

    static var behavior: Behavior {
        get { lock.withLock { _behavior } }
        set { lock.withLock { _behavior = newValue } }
    }

    static var recorded: [RecordedRequest] {
        lock.withLock { _recorded }
    }

    static var cancelledCount: Int {
        lock.withLock { _cancelledCount }
    }

    static func reset() {
        lock.withLock {
            _behavior = .respond(status: 500, body: Data())
            _recorded = []
            _cancelledCount = 0
        }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BingTranslateHTTPStub.self]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    static func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let finishLock = NSLock()
    private var didFinish = false

    override func startLoading() {
        let recorded = RecordedRequest(
            url: request.url ?? URL(string: "https://invalid.invalid")!,
            method: request.httpMethod,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: Self.copyBody(from: request)
        )
        let behavior = Self.lock.withLock { () -> Behavior in
            Self._recorded.append(recorded)
            return Self._behavior
        }

        switch behavior {
        case .respond(let status, let body):
            deliverSuccess(status: status, body: body)
        case .hang:
            break
        }
    }

    override func stopLoading() {
        Self.lock.withLock { Self._cancelledCount += 1 }
        deliverFailure(URLError(.cancelled))
    }

    private func deliverSuccess(status: Int, body: Data) {
        finishLock.lock()
        let proceed = !didFinish
        if proceed { didFinish = true }
        finishLock.unlock()
        guard proceed else { return }
        let url = request.url ?? URL(string: "https://invalid.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func deliverFailure(_ error: Error) {
        finishLock.lock()
        let proceed = !didFinish
        if proceed { didFinish = true }
        finishLock.unlock()
        guard proceed else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }

    private static func copyBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        let bufferSize = 16_384
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var data = Data()
        while true {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
