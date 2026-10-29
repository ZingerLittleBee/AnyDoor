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

    /// Deletion can abandon a presentation snapshot without creating transfer work.
    /// Membership, rather than current tag selection, decides whether it is unowned.
    func reclaimUnownedFileConflictPlans(in database: Database) throws {
        let rows = try Row.fetchAll(database, sql: """
            SELECT plan.id, plan.snapshot FROM clipboard_sync_file_conflict_plans AS plan
            WHERE NOT EXISTS(SELECT 1 FROM clipboard_sync_file_resolutions WHERE plan_id = plan.id)
              AND NOT EXISTS(SELECT 1 FROM clipboard_sync_file_conflict_pins WHERE plan_id = plan.id)
            """)
        for row in rows {
            guard let id = UUID(uuidString: row["id"]), !activeFileConflictResolutions.contains(id) else { continue }
            let snapshot = try JSONDecoder().decode(ClipboardSyncFileConflictSnapshot.self, from: row["snapshot"])
            let owned = try Bool.fetchOne(database, sql: """
                SELECT EXISTS(SELECT 1 FROM clipboard_sync_file_members AS member
                  WHERE member.account_id = ? AND member.epoch = ? AND member.object_id = ? AND member.entry_id = ?
                    AND \(Self.liveSyncFileMember))
                """, arguments: [snapshot.accountID, snapshot.epoch.uuidString, snapshot.objectID.uuidString,
                    snapshot.entryID.uuidString.lowercased()])
            if owned != true {
                try database.execute(sql: "DELETE FROM clipboard_sync_file_conflict_plans WHERE id = ?", arguments: [id.uuidString])
            }
        }
    }

    /// Completion has already proved publication and installation. Retain its
    /// receipt, but discard detailed ownership only after durable versions own it.
    func compactFileConflictResolution(planID: String, in database: Database) throws {
        guard let current = try Row.fetchOne(database, sql: """
            SELECT plan.snapshot, resolution.journal FROM clipboard_sync_file_conflict_plans AS plan
            JOIN clipboard_sync_file_resolutions AS resolution ON resolution.plan_id = plan.id
            WHERE plan.id = ? AND resolution.phase = 'complete'
            """, arguments: [planID]), let id = UUID(uuidString: planID) else { return }
        let snapshot = try JSONDecoder().decode(ClipboardSyncFileConflictSnapshot.self, from: current["snapshot"])
        let journal = try JSONDecoder().decode(ClipboardSyncFileResolutionJournal.self, from: current["journal"])
        for source in try Data.fetchAll(database, sql: """
            SELECT source FROM clipboard_sync_file_preservations WHERE account_id = ? AND epoch = ? AND completed = 0
            """, arguments: [snapshot.accountID, snapshot.epoch.uuidString]) {
            let preservation = try JSONDecoder().decode(ClipboardSyncPreservedFileSource.self, from: source)
            if preservation.location.objectID == snapshot.objectID { return }
        }
        guard try fileConflictResolutionIsSettled(id, snapshot: snapshot, journal: journal, visiting: [], in: database) else { return }
        let receipt = ClipboardSyncFileResolutionJournal(choice: journal.choice, resultID: journal.resultID,
            publicationID: journal.publicationID, branches: [], inheritedPlans: [], prepared: [])
        let identity = ClipboardSyncFileConflictSnapshot(accountID: snapshot.accountID, epoch: snapshot.epoch,
            keyID: snapshot.keyID, entryID: snapshot.entryID, objectID: snapshot.objectID, heads: [], locations: [])
        try database.execute(sql: "UPDATE clipboard_sync_file_resolutions SET journal = ? WHERE plan_id = ?",
            arguments: [try JSONEncoder().encode(receipt), planID])
        try database.execute(sql: "UPDATE clipboard_sync_file_conflict_plans SET snapshot = ? WHERE id = ?",
            arguments: [try JSONEncoder().encode(identity), planID])

        let rows = try Row.fetchAll(database, sql: """
            SELECT resolution.plan_id, resolution.phase, resolution.journal, plan.snapshot
            FROM clipboard_sync_file_resolutions AS resolution
            JOIN clipboard_sync_file_conflict_plans AS plan ON plan.id = resolution.plan_id
            WHERE resolution.account_id = ? AND resolution.epoch = ? AND resolution.object_id = ? AND resolution.plan_id != ?
            """, arguments: [snapshot.accountID, snapshot.epoch.uuidString, snapshot.objectID.uuidString, planID])
        var removable: Set<UUID> = [], protected: Set<UUID> = []
        var dependencies: [UUID: [UUID]] = [:]
        for row in rows {
            guard let previous = UUID(uuidString: row["plan_id"]) else { throw ClipboardSyncServiceError.corruptData }
            let previousSnapshot = try JSONDecoder().decode(ClipboardSyncFileConflictSnapshot.self, from: row["snapshot"])
            let previousJournal = try JSONDecoder().decode(ClipboardSyncFileResolutionJournal.self, from: row["journal"])
            dependencies[previous] = previousJournal.inheritedPlans
            if ["complete", "superseded"].contains(row["phase"] as String), previousSnapshot.entryID == snapshot.entryID,
               try fileConflictResolutionIsSettled(previous, snapshot: previousSnapshot, journal: previousJournal,
                    visiting: [], in: database) {
                removable.insert(previous)
            } else { protected.insert(previous) }
        }
        // Retained work keeps its whole dependency chain. Establish eligibility
        // before deletion so parent/child row order cannot change retention.
        var pending = Array(protected)
        while let owner = pending.popLast() {
            for dependency in dependencies[owner, default: []] where protected.insert(dependency).inserted {
                pending.append(dependency)
            }
        }
        for previous in removable.subtracting(protected) {
            // The plan owns the foreign-key parent; remove its settled receipt first.
            try database.execute(sql: "DELETE FROM clipboard_sync_file_resolutions WHERE plan_id = ?", arguments: [previous.uuidString])
            try database.execute(sql: "DELETE FROM clipboard_sync_file_conflict_plans WHERE id = ?", arguments: [previous.uuidString])
        }
    }

    private func fileConflictResolutionIsSettled(_ id: UUID, snapshot: ClipboardSyncFileConflictSnapshot,
        journal: ClipboardSyncFileResolutionJournal, visiting: Set<UUID>, in database: Database) throws -> Bool {
        guard !visiting.contains(id), !activeFileConflictResolutions.contains(id),
              try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM clipboard_sync_file_conflict_pins WHERE plan_id = ?)",
                arguments: [id.uuidString]) != true else { return false }
        for prepared in journal.prepared {
            guard prepared.descriptor.objectID == snapshot.objectID,
                  let owned = try Row.fetchOne(database, sql: """
                    SELECT descriptor, parents FROM clipboard_sync_file_versions
                    WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?
                    """, arguments: [snapshot.accountID, snapshot.epoch.uuidString, snapshot.objectID.uuidString,
                        prepared.descriptor.versionID.uuidString]),
                  try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: owned["descriptor"]) == prepared.descriptor,
                  try JSONDecoder().decode([UUID].self, from: owned["parents"]) == prepared.parents else { return false }
        }
        for inherited in journal.inheritedPlans {
            guard let parent = try Row.fetchOne(database, sql: """
                SELECT resolution.phase, resolution.journal, plan.snapshot FROM clipboard_sync_file_resolutions AS resolution
                JOIN clipboard_sync_file_conflict_plans AS plan ON plan.id = resolution.plan_id WHERE resolution.plan_id = ?
                """, arguments: [inherited.uuidString]), ["complete", "superseded"].contains(parent["phase"] as String) else { return false }
            let parentSnapshot = try JSONDecoder().decode(ClipboardSyncFileConflictSnapshot.self, from: parent["snapshot"])
            let parentJournal = try JSONDecoder().decode(ClipboardSyncFileResolutionJournal.self, from: parent["journal"])
            guard parentSnapshot.accountID == snapshot.accountID, parentSnapshot.epoch == snapshot.epoch,
                  parentSnapshot.objectID == snapshot.objectID, parentSnapshot.keyID == snapshot.keyID,
                  try fileConflictResolutionIsSettled(inherited, snapshot: parentSnapshot, journal: parentJournal,
                    visiting: visiting.union([id]), in: database) else { return false }
        }
        return true
    }

    private static func conflictSnapshotsMatch(_ lhs: ClipboardSyncFileConflictSnapshot,
        _ rhs: ClipboardSyncFileConflictSnapshot) -> Bool {
        lhs.accountID == rhs.accountID && lhs.epoch == rhs.epoch && lhs.keyID == rhs.keyID
            && lhs.entryID == rhs.entryID && lhs.objectID == rhs.objectID && lhs.heads == rhs.heads
            && lhs.locations.sorted { $0.id.uuidString < $1.id.uuidString }
                == rhs.locations.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
