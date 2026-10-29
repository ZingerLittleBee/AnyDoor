import Foundation

public struct ClipboardHistoryLinkedFileLocation: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let objectID: UUID
    public let baseVersionID: UUID
    public let url: URL
    public let kind: ClipboardHistoryLinkedFileLocationKind
    public let state: ClipboardHistoryLinkedFileLocationState
    public let revision: UInt64
    public let applicationUpdateVersionID: UUID?

    public init(id: UUID, objectID: UUID, baseVersionID: UUID, url: URL,
        kind: ClipboardHistoryLinkedFileLocationKind, state: ClipboardHistoryLinkedFileLocationState,
        revision: UInt64 = 0, applicationUpdateVersionID: UUID? = nil) {
        self.id = id; self.objectID = objectID; self.baseVersionID = baseVersionID
        self.url = url; self.kind = kind; self.state = state; self.revision = revision
        self.applicationUpdateVersionID = applicationUpdateVersionID
    }
}

public enum ClipboardHistoryLinkedFileLocationKind: String, Codable, Sendable {
    case original
    case workingCopy
    case associated
}

public enum ClipboardHistoryLinkedFileLocationState: String, Codable, Sendable {
    case current
    case localChanges
    case pendingUpload
    case conflict
    case unavailable
    case detached
    case identityUncertain
    case paused
}

public struct ClipboardHistoryFileLocationAssociation: Sendable {
    public let entryID: ClipboardHistoryEntryID
    public let objectID: UUID
    public let url: URL

    public init(entryID: ClipboardHistoryEntryID, objectID: UUID, url: URL) {
        self.entryID = entryID
        self.objectID = objectID
        self.url = url
    }
}

public struct ClipboardHistoryFileLocationSelection: Sendable {
    public let entryID: ClipboardHistoryEntryID
    public let locationID: UUID
    public let expectedRevision: UInt64

    public init(entryID: ClipboardHistoryEntryID, locationID: UUID, expectedRevision: UInt64) {
        self.entryID = entryID; self.locationID = locationID; self.expectedRevision = expectedRevision
    }
}

public struct ClipboardHistoryFileLocationReassociation: Sendable {
    public let selection: ClipboardHistoryFileLocationSelection
    public let url: URL

    public init(selection: ClipboardHistoryFileLocationSelection, url: URL) {
        self.selection = selection; self.url = url
    }
}
