import Foundation
import GRDB

struct ClipboardSyncTagRevision: Codable, Equatable, Comparable, Sendable {
    let counter: Int64
    let operationID: String

    static let initial = Self(counter: 0, operationID: "")
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.operationID < rhs.operationID : lhs.counter < rhs.counter
    }
}

struct ClipboardSyncTagMembership: Codable, Equatable, Sendable {
    let sharedID: String
    let tagID: String
    let present: Bool
    let revision: ClipboardSyncTagRevision
}

extension ClipboardHistoryModule {
    static func createSyncTagSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_tag_clock (id INTEGER PRIMARY KEY CHECK(id = 1), counter INTEGER NOT NULL);
            INSERT INTO clipboard_sync_tag_clock VALUES (1, 0);
            CREATE TABLE clipboard_sync_tag_states (
                account_id TEXT NOT NULL, tag_id TEXT NOT NULL, state BLOB NOT NULL, pending INTEGER NOT NULL,
                PRIMARY KEY(account_id, tag_id)
            ) WITHOUT ROWID;
            CREATE TABLE clipboard_sync_memberships (
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, shared_id TEXT NOT NULL, tag_id TEXT NOT NULL,
                present INTEGER NOT NULL, counter INTEGER NOT NULL, operation_id TEXT NOT NULL,
                pending INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(account_id, epoch, shared_id, tag_id)
            ) WITHOUT ROWID;
            """)
    }

    func nextSyncTagRevision(in database: Database) throws -> ClipboardSyncTagRevision {
        try database.execute(sql: "UPDATE clipboard_sync_tag_clock SET counter = counter + 1 WHERE id = 1")
        return ClipboardSyncTagRevision(counter: try Int64.fetchOne(database,
            sql: "SELECT counter FROM clipboard_sync_tag_clock WHERE id = 1") ?? 1,
            operationID: UUID().uuidString.lowercased())
    }

    func observeSyncTagRevision(_ revision: ClipboardSyncTagRevision, in database: Database) throws {
        guard revision.counter >= 0, revision.counter < Int64.max, !revision.operationID.isEmpty else {
            throw ClipboardSyncServiceError.corruptData
        }
        try database.execute(sql: "UPDATE clipboard_sync_tag_clock SET counter = MAX(counter, ?) WHERE id = 1",
            arguments: [revision.counter])
    }

    /// Initial snapshots seed only absent associations. Later operations win even
    /// when metadata is delivered before the entry or in a different page order.
    func seedSyncMemberships(_ tags: [ClipboardSyncTagContent], sharedID: String, localID: String,
                             account: ClipboardSyncAccount, epoch: UUID, in database: Database) throws {
        for tag in tags {
            try database.execute(sql: """
                INSERT OR IGNORE INTO clipboard_sync_memberships
                    (account_id, epoch, shared_id, tag_id, present, counter, operation_id)
                VALUES (?, ?, ?, ?, 1, 0, '')
                """, arguments: [account.identifier, epoch.uuidString, sharedID, tag.id])
        }
        try applySyncMemberships(sharedID: sharedID, localID: localID, account: account, epoch: epoch, in: database)
    }

    /// Snapshot local differences before applying incoming operations. A local
    /// edit made while a provider request is suspended must not be overwritten.
    func recordLocalSyncMemberships(account: ClipboardSyncAccount, epoch: UUID, in database: Database) throws {
        let selected = Set(try selectedSyncTags(accountID: account.identifier, in: database).map(\.id))
        let entries = try Row.fetchAll(database, sql: """
            SELECT shared_id, local_entry_id FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ?
            """, arguments: [account.identifier, epoch.uuidString])
        for entry in entries {
            let sharedID: String = entry["shared_id"]
            let localID: String = entry["local_entry_id"]
            let current = Set(try String.fetchAll(database,
                sql: "SELECT tag_id FROM clipboard_entry_tags WHERE entry_id = ?", arguments: [localID])).intersection(selected)
            // Loss of the final matching tag is handled by withdrawal, not an
            // empty content update that could erase retained local membership.
            guard !current.isEmpty else { continue }
            for tagID in selected.sorted() {
                let previous = try Bool.fetchOne(database, sql: """
                    SELECT present FROM clipboard_sync_memberships
                    WHERE account_id = ? AND epoch = ? AND shared_id = ? AND tag_id = ?
                    """, arguments: [account.identifier, epoch.uuidString, sharedID, tagID]) ?? false
                let present = current.contains(tagID)
                guard previous != present else { continue }
                try saveSyncMembership(.init(sharedID: sharedID, tagID: tagID, present: present,
                    revision: nextSyncTagRevision(in: database)), account: account, epoch: epoch, pending: true, in: database)
            }
        }
    }

    func stageSyncMemberships(account: ClipboardSyncAccount, control: ClipboardSyncControl,
                              key: Data, in database: Database) throws {
        try recordLocalSyncMemberships(account: account, epoch: control.epoch, in: database)
        for row in try Row.fetchAll(database, sql: """
            SELECT * FROM clipboard_sync_memberships WHERE account_id = ? AND epoch = ? AND pending = 1
            """, arguments: [account.identifier, control.epoch.uuidString]) {
            let membership = syncMembership(from: row)
            let upload = try ClipboardSyncCodec.seal(.tagMembership(membership), account: account, control: control, key: key)
            try storeSyncUpload(upload, subjectID: membership.sharedID, account: account, in: database)
            try database.execute(sql: """
                UPDATE clipboard_sync_memberships SET pending = 0
                WHERE account_id = ? AND epoch = ? AND shared_id = ? AND tag_id = ?
                """, arguments: [account.identifier, control.epoch.uuidString, membership.sharedID, membership.tagID])
        }
    }

    func importSyncMembership(_ membership: ClipboardSyncTagMembership, account: ClipboardSyncAccount,
                              epoch: UUID, in database: Database) throws {
        guard UUID(uuidString: membership.sharedID) != nil, !membership.tagID.isEmpty else {
            throw ClipboardSyncServiceError.corruptData
        }
        try observeSyncTagRevision(membership.revision, in: database)
        if let previous = try Row.fetchOne(database, sql: """
            SELECT * FROM clipboard_sync_memberships WHERE account_id = ? AND epoch = ? AND shared_id = ? AND tag_id = ?
            """, arguments: [account.identifier, epoch.uuidString, membership.sharedID, membership.tagID]),
           syncMembership(from: previous).revision >= membership.revision { return }
        try saveSyncMembership(membership, account: account, epoch: epoch, pending: false, in: database)
        if let localID = try String.fetchOne(database, sql: """
            SELECT local_entry_id FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ? AND shared_id = ?
            """, arguments: [account.identifier, epoch.uuidString, membership.sharedID]) {
            try applySyncMemberships(sharedID: membership.sharedID, localID: localID, account: account, epoch: epoch, in: database)
        }
    }

    private func syncMembership(from row: Row) -> ClipboardSyncTagMembership {
        .init(sharedID: row["shared_id"], tagID: row["tag_id"], present: row["present"],
            revision: .init(counter: row["counter"], operationID: row["operation_id"]))
    }

    private func saveSyncMembership(_ value: ClipboardSyncTagMembership, account: ClipboardSyncAccount,
                                    epoch: UUID, pending: Bool, in database: Database) throws {
        try database.execute(sql: """
            INSERT INTO clipboard_sync_memberships(account_id, epoch, shared_id, tag_id, present, counter, operation_id, pending)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, epoch, shared_id, tag_id) DO UPDATE SET
                present = excluded.present, counter = excluded.counter, operation_id = excluded.operation_id, pending = excluded.pending
            """, arguments: [account.identifier, epoch.uuidString, value.sharedID, value.tagID,
                value.present, value.revision.counter, value.revision.operationID, pending])
    }

    func applyAllSyncMemberships(account: ClipboardSyncAccount, epoch: UUID, in database: Database) throws {
        for row in try Row.fetchAll(database, sql: "SELECT shared_id, local_entry_id FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ?",
            arguments: [account.identifier, epoch.uuidString]) {
            try applySyncMemberships(sharedID: row["shared_id"], localID: row["local_entry_id"], account: account, epoch: epoch, in: database)
        }
    }

    func applySyncMemberships(sharedID: String, localID: String, account: ClipboardSyncAccount,
                                      epoch: UUID, in database: Database) throws {
        let rows = try Row.fetchAll(database, sql: """
            SELECT membership.tag_id, membership.present FROM clipboard_sync_memberships AS membership
            JOIN clipboard_sync_tags AS tag ON tag.account_id = membership.account_id AND tag.tag_id = membership.tag_id
            JOIN clipboard_tag_definitions AS definition ON definition.id = tag.tag_id
            WHERE membership.account_id = ? AND membership.epoch = ? AND membership.shared_id = ? AND tag.selected = 1
            """, arguments: [account.identifier, epoch.uuidString, sharedID])
        for row in rows {
            let tagID: String = row["tag_id"]
            if row["present"] as Bool {
                try database.execute(sql: "INSERT OR IGNORE INTO clipboard_entry_tags(entry_id, tag_id) VALUES (?, ?)",
                    arguments: [localID, tagID])
            } else {
                try database.execute(sql: "DELETE FROM clipboard_entry_tags WHERE entry_id = ? AND tag_id = ?",
                    arguments: [localID, tagID])
            }
        }
        _ = try recomputeProtection(for: localID, in: database)
    }
}
