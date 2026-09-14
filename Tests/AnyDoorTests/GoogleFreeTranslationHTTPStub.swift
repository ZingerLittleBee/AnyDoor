import Foundation

/// Package-local `URLProtocol` for Google translate stream tests. Isolated from
/// the shared `MockURLProtocol` helper so this package does not edit it.
/// Do not redeclare `Sendable`: `URLProtocol` already inherits an unavailable
/// conformance from the SDK.
final class GoogleFreeTranslationHTTPStub: URLProtocol {
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

    typealias Handler = @Sendable (URLRequest) async -> CannedResponse

    static let successBody = Data(#"[[["你好","hello",null,null,10]],null,"en"]"#.utf8)

    /// All mutable stub state lives in this lock box. A `static let` of a
    /// lock-serialized class is concurrency-safe; the `@unchecked Sendable`
    /// is sound because every field is read and written under `lock`.
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: Handler?
        private var requests: [URLRequest] = []
        private var loadTasks: [UUID: Task<Void, Never>] = [:]
        private var cancelledIDs: Set<UUID> = []

        func reset() -> [Task<Void, Never>] {
            lock.lock()
            handler = nil
            requests = []
            let tasks = Array(loadTasks.values)
            loadTasks.removeAll()
            cancelledIDs.removeAll()
            lock.unlock()
            return tasks
        }

        func setHandler(_ handler: @escaping Handler) {
            lock.lock()
            self.handler = handler
            lock.unlock()
        }

        func record(_ request: URLRequest) -> Handler? {
            lock.lock()
            requests.append(request)
            let handler = handler
            lock.unlock()
            return handler
        }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return requests.count
        }

        var recordedRequests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        /// Returns `false` when `stopLoading` already ran for `id`, so the
        /// caller must cancel the task it just created.
        func storeTask(_ task: Task<Void, Never>, id: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelledIDs.remove(id) != nil {
                return false
            }
            loadTasks[id] = task
            return true
        }

        func takeTask(id: UUID) -> Task<Void, Never>? {
            lock.lock()
            defer { lock.unlock() }
            if let task = loadTasks.removeValue(forKey: id) {
                return task
            }
            cancelledIDs.insert(id)
            return nil
        }
    }

    private static let storage = Storage()
    private let loadID = UUID()

    /// Test-local Sendable boundary for `URLProtocolClient` callbacks.
    /// The load `Task` cannot capture `self` because the inherited
    /// `URLProtocol` Sendable conformance is unavailable. URLSession retains
    /// this protocol instance for the load; `Storage` serializes task
    /// bookkeeping and cancellation so each `loadID` delivers at most once.
    private struct ClientRelay: @unchecked Sendable {
        let proto: URLProtocol
        let client: URLProtocolClient?

        func fail(_ error: Error) {
            client?.urlProtocol(proto, didFailWithError: error)
        }

        func finish(response: URLResponse, body: Data) {
            client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(proto, didLoad: body)
            client?.urlProtocolDidFinishLoading(proto)
        }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GoogleFreeTranslationHTTPStub.self]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    static func reset() {
        for task in storage.reset() {
            task.cancel()
        }
    }

    static func setHandler(_ handler: @escaping Handler) {
        storage.setHandler(handler)
    }

    static var requestCount: Int { storage.requestCount }

    static var recordedRequests: [URLRequest] { storage.recordedRequests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let handler = Self.storage.record(request)
        let loadID = self.loadID
        let relay = ClientRelay(proto: self, client: client)
        let task = Self.makeLoadTask(
            request: request,
            loadID: loadID,
            handler: handler,
            relay: relay
        )
        if !Self.storage.storeTask(task, id: loadID) {
            task.cancel()
        }
    }

    /// Form the load `Task` off the `URLProtocol` instance. `Task.init` takes a
    /// `sending` closure (SE-0430/0431); Swift 6.3's region checker cannot
    /// analyze that pattern when the closure is created in `startLoading`
    /// beside non-Sendable `self`. The static entry only sees immutable
    /// Sendable snapshots, so the task still cancels through `Storage`.
    private static func makeLoadTask(
        request: URLRequest,
        loadID: UUID,
        handler: Handler?,
        relay: ClientRelay
    ) -> Task<Void, Never> {
        Task { @Sendable in
            defer { _ = storage.takeTask(id: loadID) }
            guard let handler else {
                relay.fail(URLError(.badServerResponse))
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
            relay.finish(response: response, body: canned.body)
        }
    }

    override func stopLoading() {
        Self.storage.takeTask(id: loadID)?.cancel()
    }
}
