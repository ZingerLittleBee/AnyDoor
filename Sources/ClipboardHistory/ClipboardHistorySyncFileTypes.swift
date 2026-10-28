import Foundation

public struct ClipboardHistorySyncFileSummary: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let versionID: UUID
    public let displayName: String
    public let originalByteCount: Int64?
    public let state: ClipboardHistorySyncFileState

    public init(id: UUID, versionID: UUID, displayName: String, originalByteCount: Int64?, state: ClipboardHistorySyncFileState) {
        self.id = id
        self.versionID = versionID
        self.displayName = displayName
        self.originalByteCount = originalByteCount
        self.state = state
    }
}

public enum ClipboardHistorySyncFileState: String, Sendable {
    case complete
    case waitingForDownload
    case waitingForUpload
    case sourceUnavailable
    case unsupportedKind
}

/// This descriptor travels inside the authenticated, encrypted entry envelope.
/// A body is a separate object so discovery never authorizes its download.
struct ClipboardSyncFileDescriptor: Codable, Equatable, Sendable {
    let objectID: UUID
    let versionID: UUID
    let displayName: String
    let originalByteCount: Int64?
    let contentDigest: Data?
    let body: ClipboardSyncRemoteRecord?
    let state: ClipboardSyncFileSourceState
}

enum ClipboardSyncFileSourceState: String, Codable, Sendable {
    case available
    case sourceUnavailable
    case pendingUpload
    case unsupportedKind
}

struct ClipboardSyncFileBody: Codable, Equatable, Sendable {
    let objectID: UUID
    let versionID: UUID
    let bytes: Data
}
