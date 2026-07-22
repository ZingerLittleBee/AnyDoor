import Network
import ScriptPluginRuntime
import XCTest

/// Pins the production `URLSessionFetchTransport` against a real loopback
/// server (the repo's no-mocking philosophy: the transport *is* the network
/// boundary, so it is tested for real). The server baits the HTTP cache with
/// the same five-day `Cache-Control` V2EX sends; a transport that honors it
/// would serve day-old rows from the local `URLCache` on every palette open.
final class ScriptFetchTransportTests: XCTestCase {

    func testFetchBypassesLocalHTTPCache() async throws {
        let server = try CacheBaitHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        let transport = URLSessionFetchTransport()
        let url = "http://127.0.0.1:\(port)/hot.json"

        let first = try await transport.fetch(ScriptFetchRequest(url: url))
        let second = try await transport.fetch(ScriptFetchRequest(url: url))

        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(first.body, "response-1")
        // The second fetch must hit the live server despite the cacheable
        // first response; a cached reply would repeat "response-1".
        XCTAssertEqual(second.body, "response-2")
    }
}

/// Minimal HTTP/1.1 loopback server: every request gets a fresh incrementing
/// body wrapped in an aggressively cacheable response (public, max-age five
/// days), so any local-cache hit is observable as a repeated body.
private final class CacheBaitHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cache-bait-http-server")
    private let lock = NSLock()
    private var hitCount = 0
    private var startResumed = false

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Start listening and return the system-assigned port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.claimStartResume(for: state) else { return }
                switch state {
                case .ready:
                    continuation.resume(returning: self.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    /// The state handler fires for every transition; only the first terminal
    /// state may resume the start continuation.
    private func claimStartResume(for state: NWListener.State) -> Bool {
        switch state {
        case .ready, .failed:
            lock.lock()
            defer { lock.unlock() }
            if startResumed { return false }
            startResumed = true
            return true
        default:
            return false
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffered: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self, error == nil, let data else {
                connection.cancel()
                return
            }
            var buffer = buffered
            buffer.append(data)
            guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                self.receiveRequest(connection, buffered: buffer)
                return
            }
            connection.send(content: self.makeResponse(), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func makeResponse() -> Data {
        lock.lock()
        hitCount += 1
        let body = "response-\(hitCount)"
        lock.unlock()
        let head = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/plain",
            "Cache-Control: public, max-age=432000",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
            "", "",
        ].joined(separator: "\r\n")
        return Data((head + body).utf8)
    }
}
