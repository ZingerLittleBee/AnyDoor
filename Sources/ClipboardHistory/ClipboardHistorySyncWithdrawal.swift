import Foundation
import GRDB

struct ClipboardSyncWithdrawal: Codable, Equatable, Sendable {
    let sharedID: String
    let withdrawn: Bool
    let revision: ClipboardSyncTagRevision
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
        if value.withdrawn {
            try database.execute(sql: "DELETE FROM clipboard_sync_outbox WHERE account_id = ? AND epoch = ? AND subject_id = ? AND kind = 'entry'",
                arguments: [accountID, epoch, value.sharedID])
        }
    }

    func stageSyncWithdrawals(account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data, in database: Database) throws {
        for row in try Row.fetchAll(database, sql: "SELECT * FROM clipboard_sync_withdrawals WHERE account_id = ? AND epoch = ? AND pending = 1",
            arguments: [account.identifier, control.epoch.uuidString]) {
            let value = ClipboardSyncWithdrawal(sharedID: row["shared_id"], withdrawn: row["withdrawn"],
                revision: .init(counter: row["counter"], operationID: row["operation_id"]))
            let upload = try ClipboardSyncCodec.seal(.withdrawal(value), account: account, control: control, key: key)
            try storeSyncUpload(upload, subjectID: value.sharedID, account: account, in: database)
            try database.execute(sql: """
                UPDATE clipboard_sync_withdrawals SET pending = 0, record_id = ? WHERE account_id = ? AND epoch = ? AND shared_id = ?
                """, arguments: [upload.record.recordID, account.identifier, control.epoch.uuidString, value.sharedID])
        }
    }
}
