import Foundation

public extension Notification.Name {
    static let clipboardHistoryV2DidMutate = Notification.Name(
        "dev.bybee.AnyDoor.clipboardHistoryV2DidMutate"
    )
    static let clipboardHistoryV2OperationDidFail = Notification.Name(
        "dev.bybee.AnyDoor.clipboardHistoryV2OperationDidFail"
    )
}

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
    public let tagIDs: Set<String>
    public let source: ClipboardHistoryCaptureSource

    public init(
        id: ClipboardHistoryEntryID,
        capturedAt: Date,
        previewText: String?,
        facets: Set<ClipboardHistoryFacet>,
        isFavorite: Bool,
        tagIDs: Set<String> = [],
        source: ClipboardHistoryCaptureSource
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.previewText = previewText
        self.facets = facets
        self.isFavorite = isFavorite
        self.tagIDs = tagIDs
        self.source = source
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
    public var capturedAfter: Date?
    public var capturedBefore: Date?

    public init(
        text: String = "",
        facet: ClipboardHistoryFacet? = nil,
        sourceID: String? = nil,
        tagID: String? = nil,
        favoritesOnly: Bool = false,
        capturedAfter: Date? = nil,
        capturedBefore: Date? = nil
    ) {
        self.text = text
        self.facet = facet
        self.sourceID = sourceID
        self.tagID = tagID
        self.favoritesOnly = favoritesOnly
        self.capturedAfter = capturedAfter
        self.capturedBefore = capturedBefore
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
    public let state: ClipboardHistoryPageState

    public init(
        entries: [ClipboardHistoryEntry],
        nextCursor: ClipboardHistoryCursor?,
        state: ClipboardHistoryPageState = .ready
    ) {
        self.entries = entries
        self.nextCursor = nextCursor
        self.state = state
    }
}

public enum ClipboardHistoryPageState: Equatable, Sendable {
    case ready
    case indexing
    case failed(ClipboardHistorySearchIndexFailure)
}

public enum ClipboardHistorySearchIndexStatus: Equatable, Sendable {
    case ready
    case indexing
    case failed(ClipboardHistorySearchIndexFailure)
}

public enum ClipboardHistorySearchIndexFailure: Equatable, Sendable {
    case rebuildFailed
    case stateUnavailable
}

public enum ClipboardHistoryMonitoringCommand: Equatable, Sendable {
    case start
    case stop
    case migrationStarted
    case migrationCompleted
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
    public let provenance: ClipboardHistoryCaptureSourceProvenance

    public init(
        bundleIdentifier: String?,
        displayName: String?,
        provenance: ClipboardHistoryCaptureSourceProvenance = .declared
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.provenance = provenance
    }

    public static let universalClipboard = Self(
        bundleIdentifier: nil,
        displayName: nil,
        provenance: .universalClipboard
    )

    public static let unknown = Self(
        bundleIdentifier: nil,
        displayName: nil,
        provenance: .unknown
    )

    public static let anyDoor = Self(
        bundleIdentifier: "dev.bybee.AnyDoor",
        displayName: "AnyDoor",
        provenance: .declared
    )
}

public enum ClipboardHistoryCaptureSourceProvenance: String, Sendable {
    case universalClipboard
    case declared
    case copyEvent
    case observation
    case legacy
    case unknown
}

public struct ClipboardHistoryApplicationSource: Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String?

    public init(bundleIdentifier: String, displayName: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

public struct ClipboardHistorySourceSummary: Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public let count: Int

    public init(
        bundleIdentifier: String,
        displayName: String,
        count: Int
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.count = count
    }
}

public struct ClipboardHistoryMonitoringConfiguration: Equatable, Sendable {
    public static let defaultExcludedBundleIdentifiers: Set<String> = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
    ]

    public var excludedBundleIdentifiers: Set<String>
    public var ignoresUniversalClipboard: Bool

    public init(
        excludedBundleIdentifiers: Set<String> =
            Self.defaultExcludedBundleIdentifiers,
        ignoresUniversalClipboard: Bool = false
    ) {
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.ignoresUniversalClipboard = ignoresUniversalClipboard
    }
}

public enum ClipboardHistoryCaptureContent: Equatable, Sendable {
    case text(String)
    case ocr(String)
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

public enum ClipboardHistoryPasteboardCaptureOutcome: Equatable, Sendable {
    case captured(ClipboardHistoryCaptureOutcome)
    case skipped(ClipboardHistoryCaptureRejection)
}

public enum ClipboardHistoryCaptureRejection: Equatable, Sendable {
    case excluded
    case empty
    case unsupportedItem
    case generationChanged
    case contentTooLarge
    case imageTooLarge
    case invalidFileReference
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

public enum ClipboardHistoryRetentionPeriod:
    String,
    CaseIterable,
    Codable,
    Sendable
{
    case oneDay
    case sevenDays
    case thirtyDays
    case ninetyDays
    case oneHundredEightyDays
    case threeHundredSixtyFiveDays
    case unlimited

    public static let `default`: Self = .thirtyDays

    var duration: TimeInterval? {
        switch self {
        case .oneDay:
            86_400
        case .sevenDays:
            7 * 86_400
        case .thirtyDays:
            30 * 86_400
        case .ninetyDays:
            90 * 86_400
        case .oneHundredEightyDays:
            180 * 86_400
        case .threeHundredSixtyFiveDays:
            365 * 86_400
        case .unlimited:
            nil
        }
    }
}

public struct ClipboardHistoryRetentionStatus: Equatable, Sendable {
    public let period: ClipboardHistoryRetentionPeriod

    public init(period: ClipboardHistoryRetentionPeriod) {
        self.period = period
    }
}

public struct ClipboardHistoryTagDefinitionUpdate: Equatable, Sendable {
    public let removedMembershipCount: Int
    public let unprotectedEntryCount: Int

    public init(
        removedMembershipCount: Int,
        unprotectedEntryCount: Int
    ) {
        self.removedMembershipCount = removedMembershipCount
        self.unprotectedEntryCount = unprotectedEntryCount
    }
}

public struct ClipboardHistoryTagAssignment: Equatable, Sendable {
    public let definition: ClipboardHistoryTagDefinition
    public let entry: ClipboardHistoryEntry

    public init(
        definition: ClipboardHistoryTagDefinition,
        entry: ClipboardHistoryEntry
    ) {
        self.definition = definition
        self.entry = entry
    }
}

public enum ClipboardHistoryClearScope: String, Codable, Sendable {
    case unprotectedOnly
    case includingProtected
}

public struct ClipboardHistoryConfirmationToken: Equatable, Sendable {
    let data: Data

    init(data: Data) {
        self.data = data
    }
}

public struct ClipboardHistoryDestructivePreview: Equatable, Sendable {
    public let affectedCount: Int
    public let token: ClipboardHistoryConfirmationToken

    public init(
        affectedCount: Int,
        token: ClipboardHistoryConfirmationToken
    ) {
        self.affectedCount = affectedCount
        self.token = token
    }
}

public enum ClipboardHistoryRetentionChangePreparation: Equatable, Sendable {
    case applied(ClipboardHistoryRetentionPeriod)
    case confirmationRequired(ClipboardHistoryDestructivePreview)
}

public enum ClipboardHistoryDestructiveApplyOutcome: Equatable, Sendable {
    case applied(deletedCount: Int)
    case stale(ClipboardHistoryDestructivePreview)
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
    case text(typeIdentifier: String, value: String)
    case data(typeIdentifier: String, Data)
    case file(ClipboardHistoryMaterializedFileReference)
}

public struct ClipboardHistoryMaterializedFileReference: Equatable, Sendable {
    public let capturedPath: String
    public let displayName: String
    public let currentURL: URL

    public init(
        capturedPath: String,
        displayName: String,
        currentURL: URL
    ) {
        self.capturedPath = capturedPath
        self.displayName = displayName
        self.currentURL = currentURL
    }
}

public struct ClipboardHistoryStatus: Equatable, Sendable {
    public let availability: Availability
    public let reason: AvailabilityReason?
    public let isMonitoring: Bool
    public let searchIndex: ClipboardHistorySearchIndexStatus?

    public init(
        availability: Availability,
        reason: AvailabilityReason? = nil,
        isMonitoring: Bool,
        searchIndex: ClipboardHistorySearchIndexStatus? = nil
    ) {
        self.availability = availability
        self.reason = reason
        self.isMonitoring = isMonitoring
        self.searchIndex = searchIndex
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
        case searchIndexUnavailable
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
    case fileReferencesUnavailable(ClipboardHistoryEntryID, count: Int)
    case fileCollectionRequiresRestore(
        ClipboardHistoryEntryID,
        ownedCount: Int,
        unavailableCount: Int
    )
    case resetFailed
    case invalidTagIDs(Set<String>)
    case invalidTagName
    case duplicateTagName
    case tagDefinitionNotFound
    case invalidTextEdit
    case invalidConfirmation
    case unsupportedLegacyTransferVersion(Int)
    case legacyMigrationFailed
    case invalidLegacyFileRestore
    case legacyFileRestoreCollision(URL)
    case legacyFileRestoreFailed
    case legacyCleanupFailed
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

public enum ClipboardHistoryLegacyKind: String, Codable, Sendable {
    case text
    case color
    case qrCode
    case ocr
    case image
    case screenshot
    case file
}

public struct ClipboardHistoryLegacyFileMember:
    Equatable,
    Codable,
    Sendable
{
    public let storedName: String?
    public let originalName: String
    public let originalPath: String

    public init(
        storedName: String?,
        originalName: String,
        originalPath: String
    ) {
        self.storedName = storedName
        self.originalName = originalName
        self.originalPath = originalPath
    }
}

public struct ClipboardHistoryLegacyEntry: Equatable, Sendable {
    public let id: UUID
    public let kind: ClipboardHistoryLegacyKind
    public let text: String?
    public let fileName: String?
    public let colorHex: String?
    public let previewText: String?
    public let capturedAt: Date
    public let richData: Data?
    public let richType: String?
    public let source: ClipboardHistoryCaptureSource
    public let isFavorite: Bool
    public let tagIDs: [String]
    public let files: [ClipboardHistoryLegacyFileMember]

    public init(
        id: UUID,
        kind: ClipboardHistoryLegacyKind,
        text: String?,
        fileName: String?,
        colorHex: String?,
        previewText: String?,
        capturedAt: Date,
        richData: Data?,
        richType: String?,
        source: ClipboardHistoryCaptureSource,
        isFavorite: Bool,
        tagIDs: [String],
        files: [ClipboardHistoryLegacyFileMember]
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.fileName = fileName
        self.colorHex = colorHex
        self.previewText = previewText
        self.capturedAt = capturedAt
        self.richData = richData
        self.richType = richType
        self.source = source
        self.isFavorite = isFavorite
        self.tagIDs = tagIDs
        self.files = files
    }
}

public struct ClipboardHistoryLegacyTag: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ClipboardHistoryLegacyTransfer: Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let entries: [ClipboardHistoryLegacyEntry]
    public let tags: [ClipboardHistoryLegacyTag]
    public let categoryOrder: [String]
    public let retentionPeriod: ClipboardHistoryRetentionPeriod

    public init(
        version: Int = Self.currentVersion,
        entries: [ClipboardHistoryLegacyEntry],
        tags: [ClipboardHistoryLegacyTag],
        categoryOrder: [String],
        retentionPeriod: ClipboardHistoryRetentionPeriod
    ) {
        self.version = version
        self.entries = entries
        self.tags = tags
        self.categoryOrder = categoryOrder
        self.retentionPeriod = retentionPeriod
    }
}

public struct ClipboardHistoryLegacyMigrationRequest:
    Equatable,
    Sendable
{
    public let transfer: ClipboardHistoryLegacyTransfer
    public let payloadDirectory: URL

    public init(
        transfer: ClipboardHistoryLegacyTransfer,
        payloadDirectory: URL
    ) {
        self.transfer = transfer
        self.payloadDirectory = payloadDirectory
    }
}

public struct ClipboardHistoryLegacyMigrationReport:
    Equatable,
    Sendable
{
    public let retainedEntryCount: Int
    public let omittedExpiredEntryCount: Int
    public let ownedPayloadCount: Int
    public let redundantLegacyPayloadCount: Int

    public init(
        retainedEntryCount: Int,
        omittedExpiredEntryCount: Int,
        ownedPayloadCount: Int,
        redundantLegacyPayloadCount: Int
    ) {
        self.retainedEntryCount = retainedEntryCount
        self.omittedExpiredEntryCount = omittedExpiredEntryCount
        self.ownedPayloadCount = ownedPayloadCount
        self.redundantLegacyPayloadCount = redundantLegacyPayloadCount
    }
}

public enum ClipboardHistoryLegacyMigrationOutcome:
    Equatable,
    Sendable
{
    case published(ClipboardHistoryLegacyMigrationReport)
    case alreadyPublished(ClipboardHistoryLegacyMigrationReport)
}

public struct ClipboardHistoryLegacyFileMemberID:
    Hashable,
    Sendable
{
    public let itemIndex: Int
    public let memberIndex: Int

    public init(itemIndex: Int, memberIndex: Int) {
        self.itemIndex = itemIndex
        self.memberIndex = memberIndex
    }
}

public struct ClipboardHistoryLegacyFileRestoreMember:
    Equatable,
    Sendable
{
    public let id: ClipboardHistoryLegacyFileMemberID
    public let suggestedName: String

    public init(
        id: ClipboardHistoryLegacyFileMemberID,
        suggestedName: String
    ) {
        self.id = id
        self.suggestedName = suggestedName
    }
}

public struct ClipboardHistoryLegacyFileRestorePlan:
    Equatable,
    Sendable
{
    public let entryID: ClipboardHistoryEntryID
    public let ownedMembers: [ClipboardHistoryLegacyFileRestoreMember]
    public let unavailableCount: Int

    public init(
        entryID: ClipboardHistoryEntryID,
        ownedMembers: [ClipboardHistoryLegacyFileRestoreMember],
        unavailableCount: Int
    ) {
        self.entryID = entryID
        self.ownedMembers = ownedMembers
        self.unavailableCount = unavailableCount
    }
}

public enum ClipboardHistoryLegacyFileCollisionPolicy:
    Equatable,
    Sendable
{
    case failIfExists
    case reuseIfIdentical
}

public struct ClipboardHistoryLegacyFileDestination:
    Equatable,
    Sendable
{
    public let memberID: ClipboardHistoryLegacyFileMemberID
    public let url: URL
    public let collisionPolicy: ClipboardHistoryLegacyFileCollisionPolicy

    public init(
        memberID: ClipboardHistoryLegacyFileMemberID,
        url: URL,
        collisionPolicy: ClipboardHistoryLegacyFileCollisionPolicy =
            .failIfExists
    ) {
        self.memberID = memberID
        self.url = url
        self.collisionPolicy = collisionPolicy
    }
}

public struct ClipboardHistoryLegacyFileRestoreRequest:
    Equatable,
    Sendable
{
    public let entryID: ClipboardHistoryEntryID
    public let destinations: [ClipboardHistoryLegacyFileDestination]

    public init(
        entryID: ClipboardHistoryEntryID,
        destinations: [ClipboardHistoryLegacyFileDestination]
    ) {
        self.entryID = entryID
        self.destinations = destinations
    }
}

public enum ClipboardHistoryLegacyFileRestoreOutcome:
    Equatable,
    Sendable
{
    case restored(memberCount: Int)
    case alreadyRestored(memberCount: Int)
}

public struct ClipboardHistoryLegacyCleanupReport:
    Equatable,
    Sendable
{
    public let removedPayloadCount: Int
    public let alreadyMissingPayloadCount: Int
    public let pendingPayloadCount: Int
    public let canDeleteLegacyRows: Bool

    public init(
        removedPayloadCount: Int,
        alreadyMissingPayloadCount: Int,
        pendingPayloadCount: Int,
        canDeleteLegacyRows: Bool
    ) {
        self.removedPayloadCount = removedPayloadCount
        self.alreadyMissingPayloadCount = alreadyMissingPayloadCount
        self.pendingPayloadCount = pendingPayloadCount
        self.canDeleteLegacyRows = canDeleteLegacyRows
    }
}

public struct ClipboardHistoryTagDefinition: Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}
