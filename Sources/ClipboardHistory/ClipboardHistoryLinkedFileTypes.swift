import Foundation

public struct ClipboardHistoryLinkedFileLocation: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let objectID: UUID
    public let baseVersionID: UUID
    public let url: URL
    public let kind: ClipboardHistoryLinkedFileLocationKind
    public let state: ClipboardHistoryLinkedFileLocationState
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
