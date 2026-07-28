import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "sync")

enum SyncTransportError: Error, Equatable {
    case timedOut
    case unauthorized
    case http(Int)
    case badResponse
}

/// Where sync state lives. A transport moves whole state files; document
/// semantics stay in the engine. Implementations: `SyncFolderTransport`
/// (cloud-drive folder) and `SyncWebDAVTransport` (self-hosted servers).
protocol SyncTransport: Sendable {
    /// Read every peer document. Per-file tolerant; throws only when the
    /// location itself is unreachable (or rejects the credentials).
    func readPeerDocuments(excludingDeviceID: String) async throws -> [SyncDocument]
    func writeOwnDocument(_ data: Data, deviceID: String) async throws
    /// A local directory the engine can watch for changes, when the transport
    /// is backed by one; nil means the engine relies on periodic polling.
    var watchableDirectory: URL? { get }
}

/// The state-file naming policy shared by every transport. Strict pattern
/// gate: anything else at the location — user files, a cloud client's
/// "conflicted copy" artifacts — is invisible.
enum SyncStateFile {
    static let prefix = "AnyDoor-SyncState-"
    static let suffix = ".json"

    static func name(forDeviceID deviceID: String) -> String {
        prefix + deviceID + suffix
    }

    static func deviceID(fromFileName name: String) -> String? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let id = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard !id.isEmpty,
              id.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" })
        else { return nil }
        return id
    }
}

/// Stable JSON encoding for sync state. `sortedKeys` makes encoding
/// deterministic so "did the document change since the last write?" is a
/// byte comparison.
enum SyncStateCodec {
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

/// The v1 transport of ADR-0010: a user-chosen folder, usually inside a cloud
/// drive's local mount. Each device writes exactly one state file and reads
/// everyone else's; the cloud client moves the bytes.
///
/// File Provider defense: any call can hang on a dataless file or a stalled
/// mount, so every filesystem touch races a timeout. A timed-out or corrupt
/// peer file is skipped — that only delays convergence, it never corrupts it.
struct SyncFolderTransport: SyncTransport {
    let folderURL: URL
    var timeout: TimeInterval = 5

    var watchableDirectory: URL? { folderURL }

    /// Read every peer document currently in the folder. Per-file tolerant:
    /// unreadable, timed-out, corrupt, or wrong-schema files are logged and
    /// skipped. Throws only when the folder itself cannot be listed (missing,
    /// unmounted, hung) — the one condition worth surfacing in the UI.
    func readPeerDocuments(excludingDeviceID own: String) async throws -> [SyncDocument] {
        let folder = folderURL
        let names = try await Self.withTimeout(timeout) {
            try FileManager.default.contentsOfDirectory(atPath: folder.path)
        }

        var documents: [SyncDocument] = []
        for name in names.sorted() {
            guard let deviceID = SyncStateFile.deviceID(fromFileName: name), deviceID != own else { continue }
            let url = folder.appendingPathComponent(name)
            do {
                let data = try await Self.withTimeout(timeout) { try Data(contentsOf: url) }
                let document = try SyncStateCodec.decode(SyncDocument.self, from: data)
                guard document.schemaVersion == SyncDocument.currentSchemaVersion else {
                    logger.warning("skipping \(name): schema \(document.schemaVersion)")
                    continue
                }
                documents.append(document)
            } catch {
                logger.warning("skipping unreadable peer state \(name): \(error)")
            }
        }
        return documents
    }

    func writeOwnDocument(_ data: Data, deviceID: String) async throws {
        let url = folderURL.appendingPathComponent(SyncStateFile.name(forDeviceID: deviceID))
        try await Self.withTimeout(timeout) {
            try data.write(to: url, options: .atomic)
        }
    }

    /// Race blocking file I/O against a wall-clock timeout. The blocking work
    /// cannot be cancelled — on timeout it is abandoned on its pool thread and
    /// the caller moves on; the next tick simply tries again.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SyncTransportError.timedOut
            }
            guard let first = try await group.next() else {
                throw SyncTransportError.timedOut
            }
            group.cancelAll()
            return first
        }
    }
}

/// Machine-local persistence of the engine's own document + clock, so clocks
/// stay monotonic across launches and the document survives the sync folder
/// being temporarily unavailable.
struct SyncLocalState: Codable, Equatable, Sendable {
    var clock: SyncClock
    var document: SyncDocument
}

struct SyncLocalStateStore: Sendable {
    let url: URL

    static func defaultURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("dev.bybee.AnyDoor", isDirectory: true)
            .appendingPathComponent("Sync", isDirectory: true)
            .appendingPathComponent("local-state.json")
    }

    func load() -> SyncLocalState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try SyncStateCodec.decode(SyncLocalState.self, from: data)
        } catch {
            logger.error("local sync state unreadable, starting fresh: \(error)")
            return nil
        }
    }

    func save(_ state: SyncLocalState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try SyncStateCodec.encode(state).write(to: url, options: .atomic)
    }
}
