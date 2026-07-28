import Foundation
import OSLog
import Security

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "sync")

/// Connection settings for a WebDAV sync location. `baseURL` is the directory
/// that holds the state files (https only, loopback http excepted — enforced
/// by the coordinator).
struct SyncWebDAVConfiguration: Equatable, Sendable {
    var baseURL: URL
    var username: String
    var password: String
}

/// Executes one HTTP request. The seam that keeps the transport testable —
/// tests plug an in-memory WebDAV server in here; production uses URLSession.
typealias SyncHTTPExecutor = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// The v2 transport of ADR-0010: a WebDAV directory on a self-hosted or
/// account-based server (Nextcloud, 坚果云, Synology…). Same file layout as
/// the folder transport — one state file per device — reached through
/// PROPFIND / GET / PUT instead of the filesystem.
struct SyncWebDAVTransport: SyncTransport {
    let config: SyncWebDAVConfiguration
    var timeout: TimeInterval = 15
    var execute: SyncHTTPExecutor = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncTransportError.badResponse
        }
        return (data, http)
    }

    var watchableDirectory: URL? { nil }

    func readPeerDocuments(excludingDeviceID own: String) async throws -> [SyncDocument] {
        let names: [String]
        do {
            names = try await listStateFiles()
        } catch SyncTransportError.http(404) {
            // Directory not created yet — a fresh setup, not an error.
            return []
        }
        var documents: [SyncDocument] = []
        for name in names.sorted() {
            guard let deviceID = SyncStateFile.deviceID(fromFileName: name), deviceID != own else { continue }
            do {
                let data = try await get(name)
                let document = try SyncStateCodec.decode(SyncDocument.self, from: data)
                guard document.schemaVersion == SyncDocument.currentSchemaVersion else {
                    logger.warning("skipping \(name): schema \(document.schemaVersion)")
                    continue
                }
                documents.append(document)
            } catch SyncTransportError.unauthorized {
                throw SyncTransportError.unauthorized
            } catch {
                logger.warning("skipping unreadable peer state \(name): \(error)")
            }
        }
        return documents
    }

    func writeOwnDocument(_ data: Data, deviceID: String) async throws {
        let name = SyncStateFile.name(forDeviceID: deviceID)
        do {
            try await put(name, data: data)
        } catch SyncTransportError.http(let status) where status == 404 || status == 409 {
            // Parent collection missing: create the leaf directory and retry.
            try await makeCollection()
            try await put(name, data: data)
        }
    }

    // MARK: - WebDAV verbs

    private func listStateFiles() async throws -> [String] {
        var request = makeRequest(url: collectionURL(), method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            #"<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>"#
                .utf8
        )
        let data = try await send(request, accepting: [207])
        return WebDAVMultistatusParser.fileNames(from: data)
    }

    private func get(_ name: String) async throws -> Data {
        let request = makeRequest(url: fileURL(name), method: "GET")
        return try await send(request, accepting: [200])
    }

    private func put(_ name: String, data: Data) async throws {
        var request = makeRequest(url: fileURL(name), method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        _ = try await send(request, accepting: [200, 201, 204])
    }

    private func makeCollection() async throws {
        let request = makeRequest(url: collectionURL(), method: "MKCOL")
        // 405 = collection already exists; a concurrent creator beat us, fine.
        _ = try await send(request, accepting: [201, 405])
    }

    // MARK: - Plumbing

    /// WebDAV collection URLs must end with a slash or some servers redirect
    /// PROPFIND (and drop the auth header on the hop).
    private func collectionURL() -> URL {
        var path = config.baseURL.absoluteString
        if !path.hasSuffix("/") { path += "/" }
        return URL(string: path) ?? config.baseURL
    }

    private func fileURL(_ name: String) -> URL {
        collectionURL().appendingPathComponent(name)
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        let credentials = Data("\(config.username):\(config.password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest, accepting statuses: Set<Int>) async throws -> Data {
        let (data, response) = try await execute(request)
        if statuses.contains(response.statusCode) { return data }
        if response.statusCode == 401 { throw SyncTransportError.unauthorized }
        throw SyncTransportError.http(response.statusCode)
    }
}

/// Extracts the file names of a PROPFIND Depth:1 multistatus response.
/// Namespace-aware (`D:href`, `d:href`, default-namespace `href` all match)
/// and tolerant of absolute-path vs full-URL hrefs; the collection itself
/// (href ending in `/`) is dropped.
enum WebDAVMultistatusParser {
    static func fileNames(from data: Data) -> [String] {
        let collector = HrefCollector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        parser.parse()
        return collector.hrefs.compactMap { href in
            guard !href.hasSuffix("/") else { return nil }
            let decoded = href.removingPercentEncoding ?? href
            guard let last = decoded.split(separator: "/").last else { return nil }
            return String(last)
        }
    }

    private final class HrefCollector: NSObject, XMLParserDelegate {
        var hrefs: [String] = []
        private var current: String?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String]
        ) {
            if elementName == "href", namespaceURI == "DAV:" {
                current = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            current? += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            if elementName == "href", namespaceURI == "DAV:", let href = current {
                hrefs.append(href.trimmingCharacters(in: .whitespacesAndNewlines))
                current = nil
            }
        }
    }
}

/// Keychain storage for the WebDAV password. Same `kSecClassGenericPassword`
/// shape as `TranslationKeychainStore`; secrets never touch UserDefaults and
/// are excluded from backup and sync.
struct SyncWebDAVCredentialStore: Sendable {
    private let service: String
    private static let account = "webdav"

    init(service: String = "dev.bybee.AnyDoor.sync") {
        self.service = service
    }

    func setPassword(_ password: String) {
        deletePassword()
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("SecItemAdd failed for WebDAV password: OSStatus \(status, privacy: .public)")
        }
    }

    func password() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    func deletePassword() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
