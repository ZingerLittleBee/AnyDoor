import Foundation
import GRDB

extension ClipboardHistoryModule {
    /// Presentation does not consume a choice or create another recovery owner.
    /// Keep one current unprotected snapshot for each entry/object, and preserve
    /// every plan whose explicit download or resolution still owns work.
    func retainFileConflictPlan(_ snapshot: ClipboardSyncFileConflictSnapshot, in database: Database) throws -> UUID {
        let rows = try Row.fetchAll(database, sql: """
            SELECT plan.id, plan.snapshot,
              EXISTS(SELECT 1 FROM clipboard_sync_file_conflict_pins WHERE plan_id = plan.id) AS pinned
            FROM clipboard_sync_file_conflict_plans AS plan
            WHERE plan.account_id = ? AND plan.epoch = ? AND plan.object_id = ?
              AND NOT EXISTS(SELECT 1 FROM clipboard_sync_file_resolutions WHERE plan_id = plan.id)
            ORDER BY plan.id
            """, arguments: [snapshot.accountID, snapshot.epoch.uuidString, snapshot.objectID.uuidString])
        var reusable: UUID?
        var obsolete: [UUID] = []
        for row in rows {
            guard let id = UUID(uuidString: row["id"]) else { throw ClipboardSyncServiceError.corruptData }
            guard !activeFileConflictResolutions.contains(id) else { continue }
            let saved = try JSONDecoder().decode(ClipboardSyncFileConflictSnapshot.self, from: row["snapshot"])
            guard saved.entryID == snapshot.entryID else { continue }
            if reusable == nil, Self.conflictSnapshotsMatch(saved, snapshot) { reusable = id }
            if !(row["pinned"] as Bool) { obsolete.append(id) }
        }
        let id = reusable ?? UUID()
        if reusable == nil {
            try database.execute(sql: """
                INSERT INTO clipboard_sync_file_conflict_plans(id, account_id, epoch, object_id, snapshot)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, snapshot.accountID, snapshot.epoch.uuidString,
                    snapshot.objectID.uuidString, try JSONEncoder().encode(snapshot)])
        }
        for previous in obsolete where previous != id {
            try database.execute(sql: """
                DELETE FROM clipboard_sync_file_conflict_plans WHERE id = ?
                  AND NOT EXISTS(SELECT 1 FROM clipboard_sync_file_resolutions WHERE plan_id = ?)
                  AND NOT EXISTS(SELECT 1 FROM clipboard_sync_file_conflict_pins WHERE plan_id = ?)
                """, arguments: [previous.uuidString, previous.uuidString, previous.uuidString])
        }
        return id
    }

    private static func conflictSnapshotsMatch(_ lhs: ClipboardSyncFileConflictSnapshot,
        _ rhs: ClipboardSyncFileConflictSnapshot) -> Bool {
        lhs.accountID == rhs.accountID && lhs.epoch == rhs.epoch && lhs.keyID == rhs.keyID
            && lhs.entryID == rhs.entryID && lhs.objectID == rhs.objectID && lhs.heads == rhs.heads
            && lhs.locations.sorted { $0.id.uuidString < $1.id.uuidString }
                == rhs.locations.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
