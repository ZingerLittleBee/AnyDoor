import Foundation
import os
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
/// mount, so every filesystem touch goes through `SyncFolderCalls`, which
/// stops waiting after `timeout`. A timed-out or corrupt peer file is skipped
/// — that only delays convergence, it never corrupts it.
struct SyncFolderTransport: SyncTransport {
    let folderURL: URL
    var timeout: TimeInterval = 5
    var fileSystem = SyncFolderFileSystem()

    var watchableDirectory: URL? { folderURL }

    /// Read every peer document currently in the folder. Per-file tolerant:
    /// unreadable, timed-out, corrupt, or wrong-schema files are logged and
    /// skipped. Throws only when the folder itself cannot be listed in time
    /// (missing, unmounted, hung) — the one condition worth surfacing in the
    /// UI — or when the caller is cancelled.
    func readPeerDocuments(excludingDeviceID own: String) async throws -> [SyncDocument] {
        let folder = folderURL
        let fileSystem = fileSystem
        let names = try await SyncFolderCalls.run(on: folder, timeout: timeout) {
            try fileSystem.listFileNames(folder)
        }

        var documents: [SyncDocument] = []
        for name in names.sorted() {
            guard let deviceID = SyncStateFile.deviceID(fromFileName: name), deviceID != own else { continue }
            let url = folder.appendingPathComponent(name)
            do {
                let data = try await SyncFolderCalls.run(on: url, timeout: timeout) {
                    try fileSystem.read(url)
                }
                let document = try SyncStateCodec.decode(SyncDocument.self, from: data)
                guard document.schemaVersion == SyncDocument.currentSchemaVersion else {
                    logger.warning("skipping \(name): schema \(document.schemaVersion)")
                    continue
                }
                documents.append(document)
            } catch let cancellation as CancellationError {
                // A cancelled caller is not a bad peer file.
                throw cancellation
            } catch {
                logger.warning("skipping unreadable peer state \(name): \(error)")
            }
        }
        return documents
    }

    func writeOwnDocument(_ data: Data, deviceID: String) async throws {
        let url = folderURL.appendingPathComponent(SyncStateFile.name(forDeviceID: deviceID))
        let fileSystem = fileSystem
        try await SyncFolderCalls.run(on: url, timeout: timeout) {
            try fileSystem.write(data, url)
        }
    }
}

/// The folder transport's blocking file calls. Production uses Foundation;
/// tests stand in calls that block the way a hung mount does.
struct SyncFolderFileSystem: Sendable {
    var listFileNames: @Sendable (URL) throws -> [String] = { folder in
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }
    var read: @Sendable (URL) throws -> Data = { url in
        try Data(contentsOf: url)
    }
    var write: @Sendable (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }
}

/// Runs the folder transport's blocking file calls so that a stuck call can't
/// hold its caller.
///
/// A call into a File Provider mount can block for minutes on a dataless file
/// or a stalled mount, and nothing can interrupt it. Each call therefore runs
/// on a GCD thread, never on the Swift cooperative pool: a stuck call strands
/// that one thread instead of starving the pool all async work shares. Its
/// caller waits at most `timeout`: a GCD timer then resumes it with
/// `SyncTransportError.timedOut`, and cancelling the caller resumes it at once
/// with `CancellationError`. A started call cannot be interrupted; it runs to
/// its end and its result is dropped.
///
/// A call claims its file path for the whole process, across transports and
/// engine restarts, so a path that stays hung holds at most one thread and a
/// write that lands late can never overwrite a newer one. A call that finds
/// its path claimed waits, without holding a thread, for the earlier call to
/// return, at most until its own deadline. A claim held for longer than its
/// call's `timeout` is known to be stuck, so a new call on its path fails at
/// once with `.timedOut` instead of waiting for it again. The caller's
/// deadline is fixed when it arrives and covers both its wait and its call.
enum SyncFolderCalls {
    /// The call in flight on one path.
    private struct Claim {
        /// One `timeout` after the call claimed the path; a claim held past
        /// it is stuck.
        let stuckAt: DispatchTime
        /// Calls waiting for the path to free up.
        var waiters: [FirstOutcome<Void>] = []
    }

    private static let claims = OSAllocatedUnfairLock<[String: Claim]>(initialState: [:])

    static func run<T: Sendable>(
        on url: URL,
        timeout: TimeInterval,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let path = url.path
        let deadline = DispatchTime.now() + timeout
        try await claim(path, timeout: timeout, until: deadline)

        let outcome = FirstOutcome<T>()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try work() }
            SyncFolderCalls.release(path)
            outcome.resolve(result)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
            outcome.resolve(.failure(SyncTransportError.timedOut))
        }
        return try await outcome.value()
    }

    /// How many calls wait for `url`'s path to free up. A test seam: nothing
    /// else can tell a waiting call from one that has not arrived yet.
    static func waitingCallCountForTesting(on url: URL) -> Int {
        claims.withLock { $0[url.path]?.waiters.count ?? 0 }
    }

    /// Claims `path` for a call that may take `timeout` and whose caller gives
    /// up at `deadline`, after the path's earlier call returns if one is in
    /// flight. A cancelled caller never claims.
    private static func claim(
        _ path: String,
        timeout: TimeInterval,
        until deadline: DispatchTime
    ) async throws {
        while true {
            try Task.checkCancellation()
            let waiter = FirstOutcome<Void>()
            let claimed = try claims.withLock { held -> Bool in
                guard let holder = held[path] else {
                    held[path] = Claim(stuckAt: DispatchTime.now() + timeout)
                    return true
                }
                guard DispatchTime.now() < holder.stuckAt else {
                    throw SyncTransportError.timedOut
                }
                held[path]?.waiters.append(waiter)
                return false
            }
            if claimed { return }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                waiter.resolve(.failure(SyncTransportError.timedOut))
            }
            do {
                try await waiter.value()
            } catch {
                claims.withLock { $0[path]?.waiters.removeAll { $0 === waiter } }
                throw error
            }
        }
    }

    /// Frees `path` once its call returns, and wakes the calls waiting for it.
    private static func release(_ path: String) {
        let waiters = claims.withLock { $0.removeValue(forKey: path)?.waiters ?? [] }
        for waiter in waiters {
            waiter.resolve(.success(()))
        }
    }
}

/// The first outcome of a wait, delivered to its waiter exactly once. An
/// outcome that arrives before the waiter starts waiting is kept for it.
private final class FirstOutcome<T: Sendable>: Sendable {
    private struct State {
        var outcome: Result<T, any Error>?
        var continuation: CheckedContinuation<T, any Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Waits for the first outcome. Cancelling the waiting task settles the
    /// wait with `CancellationError`.
    func value() async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready = state.withLock { state -> Result<T, any Error>? in
                    if state.outcome == nil { state.continuation = continuation }
                    return state.outcome
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    /// Settles the wait with `outcome`, unless an earlier outcome already did.
    func resolve(_ outcome: Result<T, any Error>) {
        let waiting = state.withLock { state -> CheckedContinuation<T, any Error>? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            defer { state.continuation = nil }
            return state.continuation
        }
        waiting?.resume(with: outcome)
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
