import Foundation
import GRDB

/// Reads the pre-v2 SwiftData store as plain SQLite.
///
/// Core Data keeps every fetched blob in its row cache, so reading the snapshot
/// through a `ModelContext` costs a second full copy of the store on top of the
/// entries handed back — measured at ~215MB for 800 rows of 128KB, identically
/// for a one-shot `fetch` and for `enumerate(batchSize:)`, and identically even
/// when the enumeration block retains nothing. A cursor releases each row as it
/// advances, so the same fixture peaks at ~113MB: the returned entries and
/// nothing else.
///
/// That remainder is the transfer array itself, and it is deliberate — the
/// migration publishes in one atomic step, which the crash-safe cutover rests
/// on, so the whole transfer has to be in hand before publication starts.
/// Making the peak independent of history size means streaming the publish,
/// which is a different guarantee, not a different read.
///
/// Reading Core Data's private table layout is normally a bad idea. It is sound
/// here precisely because this store is dead: nothing writes the v1 schema any
/// more, and the file is a byte copy of a store this app itself produced, so the
/// layout cannot drift underneath us. `ClipboardHistoryLegacyStoreReaderTests`
/// pins every name and encoding below against a store built by SwiftData, so a
/// toolchain that changed them would fail the suite rather than silently drop
/// the user's history.
public enum ClipboardHistoryLegacyStoreReader {
    /// Why a row could not be mapped. The caller decides how loudly to report
    /// it; migration drops the row rather than failing the whole transfer.
    public struct SkippedRow: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            case unreadableIdentifier
            case unknownKind(String)
            case unreadableFileManifest
        }

        public let id: UUID?
        public let reason: Reason

        public init(id: UUID?, reason: Reason) {
            self.id = id
            self.reason = reason
        }
    }

    private enum RowOutcome {
        case mapped(ClipboardHistoryLegacyEntry)
        case skipped(SkippedRow)
    }

    private enum Column {
        static let table = "ZCLIPBOARDHISTORYITEM"
        static let primaryKey = "Z_PK"
        static let id = "ZID"
        static let kind = "ZKIND"
        static let createdAt = "ZCREATEDAT"
        static let text = "ZTEXT"
        static let fileName = "ZFILENAME"
        static let colorHex = "ZCOLORHEX"
        static let previewTitle = "ZPREVIEWTITLE"
        static let richData = "ZRICHDATA"
        static let richType = "ZRICHTYPE"
        static let sourceBundleID = "ZSOURCEBUNDLEID"
        static let sourceAppName = "ZSOURCEAPPNAME"
        static let isFavorite = "ZISFAVORITE"
        static let tagIDsJSON = "ZTAGIDSJSON"
        static let filesManifest = "ZFILESMANIFEST"
    }

    /// One file inside a v1 `.file` entry, as v1 encoded it.
    private struct LegacyFileManifestEntry: Decodable {
        let storedName: String?
        let originalName: String
        let originalPath: String
    }

    /// Streams every legacy row, newest first, mapping each into the transfer
    /// value type and releasing the row before advancing. Unmappable rows are
    /// reported through `onSkippedRow` and omitted: failing the whole transfer
    /// would cost the user their entire history on every retry, since each
    /// retry re-reads the same snapshot and meets the same row again.
    ///
    /// Returns an empty array when the store predates the entity entirely.
    public static func readEntries(
        at storeURL: URL,
        onSkippedRow: (SkippedRow) -> Void = { _ in }
    ) throws -> [ClipboardHistoryLegacyEntry] {
        // Opened read-write on purpose: the snapshot is copied with its -wal
        // sidecar, and SQLite needs write access to replay that journal. The
        // snapshot is a throwaway copy, so recovering it in place is harmless.
        let queue = try DatabaseQueue(path: storeURL.path)
        return try queue.read { database in
            guard try database.tableExists(Column.table) else {
                return []
            }
            var entries: [ClipboardHistoryLegacyEntry] = []
            // Z_PK breaks ties so the order is total: `recency_order` is
            // derived from this sequence downstream, and equal timestamps
            // must not reshuffle between runs.
            let cursor = try Row.fetchCursor(
                database,
                sql: """
                    SELECT \(Column.primaryKey), \(Column.id), \(Column.kind),
                           \(Column.createdAt), \(Column.text),
                           \(Column.fileName), \(Column.colorHex),
                           \(Column.previewTitle), \(Column.richData),
                           \(Column.richType), \(Column.sourceBundleID),
                           \(Column.sourceAppName), \(Column.isFavorite),
                           \(Column.tagIDsJSON), \(Column.filesManifest)
                    FROM \(Column.table)
                    ORDER BY \(Column.createdAt) DESC,
                             \(Column.primaryKey) DESC
                    """
            )
            while let row = try cursor.next() {
                switch makeEntry(from: row) {
                case .mapped(let entry):
                    entries.append(entry)
                case .skipped(let skipped):
                    onSkippedRow(skipped)
                }
            }
            return entries
        }
    }

    private static func makeEntry(from row: Row) -> RowOutcome {
        guard let identifier = uuid(from: row[Column.id]) else {
            return .skipped(
                SkippedRow(id: nil, reason: .unreadableIdentifier)
            )
        }
        let rawKind: String = row[Column.kind] ?? ""
        guard let kind = legacyKind(from: rawKind) else {
            return .skipped(
                SkippedRow(id: identifier, reason: .unknownKind(rawKind))
            )
        }

        var files: [ClipboardHistoryLegacyFileMember] = []
        if kind == .file {
            guard let manifest: Data = row[Column.filesManifest],
                let decoded = try? JSONDecoder().decode(
                    [LegacyFileManifestEntry].self,
                    from: manifest
                ),
                !decoded.isEmpty
            else {
                return .skipped(
                    SkippedRow(
                        id: identifier,
                        reason: .unreadableFileManifest
                    )
                )
            }
            files = decoded.map {
                ClipboardHistoryLegacyFileMember(
                    storedName: $0.storedName,
                    originalName: $0.originalName,
                    originalPath: $0.originalPath
                )
            }
        }

        // Core Data stores dates as seconds since its own reference date
        // (2001-01-01), not the Unix epoch.
        let capturedAt = Date(
            timeIntervalSinceReferenceDate: row[Column.createdAt] ?? 0
        )
        return .mapped(
            ClipboardHistoryLegacyEntry(
                id: identifier,
                kind: kind,
                text: row[Column.text],
                fileName: row[Column.fileName],
                colorHex: row[Column.colorHex],
                previewText: row[Column.previewTitle],
                capturedAt: capturedAt,
                richData: row[Column.richData],
                richType: row[Column.richType],
                source: ClipboardHistoryCaptureSource(
                    bundleIdentifier: row[Column.sourceBundleID],
                    displayName: row[Column.sourceAppName],
                    provenance: .legacy
                ),
                isFavorite: row[Column.isFavorite] ?? false,
                tagIDs: tagIDs(from: row[Column.tagIDsJSON]),
                files: files
            )
        )
    }

    /// v1's `ClipboardHistoryKind` raw values, which differ from the transfer's
    /// own spelling in one case (`qrcode` vs `qrCode`), so this stays explicit.
    private static func legacyKind(
        from rawValue: String
    ) -> ClipboardHistoryLegacyKind? {
        switch rawValue {
        case "text": .text
        case "color": .color
        case "qrcode": .qrCode
        case "ocr": .ocr
        case "image": .image
        case "screenshot": .screenshot
        case "file": .file
        default: nil
        }
    }

    /// Core Data stores the UUID as its raw 16 bytes.
    private static func uuid(from blob: Data?) -> UUID? {
        guard let blob, blob.count == MemoryLayout<uuid_t>.size else {
            return nil
        }
        return blob.withUnsafeBytes { raw in
            UUID(uuid: raw.loadUnaligned(as: uuid_t.self))
        }
    }

    /// v1 kept tag ids as a JSON array in an optional scalar; nil means none.
    private static func tagIDs(from json: String?) -> [String] {
        guard let json else { return [] }
        return (try? JSONDecoder().decode(
            [String].self,
            from: Data(json.utf8)
        )) ?? []
    }
}
