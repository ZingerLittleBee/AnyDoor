import Foundation

/// Where backup bytes live. Implementations move an opaque blob; serialization
/// is `BackupCodec`'s job. Future backends (iCloud, Gist, S3) conform here.
protocol SyncBackend: Sendable {
    var displayName: String { get }
    func upload(_ data: Data) async throws
    /// Returns nil when no backup exists yet at this location.
    func download() async throws -> Data?
}

/// Reads/writes a single JSON file at a fixed URL. The UI supplies the URL via
/// NSSavePanel (export) / NSOpenPanel (import).
struct LocalFileBackend: SyncBackend {
    let url: URL

    var displayName: String { "本地文件" }

    func upload(_ data: Data) async throws {
        try data.write(to: url, options: .atomic)
    }

    func download() async throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Synchronous variant for the panel-driven local flow (a save panel already
    /// blocked the main thread; the write is small). Cloud backends use the async API.
    func uploadSync(_ data: Data) throws {
        try data.write(to: url, options: .atomic)
    }

    func downloadSync() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
}
