import Foundation
import GRDB

extension ClipboardHistoryModule {
    /// Completing a known local exchange is independent of cloud participation.
    /// This only adopts the exact journaled replacement already at its path; it
    /// never downloads, starts an exchange, or accepts an unknown replacement.
    func recoverLocalLinkedFileApplications(entryID: ClipboardHistoryEntryID? = nil) async throws {
        let epoch = storeEpoch
        let rows = try linkedRead { try Row.fetchAll($0, sql: """
            SELECT location.* FROM clipboard_sync_linked_locations AS location
            WHERE applying_version_id IS NOT NULL AND (? IS NULL OR EXISTS (
              SELECT 1 FROM clipboard_sync_file_members AS member WHERE member.entry_id = ?
                AND member.account_id = location.account_id AND member.epoch = location.epoch AND member.object_id = location.object_id))
            """, arguments: [entryID?.value.uuidString.lowercased(), entryID?.value.uuidString.lowercased()]) }
        for row in rows {
            let source = try Self.linkedLocationSource(row)
            guard !activeApplicationUpdates.contains(source.id) else { continue }
            guard let version: String = row["applying_version_id"], let digest: Data = row["applying_digest"],
                  let identity: Data = row["replacement_identity"] else { continue }
            let work = Task.detached(priority: .utility) { try? ClipboardLinkedFileIO.inspect(source.url, expectedIdentity: identity) }
            guard let proof = await work.value else { continue }
            try await waitForWriteTurn()
            guard epoch == storeEpoch else { throw ClipboardHistoryModuleError.operationUnavailable }
            guard !activeApplicationUpdates.contains(source.id) else { continue }
            let changed = try syncWrite { database in
                guard proof.stamp.matches(source.url),
                      let current = try Row.fetchOne(database, sql: "SELECT * FROM clipboard_sync_linked_locations WHERE id = ?", arguments: [source.id.uuidString]),
                      (current["revision"] as UInt64) == source.revision,
                      (current["applying_version_id"] as String?) == version,
                      (current["replacement_identity"] as Data?) == identity else { return false }
                // Preserve both physical outputs. In particular a displaced
                // inode may still contain a save through an editor's open FD.
                try database.execute(sql: """
                    UPDATE clipboard_sync_linked_locations SET base_version_id = ?, base_digest = ?,
                      bookmark = ?, identity = ?, native_identity = ?, observed_digest = ?, state = ?, pending_version_id = NULL,
                      applying_version_id = NULL, applying_digest = NULL, replacement_path = NULL, replacement_identity = NULL
                    WHERE id = ?
                    """, arguments: [version, digest, proof.bookmark, proof.identity, try proof.nativeIdentity?.encoded(), proof.digest,
                        source.state == .paused ? "paused" : (proof.digest == digest ? "current" : "localChanges"), source.id.uuidString])
                try Self.completeLinkedSyncFileWork(source.id, in: database)
                try Self.bumpHistoryRevision(in: database)
                return true
            }
            if changed { publishMutation() }
        }
    }
}
