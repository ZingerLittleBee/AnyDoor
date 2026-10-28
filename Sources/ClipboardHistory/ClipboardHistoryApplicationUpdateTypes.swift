import Foundation

public enum ClipboardHistoryApplicationUpdateState: String, Codable, Sendable {
    case ready, requiresDownload, running, identityUncertain, localChanges, conflict, unavailable
}

public enum ClipboardHistoryApplicationUpdateError: Error, Equatable, Sendable {
    case stalePlan, running, identityUncertain, localChanges, candidateUnavailable
    case downloadRequired(UUID)
}

/// The opaque ID binds an explicit action to the displayed location and version.
/// Presentation values alone never authorize a package replacement.
public struct ClipboardHistoryApplicationUpdatePlan: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let entryID: ClipboardHistoryEntryID
    public let objectID: UUID
    public let locationID: UUID
    public let locationRevision: UInt64
    public let versionID: UUID
    public let displayName: String
    public let locationURL: URL
    public let state: ClipboardHistoryApplicationUpdateState
}

struct ClipboardApplicationUpdateSnapshot: Codable, Sendable {
    let id: UUID
    let accountID: String
    let epoch: UUID
    let keyID: UUID
    let entryID: UUID
    let objectID: UUID
    let location: ClipboardSyncFileConflictLocation
    let versionID: UUID
    let versionRevision: Int64
    let state: ClipboardHistoryApplicationUpdateState
}
