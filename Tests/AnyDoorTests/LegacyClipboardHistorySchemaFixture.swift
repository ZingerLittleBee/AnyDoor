import Foundation
import SwiftData

@testable import AnyDoor

// The pre-v2 clipboard-history schema, kept alive only as a test fixture.
//
// Production no longer models the legacy store at all: migration reads the
// snapshot as plain SQLite (`ClipboardHistoryLegacyStoreReader`) because
// Core Data's row cache makes a SwiftData read peak at roughly twice the store
// size. Keeping the `@Model` here lets the migration tests build their input
// with real SwiftData, so the reader is exercised against a genuine
// Core Data-produced file rather than a layout we hand-rolled to match it.
//
// The class and property names below *are* the contract: Core Data derives
// `ZCLIPBOARDHISTORYITEM` and its `Z`-prefixed columns from them. Renaming
// anything here breaks the reader's SQL, and the migration tests fail loudly
// rather than quietly dropping history.

/// One file inside a `.file` clipboard entry. `storedName` is the copy held in
/// the history directory; `originalName` is shown on the card. For
/// reference-only entries (over the size ceiling) `storedName` is nil and the
/// original on-disk path is kept in `originalPath` for write-back.
struct ClipboardFileEntry: Codable, Sendable, Hashable {
    var storedName: String?
    var originalName: String
    var originalPath: String
}

@Model
final class ClipboardHistoryItem {
    @Attribute(.unique) var id: UUID
    var kind: String
    var text: String?
    var fileName: String?
    var colorHex: String?
    var previewTitle: String
    var previewSubtitle: String?
    var createdAt: Date

    // Paste-style additions.
    var richData: Data?
    var richType: String?
    var sourceBundleID: String?
    var sourceAppName: String?
    var isFavorite: Bool = false
    var filesManifest: Data?
    var isReferenceOnly: Bool = false
    /// JSON-encoded ids of user-defined categories (`ClipboardTag.id`).
    /// Stored as an optional String scalar instead of a `[String]`
    /// transformable: lightweight migration leaves a new transformable column
    /// NULL on existing rows, and the secure-unarchive transformer then
    /// throws when those rows are faulted (launch crash). An optional scalar
    /// decodes NULL as nil safely. nil ⇔ no tags.
    private var tagIDsJSON: String?

    init(
        id: UUID = UUID(),
        kind: ClipboardHistoryKind,
        text: String? = nil,
        fileName: String? = nil,
        colorHex: String? = nil,
        previewTitle: String,
        previewSubtitle: String? = nil,
        createdAt: Date = Date(),
        richData: Data? = nil,
        richType: String? = nil,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        isFavorite: Bool = false,
        filesManifest: Data? = nil,
        isReferenceOnly: Bool = false,
        tagIDs: [String] = []
    ) {
        self.id = id
        self.kind = kind.rawValue
        self.text = text
        self.fileName = fileName
        self.colorHex = colorHex
        self.previewTitle = previewTitle
        self.previewSubtitle = previewSubtitle
        self.createdAt = createdAt
        self.richData = richData
        self.richType = richType
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.isFavorite = isFavorite
        self.filesManifest = filesManifest
        self.isReferenceOnly = isReferenceOnly
        self.tagIDsJSON = nil
        if !tagIDs.isEmpty { self.tagIDs = tagIDs }
    }

    /// IDs of user-defined categories this item belongs to. Computed facade
    /// over `tagIDsJSON`; non-empty exempts the item from pruning, like
    /// `isFavorite`. Never referenced inside a `#Predicate`.
    var tagIDs: [String] {
        get {
            guard let tagIDsJSON else { return [] }
            return (try? JSONDecoder().decode(
                [String].self,
                from: Data(tagIDsJSON.utf8)
            )) ?? []
        }
        set {
            if newValue.isEmpty {
                tagIDsJSON = nil
            } else if let data = try? JSONEncoder().encode(newValue) {
                tagIDsJSON = String(data: data, encoding: .utf8)
            }
        }
    }
}
