import Foundation
import GRDB

extension ClipboardHistoryModule {
    static func createApplicationUpdateSchema(in database: Database) throws {
        try database.execute(sql: """
            ALTER TABLE clipboard_sync_linked_locations ADD COLUMN is_application INTEGER NOT NULL DEFAULT 0;
            UPDATE clipboard_sync_linked_locations SET is_application = 1 WHERE lower(path) LIKE '%.app';
            ALTER TABLE clipboard_sync_file_selections ADD COLUMN application_revision INTEGER NOT NULL DEFAULT 0;
            CREATE TRIGGER clipboard_application_version_insert AFTER INSERT ON clipboard_sync_file_versions
            BEGIN
              UPDATE clipboard_sync_file_selections SET application_revision = application_revision + 1
              WHERE account_id = NEW.account_id AND epoch = NEW.epoch AND object_id = NEW.object_id;
            END;
            CREATE TRIGGER clipboard_application_version_delete AFTER DELETE ON clipboard_sync_file_versions
            BEGIN
              UPDATE clipboard_sync_file_selections SET application_revision = application_revision + 1
              WHERE account_id = OLD.account_id AND epoch = OLD.epoch AND object_id = OLD.object_id;
            END;
            CREATE TRIGGER clipboard_application_selection_change
            AFTER UPDATE OF current_version_id, complete_version_id ON clipboard_sync_file_selections
            WHEN OLD.current_version_id IS NOT NEW.current_version_id OR OLD.complete_version_id IS NOT NEW.complete_version_id
            BEGIN
              UPDATE clipboard_sync_file_selections SET application_revision = OLD.application_revision + 1
              WHERE account_id = NEW.account_id AND epoch = NEW.epoch AND object_id = NEW.object_id;
            END;
            CREATE TABLE clipboard_sync_application_plans (
              id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL, epoch TEXT NOT NULL,
              location_id TEXT NOT NULL, phase TEXT NOT NULL, snapshot BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE UNIQUE INDEX clipboard_application_active_plan
              ON clipboard_sync_application_plans(account_id, epoch, location_id);
            """)
    }

    static func applicationVersionRevision(_ objectID: UUID, accountID: String, epoch: UUID, in database: Database) throws -> Int64 {
        guard let revision = try Int64.fetchOne(database, sql: """
            SELECT application_revision FROM clipboard_sync_file_selections
            WHERE account_id = ? AND epoch = ? AND object_id = ?
            """, arguments: [accountID, epoch.uuidString, objectID.uuidString]) else {
            throw ClipboardHistoryApplicationUpdateError.stalePlan
        }
        return revision
    }

    static func validateApplicationUpdate(_ snapshot: ClipboardApplicationUpdateSnapshot, phase: String,
        in database: Database) throws -> ClipboardLinkedLocationSource {
        guard try Bool.fetchOne(database, sql: "SELECT enabled = 1 AND account_id = ? FROM clipboard_sync_settings WHERE id = 1",
            arguments: [snapshot.accountID]) == true,
              try String.fetchOne(database, sql: "SELECT phase FROM clipboard_sync_application_plans WHERE id = ?",
                arguments: [snapshot.id.uuidString]) == phase else { throw ClipboardHistoryApplicationUpdateError.stalePlan }
        let row = try linkedFileActionRow(.init(entryID: .init(snapshot.entryID), locationID: snapshot.location.id,
            expectedRevision: snapshot.location.revision), in: database)
        let source = try linkedLocationSource(row)
        guard (row["account_id"] as String) == snapshot.accountID, (row["epoch"] as String) == snapshot.epoch.uuidString,
              source.objectID == snapshot.objectID, source.identity == snapshot.location.identity,
              source.baseVersionID == snapshot.location.baseVersionID, source.baseDigest == snapshot.location.baseDigest,
              source.url.path == snapshot.location.path, source.state.rawValue == snapshot.location.state,
              try applicationVersionRevision(snapshot.objectID, accountID: snapshot.accountID, epoch: snapshot.epoch, in: database) == snapshot.versionRevision,
              try String.fetchOne(database, sql: """
                SELECT current_version_id FROM clipboard_sync_file_selections
                WHERE account_id = ? AND epoch = ? AND object_id = ?
                """, arguments: [snapshot.accountID, snapshot.epoch.uuidString, snapshot.objectID.uuidString]) == snapshot.versionID.uuidString else {
            throw ClipboardHistoryApplicationUpdateError.stalePlan
        }
        return source
    }
}
