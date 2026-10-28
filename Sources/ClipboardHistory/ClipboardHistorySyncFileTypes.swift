import Foundation

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
