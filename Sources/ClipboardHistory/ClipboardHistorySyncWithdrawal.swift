import Foundation
import GRDB

struct ClipboardSyncWithdrawal: Codable, Equatable, Sendable {
    let sharedID: String
    let withdrawn: Bool
    let revision: ClipboardSyncTagRevision
}

struct ClipboardSyncRejoin: Codable, Equatable, Sendable {
    let state: ClipboardSyncWithdrawal
    let entry: ClipboardSyncEntryContent
    let initialRecordID: String
    let versions: [ClipboardSyncTextEditContent]
    let selectedVersionID: UUID?
    let metadata: [ClipboardSyncMetadataContent]?
    let memberships: [ClipboardSyncTagMembership]?
    let fileVersions: [ClipboardSyncFileVersionContent]?
}

extension ClipboardHistoryModule {
    static func createSyncWithdrawalSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_withdrawals (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, shared_id TEXT NOT NULL,
                withdrawn INTEGER NOT NULL, counter INTEGER NOT NULL, operation_id TEXT NOT NULL,
                pending INTEGER NOT NULL, record_id TEXT, origin TEXT NOT NULL,
                PRIMARY KEY(account_id, epoch, shared_id)
            ) WITHOUT ROWID;
            """)
    }

    static func isSyncWithdrawn(_ sharedID: String, accountID: String, epoch: String, in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: """
            SELECT withdrawn FROM clipboard_sync_withdrawals WHERE account_id = ? AND epoch = ? AND shared_id = ?
            """, arguments: [accountID, epoch, sharedID]) ?? false
    }

    /// Losing sharing eligibility does not delete the local copy or its tags.
    /// The durable marker, rather than absence of a cloud record, fences replay.
    func recordSyncWithdrawals(in database: Database) throws {
        guard let accountID = try syncSettings(in: database).accountID else { return }
        for row in try Row.fetchAll(database, sql: """
            SELECT shared.epoch, shared.shared_id FROM clipboard_sync_entries AS shared
            JOIN clipboard_entries AS entry ON entry.id = shared.local_entry_id
            WHERE shared.account_id = ? AND NOT EXISTS (
                SELECT 1 FROM clipboard_entry_tags AS membership
                JOIN clipboard_sync_tags AS selected ON selected.tag_id = membership.tag_id
                WHERE membership.entry_id = shared.local_entry_id AND selected.account_id = shared.account_id AND selected.selected = 1)
            """, arguments: [accountID]) {
            let sharedID: String = row["shared_id"]
            let epoch: String = row["epoch"]
            guard try !Self.isSyncWithdrawn(sharedID, accountID: accountID, epoch: epoch, in: database),
                  try !Self.isSyncDeleted(sharedID, accountID: accountID, epoch: epoch, in: database) else { continue }
            try saveSyncWithdrawal(.init(sharedID: sharedID, withdrawn: true, revision: nextSyncTagRevision(in: database)),
                accountID: accountID, epoch: epoch, recordID: nil, pending: true, in: database)
        }
    }

    func saveSyncWithdrawal(_ value: ClipboardSyncWithdrawal, accountID: String, epoch: String,
                            recordID: String?, pending: Bool, in database: Database) throws {
        guard UUID(uuidString: value.sharedID) != nil else { throw ClipboardSyncServiceError.corruptData }
        try observeSyncTagRevision(value.revision, in: database)
        guard try !Self.isSyncDeleted(value.sharedID, accountID: accountID, epoch: epoch, in: database) else { return }
        if let previous = try Row.fetchOne(database, sql: """
            SELECT counter, operation_id FROM clipboard_sync_withdrawals WHERE account_id = ? AND epoch = ? AND shared_id = ?
            """, arguments: [accountID, epoch, value.sharedID]),
           ClipboardSyncTagRevision(counter: previous["counter"], operationID: previous["operation_id"]) >= value.revision { return }
        try database.execute(sql: """
            INSERT INTO clipboard_sync_withdrawals(account_id, epoch, shared_id, withdrawn, counter, operation_id, pending, record_id, origin)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, epoch, shared_id) DO UPDATE SET withdrawn = excluded.withdrawn,
                counter = excluded.counter, operation_id = excluded.operation_id, pending = excluded.pending,
                record_id = excluded.record_id, origin = excluded.origin
            """, arguments: [accountID, epoch, value.sharedID, value.withdrawn, value.revision.counter,
                value.revision.operationID, pending, recordID, pending ? "local" : "remote"])
        if !value.withdrawn { try recordSyncFileRejoin(value, accountID: accountID, epoch: epoch, in: database) }
        if value.withdrawn {
            try Self.rememberSyncFileOwnership(sharedID: value.sharedID, accountID: accountID, epoch: epoch, in: database)
            // Cancel publication, but keep whether each local version was ever
            // acknowledged for later deletion-versus-offline-edit preservation.
            try database.execute(sql: """
                UPDATE clipboard_sync_versions SET record_id = NULL
                WHERE account_id = ? AND epoch = ? AND subject_id = ? AND origin = 'local'
                  AND record_id IN (SELECT record_id FROM clipboard_sync_outbox WHERE acknowledged = 0)
                """, arguments: [accountID, epoch, value.sharedID])
            try database.execute(sql: """
                DELETE FROM clipboard_sync_outbox WHERE account_id = ? AND epoch = ? AND subject_id = ?
                  AND kind = 'entry' AND acknowledged = 0
                """, arguments: [accountID, epoch, value.sharedID])
        }
    }

    func authorizeSyncRejoin(tagID: String, revision: ClipboardSyncTagRevision, localEntryID: String? = nil, in database: Database) throws {
        guard let accountID = try syncSettings(in: database).accountID else { return }
        let rows = try Row.fetchAll(database, SQLRequest<Row>(literal: """
            SELECT shared.shared_id, shared.epoch FROM clipboard_sync_entries AS shared
            JOIN clipboard_entries AS entry ON entry.id = shared.local_entry_id
            JOIN clipboard_sync_withdrawals AS withdrawal ON withdrawal.account_id = shared.account_id
                AND withdrawal.epoch = shared.epoch AND withdrawal.shared_id = shared.shared_id
            WHERE shared.account_id = \(accountID) AND withdrawal.withdrawn = 1
              AND (\(localEntryID) IS NULL OR entry.id = \(localEntryID))
              AND EXISTS (SELECT 1 FROM clipboard_entry_tags WHERE entry_id = entry.id AND tag_id = \(tagID))
              AND (\(Self.syncEntryPublicationAuthority(accountID: accountID, includingWithdrawn: true)))
            """))
        for row in rows {
            try saveSyncWithdrawal(.init(sharedID: row["shared_id"], withdrawn: false, revision: revision),
                accountID: accountID, epoch: row["epoch"], recordID: nil, pending: true, in: database)
        }
    }

    private func syncRejoinContent(_ state: ClipboardSyncWithdrawal, account: ClipboardSyncAccount,
                                  control: ClipboardSyncControl, key: Data, in database: Database) throws -> ClipboardSyncRejoin {
        guard let shared = try Row.fetchOne(database, sql: """
            SELECT local_entry_id, record_id FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ? AND shared_id = ?
            """, arguments: [account.identifier, control.epoch.uuidString, state.sharedID]),
              let localID = UUID(uuidString: shared["local_entry_id"]), let sharedID = UUID(uuidString: state.sharedID) else {
            throw ClipboardSyncServiceError.localStorage
        }
        let localTags = Set(try String.fetchAll(database, sql: "SELECT tag_id FROM clipboard_entry_tags WHERE entry_id = ?",
            arguments: [localID.uuidString.lowercased()]))
        let tags = try selectedSyncTags(accountID: account.identifier, in: database).filter { localTags.contains($0.id) }
        let entry = try syncEntryContent(id: localID, sharedID: sharedID, tags: tags, account: account, control: control, key: key, in: database)
        let versions = try Data.fetchAll(database, sql: """
            SELECT content FROM clipboard_sync_versions WHERE account_id = ? AND epoch = ? AND subject_id = ? ORDER BY version_id
            """, arguments: [account.identifier, control.epoch.uuidString, state.sharedID]).map {
                try JSONDecoder().decode(ClipboardSyncTextEditContent.self, from: $0)
            }
        let selection = try String.fetchOne(database, sql: """
            SELECT version_id FROM clipboard_sync_version_selections WHERE account_id = ? AND epoch = ? AND subject_id = ?
            """, arguments: [account.identifier, control.epoch.uuidString, state.sharedID]).flatMap(UUID.init(uuidString:))
        let metadata = try Data.fetchAll(database, sql: """
            SELECT value FROM clipboard_sync_metadata WHERE account_id = ? AND epoch = ? AND shared_id = ? ORDER BY field
            """, arguments: [account.identifier, control.epoch.uuidString, state.sharedID]).map {
                try JSONDecoder().decode(ClipboardSyncMetadataContent.self, from: $0)
            }
        let memberships = try Row.fetchAll(database, sql: """
            SELECT membership.* FROM clipboard_sync_memberships AS membership
            JOIN clipboard_sync_tags AS tag ON tag.account_id = membership.account_id AND tag.tag_id = membership.tag_id
            WHERE membership.account_id = ? AND membership.epoch = ? AND membership.shared_id = ? AND tag.selected = 1
            """, arguments: [account.identifier, control.epoch.uuidString, state.sharedID]).map {
                ClipboardSyncTagMembership(sharedID: $0["shared_id"], tagID: $0["tag_id"], present: $0["present"],
                    revision: .init(counter: $0["counter"], operationID: $0["operation_id"]))
            }
        return ClipboardSyncRejoin(state: state, entry: entry, initialRecordID: shared["record_id"], versions: versions, selectedVersionID: selection, metadata: metadata, memberships: memberships,
            fileVersions: try syncFileRejoinVersions(entryID: localID.uuidString.lowercased(), account: account, control: control, in: database))
    }

    func importSyncRejoin(_ value: ClipboardSyncRejoin, account: ClipboardSyncAccount,
                          record: ClipboardSyncRemoteRecord, prepared: ClipboardSyncPreparedEntry?, in database: Database) throws {
        guard !value.state.withdrawn, value.state.sharedID == value.entry.id.uuidString.lowercased(),
              value.initialRecordID.hasPrefix("v1-"), UUID(uuidString: String(value.initialRecordID.dropFirst(3))) != nil,
              (value.memberships ?? []).allSatisfy({ $0.sharedID == value.state.sharedID }),
              (value.metadata ?? []).allSatisfy({ $0.id == value.entry.id }),
              Set((value.metadata ?? []).map { $0.value.field }).count == (value.metadata ?? []).count,
              Set(value.versions.map(\.versionID)).count == value.versions.count,
              value.versions.allSatisfy({ $0.id == value.entry.id && !$0.parents.contains($0.versionID)
                  && Set($0.parents).count == $0.parents.count && $0.editedAt.timeIntervalSince1970.isFinite
                  && !$0.text.isEmpty && $0.text.utf8.count <= PasteboardSnapshot.maximumByteCount }) else {
            throw ClipboardSyncServiceError.corruptData
        }
        try saveSyncWithdrawal(value.state, accountID: account.identifier, epoch: record.epoch.uuidString,
            recordID: record.recordID, pending: false, in: database)
        guard try !Self.isSyncWithdrawn(value.state.sharedID, accountID: account.identifier, epoch: record.epoch.uuidString, in: database) else { return }
        let existed = try Bool.fetchOne(database, sql: """
            SELECT EXISTS (SELECT 1 FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ? AND shared_id = ?)
            """, arguments: [account.identifier, record.epoch.uuidString, value.state.sharedID]) ?? false
        let fileParents = try importSyncFileRejoinVersions(value.fileVersions, entry: value.entry,
            account: account, record: record, in: database)
        try importSyncEntryContent(value.entry, account: account, record: record, prepared: prepared,
            initialRecordID: value.initialRecordID, fileParents: fileParents, in: database)
        for membership in value.memberships ?? [] where membership.revision != .initial {
            try importSyncMembership(membership, account: account, epoch: record.epoch, in: database)
        }
        for metadata in value.metadata ?? [] {
            try importSyncMetadata(metadata, account: account, record: record, fromCheckpoint: true, in: database)
        }
        for version in value.versions {
            try Self.saveSyncTextVersion(version, accountID: account.identifier, epoch: record.epoch.uuidString,
                origin: version.parents.isEmpty ? "root" : "remote",
                recordID: version.parents.isEmpty ? value.initialRecordID : record.recordID, in: database)
        }
        if !existed, let selected = value.selectedVersionID, value.versions.contains(where: { $0.versionID == selected }) {
            try Self.selectSyncVersion(selected, subjectID: value.state.sharedID, accountID: account.identifier, epoch: record.epoch.uuidString, in: database)
        }
        try reconcileSyncTextVersions(subjectID: value.state.sharedID, accountID: account.identifier, epoch: record.epoch.uuidString, in: database)
    }

    func stageSyncWithdrawals(account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data, in database: Database) throws {
        try recordLocalSyncMemberships(account: account, epoch: control.epoch, in: database)
        for row in try Row.fetchAll(database, sql: "SELECT * FROM clipboard_sync_withdrawals WHERE account_id = ? AND epoch = ? AND pending = 1",
            arguments: [account.identifier, control.epoch.uuidString]) {
            let value = ClipboardSyncWithdrawal(sharedID: row["shared_id"], withdrawn: row["withdrawn"],
                revision: .init(counter: row["counter"], operationID: row["operation_id"]))
            let content: ClipboardSyncContent = value.withdrawn ? .withdrawal(value)
                : .rejoin(try syncRejoinContent(value, account: account, control: control, key: key, in: database))
            let upload = try ClipboardSyncCodec.seal(content, account: account, control: control, key: key)
            try storeSyncUpload(upload, subjectID: value.sharedID, account: account, in: database)
            try database.execute(sql: """
                UPDATE clipboard_sync_withdrawals SET pending = 0, record_id = ? WHERE account_id = ? AND epoch = ? AND shared_id = ?
                """, arguments: [upload.record.recordID, account.identifier, control.epoch.uuidString, value.sharedID])
        }
    }
}
