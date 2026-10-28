import Foundation
import GRDB

struct ClipboardSyncAccountState: Codable, Sendable {
    let account: ClipboardSyncAccount
    var control: ClipboardSyncControl?
    var candidate: ClipboardSyncControl?
    var cursor: Data?
    var lastCompletedAt: Date?
}

extension ClipboardHistoryModule {
    func currentSyncRecovery() throws -> (phase: ClipboardHistorySyncPhase?, retryNotBefore: Date?) {
        try requiredDatabase().read { try syncRecovery(in: $0) }
    }

    func syncRecovery(in database: Database) throws -> (phase: ClipboardHistorySyncPhase?, retryNotBefore: Date?) {
        guard let row = try Row.fetchOne(database, sql: "SELECT phase, retry_not_before FROM clipboard_sync_recovery WHERE id = 1") else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        let data: Data? = row["phase"]
        let deadline: Double? = row["retry_not_before"]
        return (try data.map { try JSONDecoder().decode(ClipboardHistorySyncPhase.self, from: $0) },
                deadline.map { Date(timeIntervalSince1970: $0) })
    }

    /// Callers join the write turn before entering this synchronous transaction.
    /// Keeping it synchronous prevents an account/store transition between the
    /// final admission check and the local commit.
    func syncWrite<Value>(_ operation: (Database) throws -> Value) throws -> Value {
        try requiredDatabase().write(operation)
    }

    static func createSyncSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                enabled INTEGER NOT NULL DEFAULT 0,
                account_id TEXT
            );
            INSERT INTO clipboard_sync_settings(id) VALUES (1);
            CREATE TABLE clipboard_sync_accounts (id TEXT PRIMARY KEY NOT NULL, state BLOB NOT NULL);
            CREATE TABLE clipboard_sync_tags (
                account_id TEXT NOT NULL, tag_id TEXT NOT NULL, selected INTEGER NOT NULL,
                locally_authorized INTEGER NOT NULL DEFAULT 0,
                record_id TEXT, PRIMARY KEY(account_id, tag_id)
            ) WITHOUT ROWID;
            CREATE TABLE clipboard_sync_entries (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, shared_id TEXT NOT NULL,
                local_entry_id TEXT NOT NULL, record_id TEXT NOT NULL, origin TEXT NOT NULL,
                PRIMARY KEY(account_id, epoch, shared_id)
            ) WITHOUT ROWID;
            CREATE TABLE clipboard_sync_outbox (
                record_id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL, epoch TEXT NOT NULL,
                subject_id TEXT NOT NULL, kind TEXT NOT NULL, metadata BLOB NOT NULL,
                acknowledged INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE clipboard_sync_chunks (
                record_id TEXT NOT NULL REFERENCES clipboard_sync_outbox(record_id) ON DELETE CASCADE,
                chunk_index INTEGER NOT NULL, ciphertext BLOB NOT NULL,
                PRIMARY KEY(record_id, chunk_index)
            ) WITHOUT ROWID;
            CREATE TABLE clipboard_sync_inbox (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, record_id TEXT NOT NULL,
                PRIMARY KEY(account_id, epoch, record_id)
            ) WITHOUT ROWID;
            """)
    }

    func syncSettings(in database: Database) throws -> (enabled: Bool, accountID: String?) {
        guard let row = try Row.fetchOne(database, sql: "SELECT enabled, account_id FROM clipboard_sync_settings WHERE id = 1") else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        return (row["enabled"], row["account_id"])
    }

    func syncAccountState(_ account: ClipboardSyncAccount, in database: Database) throws -> ClipboardSyncAccountState {
        guard let data = try Data.fetchOne(database, sql: "SELECT state FROM clipboard_sync_accounts WHERE id = ?",
                                          arguments: [account.identifier]) else {
            return ClipboardSyncAccountState(account: account)
        }
        return try JSONDecoder().decode(ClipboardSyncAccountState.self, from: data)
    }

    func saveSyncAccount(_ state: ClipboardSyncAccountState, in database: Database) throws {
        try database.execute(sql: """
            INSERT INTO clipboard_sync_accounts(id, state) VALUES (?, ?)
            ON CONFLICT(id) DO UPDATE SET state = excluded.state
            """, arguments: [state.account.identifier, try JSONEncoder().encode(state)])
    }

    func selectedSyncTags(accountID: String, in database: Database) throws -> [ClipboardSyncTagContent] {
        try Row.fetchAll(database, sql: """
            SELECT definition.id, definition.display_name
            FROM clipboard_sync_tags AS selected
            JOIN clipboard_tag_definitions AS definition ON definition.id = selected.tag_id
            WHERE selected.account_id = ? AND selected.selected = 1
            ORDER BY definition.id
            """, arguments: [accountID]).map { ClipboardSyncTagContent(id: $0["id"], name: $0["display_name"]) }
    }

    func stageSyncBackfill(account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data) throws {
        let pool = try requiredDatabase()
        try pool.write { database in
            try stageSyncDeletions(account: account, control: control, key: key, in: database)
            try stageSyncTagDefinitions(account: account, control: control, key: key, in: database)
            try stageSyncMemberships(account: account, control: control, key: key, in: database)
            let tags = try selectedSyncTags(accountID: account.identifier, in: database)
            guard !tags.isEmpty else { return }
            let rows = try Row.fetchCursor(database, sql: """
                SELECT entry.id
                FROM clipboard_entries AS entry
                WHERE \(Self.syncEntryEligibility)
                  AND EXISTS (SELECT 1 FROM clipboard_entry_tags AS membership
                              JOIN clipboard_sync_tags AS selected ON selected.tag_id = membership.tag_id
                              WHERE membership.entry_id = entry.id AND selected.account_id = ? AND selected.selected = 1
                                AND (selected.locally_authorized = 1 OR NOT EXISTS (
                                    SELECT 1 FROM clipboard_sync_entries AS former
                                    WHERE former.local_entry_id = entry.id AND former.account_id != selected.account_id)))
                  AND NOT EXISTS (SELECT 1 FROM clipboard_sync_entries AS shared
                                  WHERE shared.account_id = ? AND shared.epoch = ? AND shared.local_entry_id = entry.id)
                ORDER BY entry.id
                """, arguments: [account.identifier, account.identifier, control.epoch.uuidString])
            while let row = try rows.next() {
                let localID: String = row["id"]
                guard let id = UUID(uuidString: localID) else { throw ClipboardSyncServiceError.corruptData }
                let memberships = Set(try String.fetchAll(database,
                    sql: "SELECT tag_id FROM clipboard_entry_tags WHERE entry_id = ?", arguments: [localID]))
                let content = try syncEntryContent(id: id, tags: tags.filter { memberships.contains($0.id) },
                    account: account, control: control, key: key, in: database)
                let upload = try ClipboardSyncCodec.seal(.entry(content), account: account, control: control, key: key)
                try storeSyncUpload(upload, subjectID: localID, account: account, in: database)
                try database.execute(sql: """
                    INSERT INTO clipboard_sync_entries(account_id, epoch, shared_id, local_entry_id, record_id, origin)
                    VALUES (?, ?, ?, ?, ?, 'local')
                    """, arguments: [account.identifier, control.epoch.uuidString, id.uuidString.lowercased(), localID, upload.record.recordID])
                try Self.registerSyncTextRoot(content, record: upload.record, account: account, in: database)
                try seedSyncMemberships(content.tags, sharedID: id.uuidString.lowercased(), localID: localID,
                    account: account, epoch: control.epoch, in: database)
            }
            try stageSyncTextEdits(account: account, control: control, key: key, in: database)
        }
    }

    func storeSyncUpload(_ upload: ClipboardSyncUpload, subjectID: String,
                                 account: ClipboardSyncAccount, in database: Database) throws {
        try database.execute(sql: """
            INSERT INTO clipboard_sync_outbox(record_id, account_id, epoch, subject_id, kind, metadata)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [upload.record.recordID, account.identifier, upload.record.epoch.uuidString,
                               subjectID, upload.record.kind.rawValue, try JSONEncoder().encode(upload.record)])
        for (index, chunk) in upload.chunks.enumerated() {
            try database.execute(sql: "INSERT INTO clipboard_sync_chunks(record_id, chunk_index, ciphertext) VALUES (?, ?, ?)",
                arguments: [upload.record.recordID, index, chunk])
        }
    }

    func nextSyncUpload(account: ClipboardSyncAccount, control: ClipboardSyncControl) throws -> ClipboardSyncUpload? {
        try requiredDatabase().read { database in
            guard let row = try Row.fetchOne(database, sql: """
                SELECT record_id, metadata FROM clipboard_sync_outbox
                WHERE account_id = ? AND epoch = ? AND acknowledged = 0
                ORDER BY CASE kind WHEN 'tag' THEN 0 ELSE 1 END, rowid LIMIT 1
                """, arguments: [account.identifier, control.epoch.uuidString]) else { return nil }
            let id: String = row["record_id"]
            let metadata: Data = row["metadata"]
            let chunks = try Data.fetchAll(database,
                sql: "SELECT ciphertext FROM clipboard_sync_chunks WHERE record_id = ? ORDER BY chunk_index", arguments: [id])
            return ClipboardSyncUpload(record: try JSONDecoder().decode(ClipboardSyncRemoteRecord.self, from: metadata), chunks: chunks)
        }
    }

    func hasReceivedSyncRecord(_ record: ClipboardSyncRemoteRecord, account: ClipboardSyncAccount) throws -> Bool {
        try requiredDatabase().read { database in
            if try Self.needsSyncTextRootReplay(accountID: account.identifier, epoch: record.epoch.uuidString,
                recordID: record.recordID, in: database) { return false }
            return try Bool.fetchOne(database, sql: """
                SELECT EXISTS (SELECT 1 FROM clipboard_sync_inbox WHERE account_id = ? AND epoch = ? AND record_id = ?)
                    OR EXISTS (SELECT 1 FROM clipboard_sync_outbox WHERE account_id = ? AND record_id = ?)
                """, arguments: [account.identifier, record.epoch.uuidString, record.recordID, account.identifier, record.recordID]) ?? false
        }
    }

    func importSyncContent(_ content: ClipboardSyncContent, record: ClipboardSyncRemoteRecord,
                           account: ClipboardSyncAccount) throws {
        let pool = try requiredDatabase()
        let preparedEntry: ClipboardSyncPreparedEntry?
        if case .entry(let entry) = content,
           try pool.read({ try String.fetchOne($0, sql: """
               SELECT local_entry_id FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ? AND shared_id = ?
               """, arguments: [account.identifier, record.epoch.uuidString, entry.id.uuidString.lowercased()]) }) == nil {
            preparedEntry = try prepareSyncEntryContent(entry)
        } else { preparedEntry = nil }
        let changed = try pool.write { database in
            let exists = try Bool.fetchOne(database, sql: """
                SELECT EXISTS (SELECT 1 FROM clipboard_sync_inbox WHERE account_id = ? AND epoch = ? AND record_id = ?)
                """, arguments: [account.identifier, record.epoch.uuidString, record.recordID]) ?? false
            let recoversRoot = try Self.needsSyncTextRootReplay(accountID: account.identifier,
                epoch: record.epoch.uuidString, recordID: record.recordID, in: database)
            guard !exists || recoversRoot else { return false }
            try recordLocalSyncTags(accountID: account.identifier, in: database)
            try recordLocalSyncMemberships(account: account, epoch: record.epoch, in: database)
            if let subject = content.entrySubjectID,
               try Self.isSyncDeleted(subject, accountID: account.identifier, epoch: record.epoch.uuidString, in: database) {
                try database.execute(sql: "INSERT OR IGNORE INTO clipboard_sync_inbox(account_id, epoch, record_id) VALUES (?, ?, ?)",
                    arguments: [account.identifier, record.epoch.uuidString, record.recordID])
                return false
            }
            switch content {
            case .deletion(let deletion):
                try receiveSyncDeletion(deletion, record: record, account: account, in: database)
            case .tag(let tag):
                try importSyncTag(tag, account: account, recordID: record.recordID, in: database)
            case .text(let text):
                try importSyncText(text, account: account, record: record, in: database)
                try Self.registerSyncTextRoot(text, record: record, account: account, in: database)
                try reconcileSyncTextVersions(subjectID: text.id.uuidString.lowercased(), accountID: account.identifier,
                    epoch: record.epoch.uuidString, in: database)
            case .textEdit(let edit):
                try Self.receiveSyncTextEdit(edit, record: record, account: account, in: database)
                try reconcileSyncTextVersions(subjectID: edit.id.uuidString.lowercased(), accountID: account.identifier,
                    epoch: record.epoch.uuidString, in: database)
            case .entry(let entry):
                try importSyncEntryContent(entry, account: account, record: record, prepared: preparedEntry, in: database)
                try Self.registerSyncTextRoot(entry, record: record, account: account, in: database)
                try reconcileSyncTextVersions(subjectID: entry.id.uuidString.lowercased(), accountID: account.identifier,
                    epoch: record.epoch.uuidString, in: database)
            case .tagMembership(let membership):
                try importSyncMembership(membership, account: account, epoch: record.epoch, in: database)
            case .tagState(let state):
                try importSyncTagState(state, account: account, record: record, in: database)
            case .fileBody:
                throw ClipboardSyncServiceError.unsupportedVersion
            }
            try database.execute(sql: "INSERT OR IGNORE INTO clipboard_sync_inbox(account_id, epoch, record_id) VALUES (?, ?, ?)",
                arguments: [account.identifier, record.epoch.uuidString, record.recordID])
            try Self.bumpHistoryRevision(in: database)
            try Self.bumpSearchIndexGeneration(in: database)
            try faultInjector.check(.databaseTransaction)
            return true
        }
        if changed { publishMutation() }
    }

    func importSyncTag(_ tag: ClipboardSyncTagContent, account: ClipboardSyncAccount,
                               recordID: String, in database: Database) throws {
        guard !tag.id.isEmpty, !tag.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClipboardSyncServiceError.corruptData
        }
        // An initial snapshot cannot undo a later rename or selection change.
        if try syncTagState(id: tag.id, accountID: account.identifier, in: database) != nil { return }
        // Names never establish identity. Do not replace the whole local tag list.
        try database.execute(sql: """
            INSERT INTO clipboard_tag_definitions(id, display_name, display_order)
            VALUES (?, ?, COALESCE((SELECT MAX(display_order) + 1 FROM clipboard_tag_definitions), 0))
            ON CONFLICT(id) DO NOTHING
            """, arguments: [tag.id, tag.name])
        try database.execute(sql: """
            INSERT INTO clipboard_sync_tags(account_id, tag_id, selected, record_id) VALUES (?, ?, 1, ?)
            ON CONFLICT(account_id, tag_id) DO UPDATE SET record_id = COALESCE(clipboard_sync_tags.record_id, excluded.record_id)
            """, arguments: [account.identifier, tag.id, recordID])
        try saveSyncTagState(.init(id: tag.id, name: tag.name, selected: true, revision: .initial),
            accountID: account.identifier, pending: false, in: database)
    }

    private func importSyncText(_ text: ClipboardSyncTextContent, account: ClipboardSyncAccount,
                                record: ClipboardSyncRemoteRecord, in database: Database) throws {
        guard !text.text.isEmpty, text.text.utf8.count <= PasteboardSnapshot.maximumByteCount,
              !text.tags.isEmpty, ClipboardHistoryCaptureSourceProvenance(rawValue: text.sourceProvenance) != nil else {
            throw ClipboardSyncServiceError.corruptData
        }
        let sharedID = text.id.uuidString.lowercased()
        let existing = try String.fetchOne(database, sql: """
            SELECT local_entry_id FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ? AND shared_id = ?
            """, arguments: [account.identifier, record.epoch.uuidString, sharedID])
        // Updates are a subsequent vertical slice. Redelivery never recaptures.
        guard existing == nil else { return }
        var localID = sharedID
        if try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM clipboard_entries WHERE id = ?)", arguments: [localID]) == true {
            localID = UUID().uuidString.lowercased()
        }
        for tag in text.tags { try importSyncTag(tag, account: account, recordID: record.recordID, in: database) }
        try database.execute(sql: """
            INSERT INTO clipboard_entries(id, captured_at, last_captured_at, source_bundle_id,
                source_display_name, source_provenance, preview_text, is_favorite)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [localID, text.capturedAt.timeIntervalSince1970, text.capturedAt.timeIntervalSince1970,
                text.sourceBundleID, text.sourceDisplayName, text.sourceProvenance, Self.boundedPreviewText(text.text), text.favorite])
        try database.execute(sql: "INSERT INTO clipboard_items(entry_id, item_index) VALUES (?, 0)", arguments: [localID])
        try database.execute(sql: """
            INSERT INTO clipboard_representations(entry_id, item_index, representation_index, kind, type_identifier, text_value)
            VALUES (?, 0, 0, 'text', 'public.utf8-plain-text', ?)
            """, arguments: [localID, text.text])
        try database.execute(sql: "INSERT INTO clipboard_entry_facets(entry_id, facet) VALUES (?, 'text')", arguments: [localID])
        for tag in text.tags {
            try database.execute(sql: "INSERT INTO clipboard_entry_tags(entry_id, tag_id) VALUES (?, ?)", arguments: [localID, tag.id])
        }
        try database.execute(sql: "INSERT INTO clipboard_retention_state(entry_id, retention_started_at, is_protected) VALUES (?, ?, 1)",
            arguments: [localID, text.capturedAt.timeIntervalSince1970])
        try Self.insertSearchField(value: text.text, kind: "exactText", index: 0,
            rankingGroup: Self.searchRankingGroup(for: "exactText"), entryID: localID, into: database, faultInjector: faultInjector)
        let identity = try CanonicalIdentity(snapshot: PasteboardSnapshot(items: [
            PasteboardSnapshot.Item(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: text.text)])
        ], extraFacets: [], allowsTextInference: true), fingerprintDigest: fingerprintDigest)
        try database.execute(sql: """
            INSERT INTO clipboard_duplicate_candidates(fingerprint, entry_id, canonical_byte_count, created_at) VALUES (?, ?, ?, ?)
            """, arguments: [identity.fingerprint, localID, identity.canonicalByteCount, text.capturedAt.timeIntervalSince1970])
        try database.execute(sql: """
            INSERT INTO clipboard_sync_entries(account_id, epoch, shared_id, local_entry_id, record_id, origin)
            VALUES (?, ?, ?, ?, ?, 'remote')
            """, arguments: [account.identifier, record.epoch.uuidString, sharedID, localID, record.recordID])
        try seedSyncMemberships(text.tags, sharedID: sharedID, localID: localID,
            account: account, epoch: record.epoch, in: database)
    }
}
