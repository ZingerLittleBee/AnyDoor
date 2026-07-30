import Foundation

public struct ClipboardHistoryEntryID: Hashable, Sendable {
    public let value: UUID

    public init(_ value: UUID) {
        self.value = value
    }
}

public struct ClipboardHistoryEntry: Equatable, Sendable {
    public let id: ClipboardHistoryEntryID
    public let capturedAt: Date
    public let previewText: String?
    public let facets: Set<ClipboardHistoryFacet>
    public let isFavorite: Bool

    public init(
        id: ClipboardHistoryEntryID,
        capturedAt: Date,
        previewText: String?,
        facets: Set<ClipboardHistoryFacet>,
        isFavorite: Bool
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.previewText = previewText
        self.facets = facets
        self.isFavorite = isFavorite
    }
}

public enum ClipboardHistoryFacet: String, CaseIterable, Sendable {
    case text
    case link
    case email
    case color
    case image
    case screenshot
    case file
    case qrCode
}

public struct ClipboardHistoryQuery: Equatable, Sendable {
    public var text: String
    public var facet: ClipboardHistoryFacet?
    public var sourceID: String?
    public var tagID: String?
    public var favoritesOnly: Bool

    public init(
        text: String = "",
        facet: ClipboardHistoryFacet? = nil,
        sourceID: String? = nil,
        tagID: String? = nil,
        favoritesOnly: Bool = false
    ) {
        self.text = text
        self.facet = facet
        self.sourceID = sourceID
        self.tagID = tagID
        self.favoritesOnly = favoritesOnly
    }
}

public struct ClipboardHistoryCursor: Equatable, Sendable {
    let token: Data

    init(token: Data) {
        self.token = token
    }
}

public struct ClipboardHistoryPage: Equatable, Sendable {
    public let entries: [ClipboardHistoryEntry]
    public let nextCursor: ClipboardHistoryCursor?

    public init(
        entries: [ClipboardHistoryEntry],
        nextCursor: ClipboardHistoryCursor?
    ) {
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

public enum ClipboardHistoryMonitoringCommand: Sendable {
    case start
    case stop
}

public struct ClipboardHistoryCaptureRequest: Equatable, Sendable {
    public let source: ClipboardHistoryCaptureSource
    public let content: ClipboardHistoryCaptureContent

    public init(
        source: ClipboardHistoryCaptureSource,
        content: ClipboardHistoryCaptureContent
    ) {
        self.source = source
        self.content = content
    }
}

public struct ClipboardHistoryCaptureSource: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let displayName: String?

    public init(bundleIdentifier: String?, displayName: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

public enum ClipboardHistoryCaptureContent: Equatable, Sendable {
    case text(String)
    case color(String)
    case bitmap(Data, provenance: ClipboardHistoryBitmapProvenance)
    case qrCode(String)
}

public enum ClipboardHistoryBitmapProvenance: Equatable, Sendable {
    case image
    case anyDoorScreenshot
}

public struct ClipboardHistoryCaptureOutcome: Equatable, Sendable {
    public let entryID: ClipboardHistoryEntryID

    public init(entryID: ClipboardHistoryEntryID) {
        self.entryID = entryID
    }
}

public enum ClipboardHistoryMutation: Equatable, Sendable {
    case delete(ClipboardHistoryEntryID)
    case setFavorite(ClipboardHistoryEntryID, Bool)
    case setTags(ClipboardHistoryEntryID, Set<String>)
    case editText(ClipboardHistoryEntryID, String)
}

public enum ClipboardHistoryMutationOutcome: Equatable, Sendable {
    case updated(ClipboardHistoryEntry)
    case deleted
    case notFound
}

public struct ClipboardHistoryMaterializationRequest: Equatable, Sendable {
    public let entryID: ClipboardHistoryEntryID
    public let purpose: ClipboardHistoryMaterializationPurpose

    public init(
        entryID: ClipboardHistoryEntryID,
        purpose: ClipboardHistoryMaterializationPurpose
    ) {
        self.entryID = entryID
        self.purpose = purpose
    }
}

public enum ClipboardHistoryMaterializationPurpose: Equatable, Sendable {
    case normalPaste
    case plainTextPaste
    case preview
    case hostAction
}

public struct ClipboardHistoryMaterialization: Equatable, Sendable {
    public let items: [ClipboardHistoryMaterializedItem]

    public init(items: [ClipboardHistoryMaterializedItem]) {
        self.items = items
    }
}

public struct ClipboardHistoryMaterializedItem: Equatable, Sendable {
    public let representations: [ClipboardHistoryMaterializedRepresentation]

    public init(representations: [ClipboardHistoryMaterializedRepresentation]) {
        self.representations = representations
    }
}

public enum ClipboardHistoryMaterializedRepresentation: Equatable, Sendable {
    case text(String)
    case data(typeIdentifier: String, Data)
}

public struct ClipboardHistoryStatus: Equatable, Sendable {
    public let availability: Availability
    public let reason: AvailabilityReason?
    public let isMonitoring: Bool

    public init(
        availability: Availability,
        reason: AvailabilityReason? = nil,
        isMonitoring: Bool
    ) {
        self.availability = availability
        self.reason = reason
        self.isMonitoring = isMonitoring
    }

    public enum Availability: Equatable, Sendable {
        case ready
        case paused
        case unavailable
    }

    public enum AvailabilityReason: Equatable, Sendable {
        case keychainLocked
        case missingKey
        case keyAccessDenied
        case keychainFailure
        case databaseAuthenticationFailed
        case databaseCorrupt
        case databaseIntegrityFailed
        case storeIOFailure
    }
}

public enum ClipboardHistoryModuleError: Error, Equatable {
    case operationUnavailable
    case entryNotFound
    case storeUnavailable
    case storageFailure
    case payloadAuthenticationFailed(ClipboardHistoryEntryID)
    case payloadUnavailable(ClipboardHistoryEntryID)
    case resetFailed
}

public enum ClipboardHistoryResetConfirmation: Sendable {
    case confirmed
}

public struct ClipboardHistoryMaintenanceReport: Equatable, Sendable {
    public let reclaimedPayloadCount: Int
    public let storageBytes: UInt64

    public init(reclaimedPayloadCount: Int, storageBytes: UInt64) {
        self.reclaimedPayloadCount = reclaimedPayloadCount
        self.storageBytes = storageBytes
    }
}
