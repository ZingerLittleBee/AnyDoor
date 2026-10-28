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
