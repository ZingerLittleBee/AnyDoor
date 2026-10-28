import Foundation
import GRDB

extension ClipboardHistoryModule {
    static func createLinkedFileIdentitySchema(in database: Database) throws {
        try database.execute(sql: """
            ALTER TABLE clipboard_sync_linked_locations ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE clipboard_sync_linked_locations ADD COLUMN native_identity BLOB;
            CREATE TRIGGER clipboard_sync_linked_location_revision
            AFTER UPDATE OF path, identity, base_version_id, base_digest, state, observed_digest
            ON clipboard_sync_linked_locations
            WHEN OLD.path IS NOT NEW.path OR OLD.identity IS NOT NEW.identity
              OR OLD.base_version_id IS NOT NEW.base_version_id OR OLD.base_digest IS NOT NEW.base_digest
              OR OLD.state IS NOT NEW.state OR OLD.observed_digest IS NOT NEW.observed_digest
            BEGIN
              UPDATE clipboard_sync_linked_locations SET revision = OLD.revision + 1 WHERE id = NEW.id;
            END;
            """)
    }
}
