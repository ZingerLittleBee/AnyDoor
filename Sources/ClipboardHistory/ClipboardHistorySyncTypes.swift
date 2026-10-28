import Foundation

public extension Notification.Name {
    static let clipboardHistorySyncDidChange = Notification.Name(
        "dev.bybee.AnyDoor.clipboardHistorySyncDidChange"
    )
}

public struct ClipboardHistorySyncStatus: Equatable, Sendable {
    public let isEnabled: Bool
    public let phase: ClipboardHistorySyncPhase
    public let uploadedEntryCount: Int
    public let receivedEntryCount: Int
    public let lastCompletedAt: Date?

    public init(
        isEnabled: Bool = false,
        phase: ClipboardHistorySyncPhase = .disabled,
        uploadedEntryCount: Int = 0,
        receivedEntryCount: Int = 0,
        lastCompletedAt: Date? = nil
    ) {
        self.isEnabled = isEnabled
        self.phase = phase
        self.uploadedEntryCount = uploadedEntryCount
        self.receivedEntryCount = receivedEntryCount
        self.lastCompletedAt = lastCompletedAt
    }
}

public enum ClipboardHistorySyncPhase: Equatable, Sendable {
    case disabled
    case connecting
    case waitingForAccount
    case waitingForKey
    case keyLocked
    case accessDenied
    case capabilityUnavailable
    case transferring
    case upToDate
    case failed(ClipboardHistorySyncFailure)
}

public enum ClipboardHistorySyncFailure: String, Error, Sendable {
    case network
    case quota
    case localStorage
    case corruptData
    case recoveryRequired
    case accountChanged
    case unsupportedVersion
}

public struct ClipboardHistorySyncTag: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let isSelected: Bool
    public let eligibleEntryCount: Int

    public init(id: String, displayName: String, isSelected: Bool, eligibleEntryCount: Int) {
        self.id = id
        self.displayName = displayName
        self.isSelected = isSelected
        self.eligibleEntryCount = eligibleEntryCount
    }
}

