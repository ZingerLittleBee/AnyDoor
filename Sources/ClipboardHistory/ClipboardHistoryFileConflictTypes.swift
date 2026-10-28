import Foundation

public enum ClipboardHistoryFileConflictChoice: Codable, Hashable, Sendable {
    case version(UUID)
    case localLocation(UUID)
}

public enum ClipboardHistoryFileConflictAvailability: String, Codable, Sendable {
    case available, requiresDownload, unavailable
}

public struct ClipboardHistoryFileConflictCandidate: Equatable, Sendable, Identifiable {
    public let id: ClipboardHistoryFileConflictChoice
    public let originalByteCount: Int64?
    public let availability: ClipboardHistoryFileConflictAvailability
    public let localURL: URL?
}

/// The opaque ID binds a later choice to a persisted account/version/file snapshot.
/// Callers cannot change that snapshot by modifying presentation values.
public struct ClipboardHistoryFileConflictPlan: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let entryID: ClipboardHistoryEntryID
    public let objectID: UUID
    public let displayName: String
    public let candidates: [ClipboardHistoryFileConflictCandidate]
    public let ancestryComplete: Bool
}

struct ClipboardSyncFileConflictLocation: Codable, Equatable, Sendable {
    let id: UUID
    let path: String
    let identity: Data
    let baseVersionID: UUID
    let baseDigest: Data
    let state: String
    let savedDigest: Data?
    let byteCount: Int64?
}

struct ClipboardSyncFileConflictSnapshot: Codable, Sendable {
    let accountID: String
    let epoch: UUID
    let keyID: UUID
    let entryID: UUID
    let objectID: UUID
    let heads: [UUID]
    let locations: [ClipboardSyncFileConflictLocation]
}
