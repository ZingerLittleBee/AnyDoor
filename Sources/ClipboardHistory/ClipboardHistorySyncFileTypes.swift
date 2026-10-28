import Foundation

public struct ClipboardHistorySyncFileSummary: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let versionID: UUID
    public let displayName: String
    public let originalByteCount: Int64?
    public let state: ClipboardHistorySyncFileState
    public let availableVersionID: UUID?
    public let transferredByteCount: Int64
    public let transferFailure: ClipboardHistorySyncFileFailure?
    public let downloadRequested: Bool
    public let uploadPending: Bool
    public let hasConflict: Bool

    public init(id: UUID, versionID: UUID, displayName: String, originalByteCount: Int64?, state: ClipboardHistorySyncFileState,
        availableVersionID: UUID? = nil, transferredByteCount: Int64 = 0,
        transferFailure: ClipboardHistorySyncFileFailure? = nil, downloadRequested: Bool = false, uploadPending: Bool = false, hasConflict: Bool = false) {
        self.id = id
        self.versionID = versionID
        self.displayName = displayName
        self.originalByteCount = originalByteCount
        self.state = state
        self.availableVersionID = availableVersionID
        self.transferredByteCount = transferredByteCount
        self.transferFailure = transferFailure
        self.downloadRequested = downloadRequested
        self.uploadPending = uploadPending
        self.hasConflict = hasConflict
    }
}

public enum ClipboardHistorySyncFileFailure: String, Codable, Sendable {
    case network, quota, localStorage, localFileAccessDenied, sourceChanged, corruptData, accessDenied, accountChanged, keyUnavailable, unavailable
}

struct ClipboardSyncOwnedFileTransfer: Sendable {
    let objectID: UUID
    let versionID: UUID
    let record: ClipboardSyncRemoteRecord
}

public enum ClipboardHistorySyncFileState: String, Sendable {
    case complete
    case waitingForDownload
    case waitingForUpload
    case sourceUnavailable
    case localUnavailable
    case unsupportedKind
    case updateAvailable
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
    /// Absence denotes the bounded JSON body used by the initial file protocol.
    let bodyFormat: ClipboardSyncFileBodyFormat?
    let kind: ClipboardSyncFileKind?
    let encodedByteCount: Int64?

    var streamByteCount: Int64? { bodyFormat == .treeSegmentsV1 ? encodedByteCount : originalByteCount }

    init(objectID: UUID, versionID: UUID, displayName: String, originalByteCount: Int64?,
         contentDigest: Data?, body: ClipboardSyncRemoteRecord?, state: ClipboardSyncFileSourceState,
         bodyFormat: ClipboardSyncFileBodyFormat? = nil, kind: ClipboardSyncFileKind? = nil, encodedByteCount: Int64? = nil) {
        self.objectID = objectID
        self.versionID = versionID
        self.displayName = displayName
        self.originalByteCount = originalByteCount
        self.contentDigest = contentDigest
        self.body = body
        self.state = state
        self.bodyFormat = bodyFormat
        self.kind = kind
        self.encodedByteCount = encodedByteCount
    }
}

enum ClipboardSyncFileBodyFormat: String, Codable, Sendable {
    case segmentsV1
    case treeSegmentsV1
}

enum ClipboardSyncFileKind: String, Codable, Sendable { case file, directory }

struct ClipboardSyncFileVersionContent: Codable, Equatable, Sendable {
    let descriptor: ClipboardSyncFileDescriptor
    let parents: [UUID]
}

/// A completed local version is separate from the latest advertised version.
/// Linked-location ownership and its edited base are maintained independently.
struct ClipboardSyncVerifiedFileVersion: Sendable {
    let descriptor: ClipboardSyncFileDescriptor
    let parents: [UUID]
    let url: URL
    let identity: Data
    let bookmark: Data
}

struct ClipboardSyncFileSelection: Sendable {
    let latest: ClipboardSyncFileDescriptor
    let complete: ClipboardSyncVerifiedFileVersion?
    let heads: [ClipboardSyncFileDescriptor]

    var hasConflict: Bool { heads.count > 1 }
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
