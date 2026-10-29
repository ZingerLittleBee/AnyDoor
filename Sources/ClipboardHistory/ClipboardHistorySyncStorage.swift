import Foundation
import GRDB

struct ClipboardSyncAccountState: Codable, Sendable {
    let account: ClipboardSyncAccount
    var control: ClipboardSyncControl?
    var candidate: ClipboardSyncControl?
    var cursor: Data?
    var lastCompletedAt: Date?
    var missingControl: Bool?
    var retiredEpochs: Set<UUID>?
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

    func stageSyncBackfill(account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data,
        generation: UInt64) async throws -> Int64 {
        let revision = try syncFileRead { try Self.historyRevision(in: $0) }
        try await recordSyncStagingState(account: account, control: control, generation: generation)
        try await stageSyncDeletions(account: account, control: control, key: key, generation: generation)
        try await stageSyncWithdrawals(account: account, control: control, key: key, generation: generation)
        try await stageSyncTagMerges(account: account, control: control, key: key, generation: generation)
        try await stageSyncTagDefinitions(account: account, control: control, key: key, generation: generation)
        try await stageSyncMemberships(account: account, control: control, key: key, generation: generation)
        try await stageSyncMetadata(account: account, control: control, key: key, generation: generation)
        let store = try requiredPayloadStore()
        var afterID = ""
        while true {
            try admitSync(generation)
            let next = try syncFileRead { database -> (String, Int64, ClipboardSyncEntrySnapshot)? in
                guard let localID = try String.fetchOne(database, SQLRequest<String>(literal: """
                    SELECT entry.id FROM clipboard_entries AS entry
                    WHERE entry.id > \(afterID) AND \(sql: Self.syncEntryEligibility)
                      AND (\(Self.syncEntryPublicationAuthority(accountID: account.identifier)))
                      AND NOT EXISTS (SELECT 1 FROM clipboard_sync_entries AS shared
                        WHERE shared.account_id = \(account.identifier) AND shared.epoch = \(control.epoch.uuidString)
                          AND shared.local_entry_id = entry.id)
                    ORDER BY entry.id LIMIT 1
                    """)) else { return nil }
                guard let id = UUID(uuidString: localID) else { throw ClipboardSyncServiceError.corruptData }
                let tags = try selectedSyncTags(accountID: account.identifier, in: database)
                let memberships = Set(try String.fetchAll(database,
                    sql: "SELECT tag_id FROM clipboard_entry_tags WHERE entry_id = ?", arguments: [localID]))
                // Retained local copies may need a new cloud identity.
                let identityInUse = try Bool.fetchOne(database, sql: """
                    SELECT EXISTS(SELECT 1 FROM clipboard_sync_entries
                    WHERE account_id = ? AND epoch = ? AND shared_id = ?)
                    """, arguments: [account.identifier, control.epoch.uuidString, localID]) == true
                let snapshot = try syncEntrySnapshot(id: id, sharedID: identityInUse ? UUID() : id,
                    tags: tags.filter { memberships.contains($0.id) }, account: account, control: control, key: key, in: database)
                return (localID, try Self.historyRevision(in: database), snapshot)
            }
            guard let (localID, snapshotRevision, snapshot) = next else { break }
            afterID = localID
            let preparation = Task.detached(priority: .utility) {
                let content = try snapshot.materialize(using: store)
                try Task.checkCancellation()
                let upload = try ClipboardSyncCodec.seal(.entry(content), account: account, control: control, key: key)
                return (content, upload)
            }
            let content: ClipboardSyncEntryContent
            let upload: ClipboardSyncUpload
            do {
                (content, upload) = try await withTaskCancellationHandler { try await preparation.value }
                    onCancel: { preparation.cancel() }
            } catch {
                try admitSync(generation)
                // Deletion/edit may reclaim a captured payload while preparation
                // runs. Its stale snapshot is no longer a storage failure.
                if try syncFileRead({ try Self.historyRevision(in: $0) }) != snapshotRevision { continue }
                throw error
            }
            try await waitForWriteTurn()
            try admitSync(generation)
            try syncWrite { database in
                guard try Self.historyRevision(in: database) == snapshotRevision,
                      let context = try syncFileContext(in: database), context.account == account,
                      context.control.epoch == control.epoch, context.control.keyID == control.keyID,
                      context.control.phase == "active" else { return }
                guard try Bool.fetchOne(database, SQLRequest<Bool>(literal: """
                    SELECT EXISTS(SELECT 1 FROM clipboard_entries AS entry
                    WHERE entry.id = \(localID) AND \(sql: Self.syncEntryEligibility)
                      AND (\(Self.syncEntryPublicationAuthority(accountID: account.identifier)))
                      AND NOT EXISTS (SELECT 1 FROM clipboard_sync_entries AS shared
                        WHERE shared.account_id = \(account.identifier) AND shared.epoch = \(control.epoch.uuidString)
                          AND shared.local_entry_id = entry.id))
                    """)) == true else { return }
                let sharedID = content.id.uuidString.lowercased()
                try storeSyncUpload(upload, subjectID: sharedID, account: account, in: database)
                try database.execute(sql: """
                    INSERT INTO clipboard_sync_entries(account_id, epoch, shared_id, local_entry_id, record_id, origin)
                    VALUES (?, ?, ?, ?, ?, 'local')
                    """, arguments: [account.identifier, control.epoch.uuidString, sharedID, localID, upload.record.recordID])
                try Self.rememberSyncFileOwnership(sharedID: sharedID, accountID: account.identifier,
                    epoch: control.epoch.uuidString, in: database)
                try Self.registerSyncTextRoot(content, record: upload.record, account: account, in: database)
                try seedSyncMemberships(content.tags, sharedID: sharedID, localID: localID,
                    account: account, epoch: control.epoch, in: database)
                try seedSyncEntryMetadata(content, account: account, record: upload.record, in: database)
            }
        }
        try admitSync(generation)
        try await stageSyncTextEdits(account: account, control: control, key: key, generation: generation)
        // Concurrent intent is deliberately not covered by this pass's witness.
        return revision
    }

    func syncStagingContextMatches(account: ClipboardSyncAccount, control: ClipboardSyncControl,
        in database: Database) throws -> Bool {
        guard let context = try syncFileContext(in: database) else { return false }
        return context.account == account && context.control.epoch == control.epoch
            && context.control.keyID == control.keyID && context.control.phase == "active"
    }

    func storeSyncUpload(_ upload: ClipboardSyncUpload, subjectID: String,
                                 account: ClipboardSyncAccount, in database: Database) throws {
        try database.execute(sql: """
            INSERT INTO clipboard_sync_outbox(record_id, account_id, epoch, subject_id, kind, metadata)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [upload.record.recordID, account.identifier, upload.record.epoch.uuidString,
                               subjectID, upload.record.kind.rawValue, try JSONEncoder().encode(upload.record)])
        if upload.record.kind == .entry,
           try !Self.isSyncDeleted(subjectID, accountID: account.identifier, epoch: upload.record.epoch.uuidString, in: database) {
            try Self.rememberSyncContentRecord(upload.record, subjectID: subjectID, accountID: account.identifier, in: database)
        }
        for (index, chunk) in upload.chunks.enumerated() {
            try database.execute(sql: "INSERT INTO clipboard_sync_chunks(record_id, chunk_index, ciphertext) VALUES (?, ?, ?)",
                arguments: [upload.record.recordID, index, chunk])
        }
    }

    func nextSyncUpload(account: ClipboardSyncAccount, control: ClipboardSyncControl) throws -> ClipboardSyncPendingUpload? {
        try requiredDatabase().read { database in
            guard let row = try Row.fetchOne(database, SQLRequest<Row>(literal: """
                SELECT record_id, metadata FROM clipboard_sync_outbox AS outbox
                WHERE account_id = \(account.identifier) AND epoch = \(control.epoch.uuidString) AND acknowledged = 0
                  AND (\(Self.syncFileOutboxAuthority(accountID: account.identifier)))
                ORDER BY CASE kind WHEN 'tag' THEN 0 ELSE 1 END, rowid LIMIT 1
                """)) else { return nil }
            let id: String = row["record_id"]
            let metadata: Data = row["metadata"]
            let record = try JSONDecoder().decode(ClipboardSyncRemoteRecord.self, from: metadata)
            if let directory = try String.fetchOne(database,
                sql: "SELECT directory FROM clipboard_sync_file_uploads WHERE record_id = ?", arguments: [id]) {
                return .file(.init(record: record, directory: URL(fileURLWithPath: directory)))
            }
            let chunks = try Data.fetchAll(database,
                sql: "SELECT ciphertext FROM clipboard_sync_chunks WHERE record_id = ? ORDER BY chunk_index", arguments: [id])
            return .inline(ClipboardSyncUpload(record: record, chunks: chunks))
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
        let initialEntry: ClipboardSyncEntryContent?
        switch content {
        case .entry(let entry): initialEntry = entry
        case .rejoin(let value): initialEntry = value.entry
        default: initialEntry = nil
        }
        let preparedEntry: ClipboardSyncPreparedEntry?
        if let entry = initialEntry,
           try pool.read({ try String.fetchOne($0, sql: """
               SELECT local_entry_id FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ? AND shared_id = ?
               """, arguments: [account.identifier, record.epoch.uuidString, entry.id.uuidString.lowercased()]) }) == nil {
            preparedEntry = try prepareSyncEntryContent(entry)
        } else { preparedEntry = nil }
        let changed = try pool.write { database in
            // Receipt and retry retirement commit together. A crash cannot leave
            // a retry that future discovery skips because its inbox receipt won.
            try database.execute(sql: """
                DELETE FROM clipboard_sync_file_retries WHERE account_id = ? AND epoch = ? AND work_id = ?
                """, arguments: [account.identifier, record.epoch.uuidString,
                    ClipboardSyncFileWork.content(record.operationID).identifier])
            let exists = try Bool.fetchOne(database, sql: """
                SELECT EXISTS (SELECT 1 FROM clipboard_sync_inbox WHERE account_id = ? AND epoch = ? AND record_id = ?)
                """, arguments: [account.identifier, record.epoch.uuidString, record.recordID]) ?? false
            let recoversRoot = try Self.needsSyncTextRootReplay(accountID: account.identifier,
                epoch: record.epoch.uuidString, recordID: record.recordID, in: database)
            guard !exists || recoversRoot else { return false }
            try recordLocalSyncTags(accountID: account.identifier, in: database)
            try recordLocalSyncMemberships(before: content, account: account, epoch: record.epoch, in: database)
            if try rememberReceivedSyncFileContent(content, record: record, account: account, in: database) {
                try database.execute(sql: "INSERT OR IGNORE INTO clipboard_sync_inbox(account_id, epoch, record_id) VALUES (?, ?, ?)",
                    arguments: [account.identifier, record.epoch.uuidString, record.recordID])
                return false
            }
            if let subject = content.entrySubjectID {
                try Self.rememberSyncContentRecord(record, subjectID: subject, accountID: account.identifier, in: database)
            }
            let resumesSubject: Bool
            if case .rejoin = content { resumesSubject = true } else { resumesSubject = false }
            let removesMembership: Bool
            if case .tagMembership(let membership) = content { removesMembership = !membership.present }
            else { removesMembership = false }
            if let subject = content.entrySubjectID,
               try Self.isSyncDeleted(subject, accountID: account.identifier, epoch: record.epoch.uuidString, in: database)
                || (!removesMembership && !resumesSubject && Self.isSyncWithdrawn(subject, accountID: account.identifier, epoch: record.epoch.uuidString, in: database)) {
                if try !Self.isSyncDeleted(subject, accountID: account.identifier, epoch: record.epoch.uuidString, in: database),
                   try Self.hasUnpublishedSyncWithdrawal(subject, accountID: account.identifier, epoch: record.epoch.uuidString, in: database) {
                    // Retain accepted peer state without changing the withdrawn
                    // local copy or authorizing its publication.
                    switch content {
                    case .textEdit(let edit):
                        try Self.receiveSyncTextEdit(edit, record: record, account: account, in: database)
                    case .metadata(let metadata):
                        try importSyncMetadata(metadata, account: account, record: record, applying: false, in: database)
                    default: break
                    }
                }
                try database.execute(sql: "INSERT OR IGNORE INTO clipboard_sync_inbox(account_id, epoch, record_id) VALUES (?, ?, ?)",
                    arguments: [account.identifier, record.epoch.uuidString, record.recordID])
                return false
            }
            switch content {
            case .rejoin(let value):
                try importSyncRejoin(value, account: account, record: record, prepared: preparedEntry, in: database)
            case .withdrawal(let value):
                try saveSyncWithdrawal(value, accountID: account.identifier, epoch: record.epoch.uuidString,
                    recordID: record.recordID, pending: false, in: database)
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
            case .metadata(let metadata):
                try importSyncMetadata(metadata, account: account, record: record, in: database)
            case .fileBody:
                throw ClipboardSyncServiceError.unsupportedVersion
            case .fileVersion(let version):
                try importSyncFileVersion(version, account: account, record: record, in: database)
            case .tagMerge(let merge):
                try applySyncTagMerge(merge, accountID: account.identifier, locallyConfirmed: false, in: database)
                try applyAllSyncMemberships(account: account, epoch: record.epoch, in: database)
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
        guard try canonicalSyncTagID(tag.id, accountID: account.identifier, in: database) == tag.id else { return }
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
        guard !text.text.isEmpty else { throw ClipboardSyncServiceError.corruptData }
        try importSyncEntryContent(.init(id: text.id, capturedAt: text.capturedAt,
            sourceBundleID: text.sourceBundleID, sourceDisplayName: text.sourceDisplayName,
            sourceProvenance: text.sourceProvenance, favorite: text.favorite, tags: text.tags,
            items: [.init(representations: [.text(typeIdentifier: "public.utf8-plain-text", value: text.text)])],
            facets: ["text"], recognition: .init()), account: account, record: record, in: database)
    }
}
