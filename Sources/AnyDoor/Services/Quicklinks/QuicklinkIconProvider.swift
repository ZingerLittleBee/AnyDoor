import AppKit
import Foundation

struct QuicklinkIconRequest: Hashable, Sendable {
    let link: String
    let openWithBundleID: String?

    init(link: String, openWithBundleID: String?) {
        self.link = link
        self.openWithBundleID = QuicklinkOpenWith.normalizedBundleID(openWithBundleID)
    }
}

enum QuicklinkIconSource: Equatable, Sendable {
    case appBundleID(String)
    case fileSystem(path: String)
    case applicationURL(URL)
    case favicon(host: String)
    case symbol(String)
}

struct QuicklinkIconLookup: Sendable {
    let fileExists: @Sendable (String) -> QuicklinkDestination.FileExistence
    let applicationURLForBundleID: @Sendable (String) -> URL?
    let applicationURLToOpen: @Sendable (URL) -> URL?

    static let live = QuicklinkIconLookup(
        fileExists: { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return .none
            }
            return isDirectory.boolValue ? .directory : .file
        },
        applicationURLForBundleID: { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        },
        applicationURLToOpen: { url in
            NSWorkspace.shared.urlForApplication(toOpen: url)
        }
    )
}

/// Carries an `NSImage` across detached work, actor cache, and MainActor cache.
/// Safe because the image is created once and never mutated after handoff.
struct QuicklinkSendableImage: @unchecked Sendable {
    let image: NSImage
}

@MainActor
enum QuicklinkIconProvider {
    private static var cache: [QuicklinkIconRequest: NSImage] = [:]

    nonisolated static func source(
        for request: QuicklinkIconRequest,
        lookup: QuicklinkIconLookup
    ) -> QuicklinkIconSource {
        if let bundleID = request.openWithBundleID,
           lookup.applicationURLForBundleID(bundleID) != nil {
            return .appBundleID(bundleID)
        }

        let link = iconClassifiableLink(request.link)
        switch QuicklinkDestination.classify(link: link, fileExists: lookup.fileExists) {
        case .file(let url), .folder(let url):
            return .fileSystem(path: url.path)
        case .deeplink(let url):
            guard let applicationURL = lookup.applicationURLToOpen(url) else {
                return .symbol("link")
            }
            return .applicationURL(applicationURL)
        case .web(let url):
            guard let host = normalizedHost(url.host) else {
                return .symbol("link")
            }
            return .favicon(host: host)
        case .missingFileSystem, .searchTemplate, .unsupported:
            return .symbol("link")
        }
    }

    static func cached(_ request: QuicklinkIconRequest) -> NSImage? {
        cache[request]
    }

    static func icon(for request: QuicklinkIconRequest) async -> NSImage? {
        if let hit = cache[request] { return hit }
        guard let resolved = await resolvedImage(for: request) else { return nil }
        cache[request] = resolved.image
        return resolved.image
    }

    static func prewarm(_ requests: [QuicklinkIconRequest]) {
        for request in requests where cache[request] == nil {
            Task { _ = await icon(for: request) }
        }
    }

    private static func resolvedImage(for request: QuicklinkIconRequest) async -> QuicklinkSendableImage? {
        let source = await liveSource(for: request)
        switch source {
        case .appBundleID(let bundleID):
            if let image = await AppIconCache.icon(forBundleID: bundleID) {
                return QuicklinkSendableImage(image: image)
            }
            let fallback = QuicklinkIconRequest(link: request.link, openWithBundleID: nil)
            guard fallback != request else { return nil }
            return await resolvedImage(for: fallback)
        case .fileSystem(let path):
            return QuicklinkSendableImage(image: await AppIconCache.icon(for: path))
        case .applicationURL(let url):
            return QuicklinkSendableImage(image: await AppIconCache.icon(for: url.path))
        case .favicon(let host):
            return await QuicklinkFaviconCache.shared.image(forHost: host)
        case .symbol:
            return nil
        }
    }

    private nonisolated static func liveSource(for request: QuicklinkIconRequest) async -> QuicklinkIconSource {
        await Task.detached(priority: .userInitiated) {
            source(for: request, lookup: .live)
        }.value
    }

    private nonisolated static func iconClassifiableLink(_ link: String) -> String {
        guard QuicklinkDestination.isSearchTemplate(link: link) else { return link }
        return link.replacingOccurrences(of: "{query}", with: "query")
    }

    private nonisolated static func normalizedHost(_ host: String?) -> String? {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return nil
        }
        return host
    }
}

actor QuicklinkFaviconCache {
    static let shared = QuicklinkFaviconCache()

    private let cacheDirectory: URL
    private var memory: [String: QuicklinkSendableImage] = [:]
    private var negativeHosts: Set<String> = []
    private var inflight: [String: Task<QuicklinkSendableImage?, Never>] = [:]

    init(cacheDirectory: URL = QuicklinkFaviconCache.defaultCacheDirectory()) {
        self.cacheDirectory = cacheDirectory
    }

    func image(forHost host: String) async -> QuicklinkSendableImage? {
        let normalized = Self.normalizedHost(host)
        guard !normalized.isEmpty else { return nil }
        if let hit = memory[normalized] { return hit }
        if negativeHosts.contains(normalized) { return nil }

        let task: Task<QuicklinkSendableImage?, Never>
        if let existing = inflight[normalized] {
            task = existing
        } else {
            let directory = cacheDirectory
            task = Task.detached(priority: .utility) {
                await Self.loadOrFetch(host: normalized, cacheDirectory: directory)
            }
            inflight[normalized] = task
        }

        let image = await task.value
        inflight[normalized] = nil
        if let image {
            memory[normalized] = image
        } else {
            negativeHosts.insert(normalized)
        }
        return image
    }

    private nonisolated static func defaultCacheDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("dev.bybee.AnyDoor", isDirectory: true)
            .appendingPathComponent("Favicons", isDirectory: true)
    }

    private nonisolated static func loadOrFetch(
        host: String,
        cacheDirectory: URL
    ) async -> QuicklinkSendableImage? {
        let fileURL = cacheDirectory.appendingPathComponent(cacheFileName(for: host))
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL),
               let image = NSImage(data: data) {
                return QuicklinkSendableImage(image: image)
            }
            try? FileManager.default.removeItem(at: fileURL)
        }

        guard let faviconURL = faviconURL(for: host),
              let (data, response) = try? await URLSession.shared.data(from: faviconURL),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = NSImage(data: data) else {
            return nil
        }

        let resolved = QuicklinkSendableImage(image: image)
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            return resolved
        }
        return resolved
    }

    private nonisolated static func faviconURL(for host: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/favicon.ico"
        return components.url
    }

    private nonisolated static func cacheFileName(for host: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        let safe = normalizedHost(host).unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
        return "\(safe.isEmpty ? "unknown" : safe).ico"
    }

    private nonisolated static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
