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

    typealias Handler = @Sendable (URLRequest) async -> CannedResponse

    static let successBody = Data(#"[[["你好","hello",null,null,10]],null,"en"]"#.utf8)

    /// All mutable stub state lives in this lock box. A `static let` of a
    /// lock-serialized class is concurrency-safe; the `@unchecked Sendable`
    /// is sound because every field is read and written under `lock`.
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: Handler?
        private var requests: [URLRequest] = []
        private var loadTasks: [UUID: Task<Void, Never>] = []
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
        let task = Task {
            defer { _ = Self.storage.takeTask(id: loadID) }
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
        if !Self.storage.storeTask(task, id: loadID) {
            task.cancel()
        }
    }

    override func stopLoading() {
        Self.storage.takeTask(id: loadID)?.cancel()
    }
}
