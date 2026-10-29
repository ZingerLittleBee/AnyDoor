import Foundation
import GRDB

struct ClipboardSyncMetadataRevision: Codable, Equatable, Comparable, Sendable {
    let counter: Int64
    let operationID: String
    static let initial = Self(counter: 0, operationID: "")
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.operationID < rhs.operationID : lhs.counter < rhs.counter
    }
}

enum ClipboardSyncMetadataValue: Codable, Equatable, Sendable {
    case favorite(Bool)
    case recognition(kind: ClipboardHistoryDerivedJobKind, values: [String], basisRecordID: String)

    var field: String {
        switch self {
        case .favorite: "favorite"
        case .recognition(let kind, _, _): kind.rawValue
        }
    }
}

struct ClipboardSyncMetadataContent: Codable, Equatable, Sendable {
    let id: UUID
    let revision: ClipboardSyncMetadataRevision
    let value: ClipboardSyncMetadataValue
}

extension ClipboardHistoryModule {
    static func createSyncContentSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_metadata_clock (id INTEGER PRIMARY KEY CHECK(id = 1), counter INTEGER NOT NULL);
            INSERT INTO clipboard_sync_metadata_clock VALUES (1, 0);
            CREATE TABLE clipboard_sync_metadata (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, shared_id TEXT NOT NULL,
                field TEXT NOT NULL, value BLOB NOT NULL, pending INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(account_id, epoch, shared_id, field)
            ) WITHOUT ROWID;
            """)
    }

    func recordSyncFavoriteChange(_ favorite: Bool, entryID: String, in database: Database) throws {
        try recordSyncMetadataChange(entryID: entryID, in: database) { _ in .favorite(favorite) }
    }

    func recordSyncRecognitionChange(_ values: [String], kind: ClipboardHistoryDerivedJobKind,
                                     entryID: String, in database: Database) throws {
        try recordSyncMetadataChange(entryID: entryID, in: database) { recordID in
            .recognition(kind: kind, values: values, basisRecordID: recordID)
        }
    }

    private func recordSyncMetadataChange(entryID: String, in database: Database,
                                          value: (String) -> ClipboardSyncMetadataValue) throws {
        for row in try Row.fetchAll(database, sql: """
            SELECT account_id, epoch, shared_id, record_id FROM clipboard_sync_entries WHERE local_entry_id = ?
            """, arguments: [entryID]) {
            guard let id = UUID(uuidString: row["shared_id"]) else { throw ClipboardSyncServiceError.corruptData }
            let current = try Int64.fetchOne(database, sql: "SELECT counter FROM clipboard_sync_metadata_clock WHERE id = 1") ?? 0
            guard current < Int64.max - 1 else { throw ClipboardSyncServiceError.localStorage }
            let value = value(row["record_id"])
            try validateSyncMetadataValue(value)
            try database.execute(sql: "UPDATE clipboard_sync_metadata_clock SET counter = counter + 1 WHERE id = 1")
            let operation = ClipboardSyncMetadataContent(id: id,
                revision: .init(counter: current + 1, operationID: UUID().uuidString.lowercased()), value: value)
            try saveSyncMetadata(operation, accountID: row["account_id"], epoch: row["epoch"], pending: true, in: database)
        }
    }

    func stageSyncMetadata(account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data,
        generation: UInt64) async throws {
        var afterSubject = ""
        var afterField = ""
        while let row = try syncFileRead({ try Row.fetchOne($0, SQLRequest<Row>(literal: """
            SELECT metadata.shared_id, metadata.field, metadata.value FROM clipboard_sync_metadata AS metadata
            JOIN clipboard_sync_entries AS shared ON shared.account_id = metadata.account_id
                AND shared.epoch = metadata.epoch AND shared.shared_id = metadata.shared_id
            JOIN clipboard_entries AS entry ON entry.id = shared.local_entry_id
            WHERE metadata.account_id = \(account.identifier) AND metadata.epoch = \(control.epoch.uuidString) AND metadata.pending = 1
              AND (metadata.shared_id, metadata.field) > (\(afterSubject), \(afterField))
              AND (\(Self.syncEntryPublicationAuthority(accountID: account.identifier)))
            ORDER BY metadata.shared_id, metadata.field LIMIT 1
            """)) }) {
            let encoded: Data = row["value"]
            afterSubject = row["shared_id"]
            afterField = row["field"]
            let operation = try JSONDecoder().decode(ClipboardSyncMetadataContent.self, from: encoded)
            guard let operationID = UUID(uuidString: operation.revision.operationID) else { throw ClipboardSyncServiceError.corruptData }
            let subject = operation.id.uuidString.lowercased()
            try await stageSyncOperation(.metadata(operation), subjectID: subject, operationID: operationID,
                account: account, control: control, key: key, generation: generation) { database, _ in
                guard try syncSubjectCanStage(subject, account: account, control: control, in: database) else { return false }
                try database.execute(sql: """
                    UPDATE clipboard_sync_metadata SET pending = 0
                    WHERE account_id = ? AND epoch = ? AND shared_id = ? AND field = ? AND pending = 1 AND value = ?
                    """, arguments: [account.identifier, control.epoch.uuidString, subject, operation.value.field, encoded])
                return database.changesCount == 1
            }
        }
    }

    func seedSyncEntryMetadata(_ content: ClipboardSyncEntryContent, account: ClipboardSyncAccount,
                               record: ClipboardSyncRemoteRecord, in database: Database) throws {
        let basis = try String.fetchOne(database, sql: """
            SELECT record_id FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ? AND shared_id = ?
            """, arguments: [account.identifier, record.epoch.uuidString, content.id.uuidString.lowercased()]) ?? record.recordID
        var values: [ClipboardSyncMetadataValue] = [.favorite(content.favorite)]
        if let ocr = content.recognition.ocr { values.append(.recognition(kind: .ocr, values: ocr, basisRecordID: basis)) }
        if let qr = content.recognition.qr { values.append(.recognition(kind: .qr, values: qr, basisRecordID: basis)) }
        for value in values {
            try validateSyncMetadataValue(value)
            let initial = ClipboardSyncMetadataContent(id: content.id, revision: .initial, value: value)
            if try syncMetadata(id: content.id, field: value.field, accountID: account.identifier, epoch: record.epoch.uuidString, in: database) == nil {
                try saveSyncMetadata(initial, accountID: account.identifier, epoch: record.epoch.uuidString, pending: false, in: database)
            }
        }
        // Also apply registers received before an initial snapshot with no results.
        for field in ["favorite", "ocr", "qr"] {
            if let current = try syncMetadata(id: content.id, field: field, accountID: account.identifier,
                                              epoch: record.epoch.uuidString, in: database) {
                try applySyncMetadata(current, accountID: account.identifier, epoch: record.epoch.uuidString, in: database)
            }
        }
    }

    func syncEntryRecognition(entryID: String, in database: Database) throws -> ClipboardSyncRecognitionContent {
        func results(_ kind: ClipboardHistoryDerivedJobKind) throws -> [String]? {
            let completed = try Bool.fetchOne(database, sql: """
                SELECT EXISTS (SELECT 1 FROM clipboard_derived_jobs WHERE entry_id = ? AND kind = ? AND state = 'succeeded')
                    OR EXISTS (SELECT 1 FROM clipboard_sync_metadata AS metadata
                        JOIN clipboard_sync_entries AS shared ON shared.account_id = metadata.account_id
                            AND shared.epoch = metadata.epoch AND shared.shared_id = metadata.shared_id
                        WHERE shared.local_entry_id = ? AND metadata.field = ?)
                """, arguments: [entryID, kind.rawValue, entryID, kind.rawValue]) ?? false
            guard completed else { return nil }
            return try String.fetchAll(database, sql: """
                SELECT value FROM clipboard_search_fields WHERE entry_id = ? AND field_kind = ? ORDER BY field_index
                """, arguments: [entryID, kind.rawValue])
        }
        guard try Bool.fetchOne(database, sql: """
            SELECT EXISTS (SELECT 1 FROM clipboard_representations WHERE entry_id = ? AND kind = 'bitmap')
            """, arguments: [entryID]) == true else { return .init() }
        return try .init(ocr: results(.ocr), qr: results(.qr))
    }

    private func validateSyncMetadataValue(_ value: ClipboardSyncMetadataValue) throws {
        guard case .recognition(_, let values, let basisRecordID) = value else { return }
        guard !basisRecordID.isEmpty else { throw ClipboardSyncServiceError.corruptData }
        var count = 0
        for text in values {
            guard text.utf8.count <= PasteboardSnapshot.maximumByteCount - count else { throw ClipboardSyncServiceError.corruptData }
            count += text.utf8.count
        }
    }

    func importSyncMetadata(_ operation: ClipboardSyncMetadataContent, account: ClipboardSyncAccount,
                            record: ClipboardSyncRemoteRecord, fromCheckpoint: Bool = false, applying: Bool = true,
                            in database: Database) throws {
        let revision = operation.revision
        let validRevision = revision.counter > 0 && revision.counter < Int64.max - 1
            && UUID(uuidString: revision.operationID) != nil
        guard fromCheckpoint ? (revision == .initial || validRevision)
                : (validRevision && UUID(uuidString: revision.operationID) == record.operationID) else {
            throw ClipboardSyncServiceError.corruptData
        }
        try validateSyncMetadataValue(operation.value)
        try database.execute(sql: "UPDATE clipboard_sync_metadata_clock SET counter = MAX(counter, ?) WHERE id = 1",
            arguments: [operation.revision.counter])
        if let current = try syncMetadata(id: operation.id, field: operation.value.field, accountID: account.identifier,
                                          epoch: record.epoch.uuidString, in: database), current.revision >= operation.revision { return }
        // The register is durable even when the entry has not arrived yet.
        try saveSyncMetadata(operation, accountID: account.identifier, epoch: record.epoch.uuidString, pending: false, in: database)
        if applying {
            try applySyncMetadata(operation, accountID: account.identifier, epoch: record.epoch.uuidString, in: database)
        }
    }

    func applyRetainedSyncMetadata(sharedID: String, accountID: String, epoch: String, in database: Database) throws {
        for value in try Data.fetchAll(database, sql: """
            SELECT value FROM clipboard_sync_metadata WHERE account_id = ? AND epoch = ? AND shared_id = ?
            """, arguments: [accountID, epoch, sharedID]) {
            let operation = try JSONDecoder().decode(ClipboardSyncMetadataContent.self, from: value)
            try applySyncMetadata(operation, accountID: accountID, epoch: epoch, in: database)
        }
    }

    private func syncMetadata(id: UUID, field: String, accountID: String, epoch: String, in database: Database) throws -> ClipboardSyncMetadataContent? {
        try Data.fetchOne(database, sql: """
            SELECT value FROM clipboard_sync_metadata WHERE account_id = ? AND epoch = ? AND shared_id = ? AND field = ?
            """, arguments: [accountID, epoch, id.uuidString.lowercased(), field]).map {
                try JSONDecoder().decode(ClipboardSyncMetadataContent.self, from: $0)
            }
    }

    private func saveSyncMetadata(_ operation: ClipboardSyncMetadataContent, accountID: String, epoch: String,
                                  pending: Bool, in database: Database) throws {
        try database.execute(sql: """
            INSERT INTO clipboard_sync_metadata(account_id, epoch, shared_id, field, value, pending) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, epoch, shared_id, field) DO UPDATE SET value = excluded.value, pending = excluded.pending
            """, arguments: [accountID, epoch, operation.id.uuidString.lowercased(), operation.value.field,
                try JSONEncoder().encode(operation), pending])
    }

    private func applySyncMetadata(_ operation: ClipboardSyncMetadataContent, accountID: String, epoch: String, in database: Database) throws {
        guard let localID = try String.fetchOne(database, sql: """
            SELECT local_entry_id FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ? AND shared_id = ?
            """, arguments: [accountID, epoch, operation.id.uuidString.lowercased()]),
            try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM clipboard_entries WHERE id = ?)", arguments: [localID]) == true else { return }
        switch operation.value {
        case .recognition(let kind, let values, let basisRecordID):
            // Text edits remove the original bitmap. Late recognition is then
            // acknowledged without reviving results for obsolete content.
            guard try Bool.fetchOne(database, sql: """
                SELECT EXISTS (SELECT 1 FROM clipboard_sync_entries
                    WHERE account_id = ? AND epoch = ? AND shared_id = ? AND record_id = ?)
                    AND EXISTS (SELECT 1 FROM clipboard_representations WHERE entry_id = ? AND kind = 'bitmap')
                """, arguments: [accountID, epoch, operation.id.uuidString.lowercased(), basisRecordID, localID]) == true else { return }
            try Self.deleteSearchFields(forEntryID: localID, kind: kind.rawValue, from: database, faultInjector: faultInjector)
            for (index, value) in values.enumerated() {
                try Self.insertSearchField(value: value, kind: kind.rawValue, index: index,
                    rankingGroup: Self.searchRankingGroup(for: kind.rawValue), entryID: localID,
                    into: database, faultInjector: faultInjector)
            }
            if kind == .qr {
                try database.execute(sql: "DELETE FROM clipboard_entry_facets WHERE entry_id = ? AND facet = 'qrCode'", arguments: [localID])
                if !values.isEmpty {
                    try database.execute(sql: "INSERT INTO clipboard_entry_facets(entry_id, facet) VALUES (?, 'qrCode')", arguments: [localID])
                }
            }
        case .favorite(let favorite):
            let protected = try Bool.fetchOne(database, sql: "SELECT is_protected FROM clipboard_retention_state WHERE entry_id = ?", arguments: [localID]) ?? false
            try database.execute(sql: "UPDATE clipboard_entries SET is_favorite = ? WHERE id = ?", arguments: [favorite, localID])
            let remainsProtected = try recomputeProtection(for: localID, in: database)
            if protected, !remainsProtected {
                try database.execute(sql: "UPDATE clipboard_retention_state SET retention_started_at = ? WHERE entry_id = ?",
                    arguments: [now().timeIntervalSince1970, localID])
            }
        }
    }
}
