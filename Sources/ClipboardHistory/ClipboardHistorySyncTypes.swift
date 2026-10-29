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
    public let withdrawnEntryCount: Int
    public let lastCompletedAt: Date?
    public let canClearCloudData: Bool
    public let canRecoverMissingCloudCollection: Bool
    public let canRecoverReplacedCloudCollection: Bool
    public let cloudReset: ClipboardHistoryCloudResetStatus?

    public init(
        isEnabled: Bool = false,
        phase: ClipboardHistorySyncPhase = .disabled,
        uploadedEntryCount: Int = 0,
        receivedEntryCount: Int = 0,
        withdrawnEntryCount: Int = 0,
        lastCompletedAt: Date? = nil,
        cloudReset: ClipboardHistoryCloudResetStatus? = nil,
        canClearCloudData: Bool = false,
        canRecoverMissingCloudCollection: Bool = false,
        canRecoverReplacedCloudCollection: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.phase = phase
        self.uploadedEntryCount = uploadedEntryCount
        self.receivedEntryCount = receivedEntryCount
        self.withdrawnEntryCount = withdrawnEntryCount
        self.lastCompletedAt = lastCompletedAt
        self.cloudReset = cloudReset
        self.canClearCloudData = canClearCloudData
        self.canRecoverMissingCloudCollection = canRecoverMissingCloudCollection
        self.canRecoverReplacedCloudCollection = canRecoverReplacedCloudCollection
    }
}

/// Opaque confirmation bound to the account and collection shown to the user.
public struct ClipboardHistoryCloudResetConfirmation: Equatable, Sendable {
    let account: ClipboardSyncAccount
    let control: ClipboardSyncControl
}

/// Authorizes retiring only this Mac's previously observed missing collection.
public struct ClipboardHistoryMissingCloudCollectionRecoveryConfirmation: Equatable, Sendable {
    let account: ClipboardSyncAccount
    let previousControl: ClipboardSyncControl
}

/// Retires only this Mac's old authority after confirming the observed replacement.
public struct ClipboardHistoryReplacedCloudCollectionRecoveryConfirmation: Equatable, Sendable {
    let account: ClipboardSyncAccount
    let previousControl: ClipboardSyncControl
    let replacementControl: ClipboardSyncControl
}

public struct ClipboardHistoryCloudResetStatus: Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case preparing, clearing, completed, superseded }
    public let stage: Stage
    public let deletedRecordCount: Int
    public let failure: ClipboardHistorySyncPhase?
    public var isPending: Bool { stage == .preparing || stage == .clearing }
}

public enum ClipboardHistorySyncPhase: Codable, Equatable, Sendable {
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

public enum ClipboardHistorySyncFailure: String, Codable, Error, Sendable {
    case network
    case quota
    case localStorage
    case localFileAccessDenied
    case sourceChanged
    case corruptData
    case recoveryRequired
    case accountChanged
    case unsupportedVersion
    case providerRejected
}

public struct ClipboardHistorySyncTag: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let isSelected: Bool
    public let eligibleEntryCount: Int
    public let withdrawalEntryCount: Int
    public let rejoinEntryCount: Int
    public let requiresLocalAuthorization: Bool

    public init(id: String, displayName: String, isSelected: Bool, eligibleEntryCount: Int,
                withdrawalEntryCount: Int = 0, rejoinEntryCount: Int = 0, requiresLocalAuthorization: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.isSelected = isSelected
        self.eligibleEntryCount = eligibleEntryCount
        self.withdrawalEntryCount = withdrawalEntryCount
        self.rejoinEntryCount = rejoinEntryCount
        self.requiresLocalAuthorization = requiresLocalAuthorization
    }
}

public struct ClipboardHistorySyncTagMergePreview: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sourceID: String
    public let targetID: String
    public let displayName: String
    public let newlyEligibleEntryCount: Int
    public var canonicalTagID: String { min(sourceID, targetID) }
    let historyRevision: Int64
    let accountID: String
}
