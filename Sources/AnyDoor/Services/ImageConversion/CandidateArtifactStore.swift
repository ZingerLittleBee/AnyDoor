import CryptoKit
import Darwin
import Foundation

/// Owns the private temporary artifacts of one Image Conversion session.
///
/// Two retention roles exist per basket item and may point at the same file:
/// the *displayed* preview candidate (pruned when idle) and the *retained
/// Best-Effort* artifact (follows the basket item's lifetime — survives
/// window hiding and run completion, dies on item removal, replacement, or
/// session teardown). Every file on disk in the output location is one the
/// user accepted; everything here stays private under a user-only session
/// directory. Not Sendable — instances live inside the engine actor.
final class CandidateArtifactStore {
    /// Root under the user's temporary directory holding one subdirectory
    /// per session.
    static func baseDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("dev.bybee.AnyDoor-imageconversion", isDirectory: true)
    }

    let sessionDirectory: URL
    private let fileManager: FileManager
    private var displayedByItem: [UUID: AtomicOutputWriter.CandidateArtifact] = [:]
    private var bestEffortByItem: [UUID: AtomicOutputWriter.CandidateArtifact] = [:]

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        sessionDirectory = Self.baseDirectory(fileManager: fileManager)
            .appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - Materialization

    /// Persist encoded candidate bytes as an immutable private artifact with
    /// recorded byte count and SHA-256.
    func materialize(_ data: Data) throws -> AtomicOutputWriter.CandidateArtifact {
        let url = sessionDirectory.appendingPathComponent("artifact-\(UUID().uuidString)")
        try data.write(to: url, options: [.withoutOverwriting])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AtomicOutputWriter.CandidateArtifact(
            artifactURL: url,
            byteCount: Int64(data.count),
            sha256: digest
        )
    }

    // MARK: - Retention roles

    func displayed(forItem id: UUID) -> AtomicOutputWriter.CandidateArtifact? {
        displayedByItem[id]
    }

    func retainedBestEffort(forItem id: UUID) -> AtomicOutputWriter.CandidateArtifact? {
        bestEffortByItem[id]
    }

    /// Replace the displayed preview candidate; the displaced artifact is
    /// deleted unless the other role still references it.
    func setDisplayed(_ artifact: AtomicOutputWriter.CandidateArtifact?, forItem id: UUID) {
        let displaced = displayedByItem[id]
        displayedByItem[id] = artifact
        deleteIfUnreferenced(displaced)
    }

    /// Replace the retained Best-Effort artifact (a retry produced a newer
    /// candidate, or a target miss just happened).
    func setRetainedBestEffort(_ artifact: AtomicOutputWriter.CandidateArtifact?, forItem id: UUID) {
        let displaced = bestEffortByItem[id]
        bestEffortByItem[id] = artifact
        deleteIfUnreferenced(displaced)
    }

    /// The basket item is gone: both roles die with it.
    func removeItem(_ id: UUID) {
        let displayed = displayedByItem.removeValue(forKey: id)
        let bestEffort = bestEffortByItem.removeValue(forKey: id)
        deleteIfUnreferenced(displayed)
        deleteIfUnreferenced(bestEffort)
    }

    /// Idle window hidden: displayed previews are stale, but retained
    /// Best-Effort artifacts follow their items and survive.
    func pruneDisplayed(keepingItem selected: UUID? = nil) {
        for id in displayedByItem.keys where id != selected {
            setDisplayed(nil, forItem: id)
        }
    }

    /// Session teardown: delete every artifact and the session directory.
    func reset() {
        displayedByItem.removeAll()
        bestEffortByItem.removeAll()
        try? fileManager.removeItem(at: sessionDirectory)
        try? fileManager.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    deinit {
        try? fileManager.removeItem(at: sessionDirectory)
    }

    private func deleteIfUnreferenced(_ artifact: AtomicOutputWriter.CandidateArtifact?) {
        guard let artifact else { return }
        let stillReferenced = displayedByItem.values.contains(artifact)
            || bestEffortByItem.values.contains(artifact)
        guard !stillReferenced else { return }
        try? fileManager.removeItem(at: artifact.artifactURL)
    }

    // MARK: - Startup janitor

    /// Remove session directories previous processes left behind. Called at
    /// launch: `deinit`/`reset` cleanup never runs on process exit or crash,
    /// and anything older than `maxAge` cannot belong to a live session.
    static func cleanupStaleSessions(
        maxAge: TimeInterval = 24 * 60 * 60,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) {
        let base = baseDirectory(fileManager: fileManager)
        guard let sessions = try? fileManager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for session in sessions {
            let modified = (try? session.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > maxAge {
                try? fileManager.removeItem(at: session)
            }
        }
    }
}
