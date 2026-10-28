import Foundation
import GRDB

struct ClipboardSyncTagState: Codable, Equatable, Sendable {
    let id: String
    let name: String?
    let selected: Bool
    let revision: ClipboardSyncTagRevision
    let activation: ClipboardSyncTagRevision?

    init(id: String, name: String?, selected: Bool, revision: ClipboardSyncTagRevision,
         activation: ClipboardSyncTagRevision? = nil) {
        self.id = id
        self.name = name
        self.selected = selected
        self.revision = revision
        self.activation = activation
    }
}

extension ClipboardHistoryModule {
    func recordLocalSyncTags(accountID: String, in database: Database) throws {
        let rows = try Row.fetchAll(database, sql: """
            SELECT tag.tag_id, tag.selected, definition.display_name FROM clipboard_sync_tags AS tag
            LEFT JOIN clipboard_tag_definitions AS definition ON definition.id = tag.tag_id
            WHERE tag.account_id = ?
            """, arguments: [accountID])
        for row in rows {
            let id: String = row["tag_id"]
            guard try canonicalSyncTagID(id, accountID: accountID, in: database) == id else { continue }
            let name: String? = row["display_name"]
            let selected = (row["selected"] as Bool) && name != nil
            let previous = try syncTagState(id: id, accountID: accountID, in: database)
            guard previous?.selected != selected || previous?.name != (selected ? name : nil) else { continue }
            guard selected || previous != nil else { continue }
            try saveSyncTagState(.init(id: id, name: selected ? name : nil, selected: selected,
                revision: nextSyncTagRevision(in: database), activation: selected ? previous?.activation : nil),
                accountID: accountID, pending: true, in: database)
        }
    }

    func recordExplicitSyncTagActivation(_ tagID: String, in database: Database) throws -> ClipboardSyncTagRevision? {
        guard let accountID = try syncSettings(in: database).accountID,
              let name = try String.fetchOne(database, sql: "SELECT display_name FROM clipboard_tag_definitions WHERE id = ?", arguments: [tagID]) else { return nil }
        let revision = try nextSyncTagRevision(in: database)
        try saveSyncTagState(.init(id: tagID, name: name, selected: true, revision: revision, activation: revision),
            accountID: accountID, pending: true, in: database)
        return revision
    }

    func stageSyncTagDefinitions(account: ClipboardSyncAccount, control: ClipboardSyncControl,
                                 key: Data, in database: Database) throws {
        try recordLocalSyncTags(accountID: account.identifier, in: database)
        let rows = try Row.fetchAll(database,
            sql: "SELECT tag_id, state FROM clipboard_sync_tag_states WHERE account_id = ? AND pending = 1",
            arguments: [account.identifier])
        for row in rows {
            let state = try JSONDecoder().decode(ClipboardSyncTagState.self, from: row["state"])
            let upload = try ClipboardSyncCodec.seal(.tagState(state), account: account, control: control, key: key)
            try storeSyncUpload(upload, subjectID: state.id, account: account, in: database)
            try database.execute(sql: "UPDATE clipboard_sync_tag_states SET pending = 0 WHERE account_id = ? AND tag_id = ?",
                arguments: [account.identifier, state.id])
            try database.execute(sql: "UPDATE clipboard_sync_tags SET record_id = ? WHERE account_id = ? AND tag_id = ?",
                arguments: [upload.record.recordID, account.identifier, state.id])
        }
    }

    func importSyncTagState(_ state: ClipboardSyncTagState, account: ClipboardSyncAccount,
                            record: ClipboardSyncRemoteRecord, in database: Database) throws {
        guard !state.id.isEmpty, !state.selected || !(state.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
              state.selected || state.name == nil else { throw ClipboardSyncServiceError.corruptData }
        try observeSyncTagRevision(state.revision, in: database)
        if let activation = state.activation {
            guard activation <= state.revision else { throw ClipboardSyncServiceError.corruptData }
            try observeSyncTagRevision(activation, in: database)
        }
        guard try canonicalSyncTagID(state.id, accountID: account.identifier, in: database) == state.id else { return }
        if let previous = try syncTagState(id: state.id, accountID: account.identifier, in: database),
           previous.revision >= state.revision { return }
        try saveSyncTagState(state, accountID: account.identifier, pending: false, in: database)
        if let name = state.name {
            try database.execute(sql: """
                INSERT INTO clipboard_tag_definitions(id, display_name, display_order)
                VALUES (?, ?, COALESCE((SELECT MAX(display_order) + 1 FROM clipboard_tag_definitions), 0))
                ON CONFLICT(id) DO UPDATE SET display_name = excluded.display_name
                """, arguments: [state.id, name])
        }
        try database.execute(sql: """
            INSERT INTO clipboard_sync_tags(account_id, tag_id, selected, record_id) VALUES (?, ?, ?, ?)
            ON CONFLICT(account_id, tag_id) DO UPDATE SET selected = excluded.selected, record_id = excluded.record_id
            """, arguments: [account.identifier, state.id, state.selected, record.recordID])
        try applyAllSyncMemberships(account: account, epoch: record.epoch, in: database)
        if state.selected, let activation = state.activation {
            try authorizeSyncRejoin(tagID: state.id, revision: activation, in: database)
        }
    }

    func syncTagState(id: String, accountID: String, in database: Database) throws -> ClipboardSyncTagState? {
        try Data.fetchOne(database, sql: "SELECT state FROM clipboard_sync_tag_states WHERE account_id = ? AND tag_id = ?",
            arguments: [accountID, id]).map { try JSONDecoder().decode(ClipboardSyncTagState.self, from: $0) }
    }

    func saveSyncTagState(_ state: ClipboardSyncTagState, accountID: String, pending: Bool, in database: Database) throws {
        try database.execute(sql: """
            INSERT INTO clipboard_sync_tag_states(account_id, tag_id, state, pending) VALUES (?, ?, ?, ?)
            ON CONFLICT(account_id, tag_id) DO UPDATE SET state = excluded.state, pending = excluded.pending
            """, arguments: [accountID, state.id, try JSONEncoder().encode(state), pending])
    }
}
