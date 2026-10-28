import Foundation
import GRDB

extension ClipboardHistoryModule {
    /// A rejoin carries the whole known graph, including roots and competing
    /// heads. The entry's selected descriptor alone cannot reconstruct ancestry.
    func syncFileRejoinVersions(entryID: String, account: ClipboardSyncAccount,
        control: ClipboardSyncControl, in database: Database) throws -> [ClipboardSyncFileVersionContent] {
        try Row.fetchAll(database, sql: """
            SELECT DISTINCT version.descriptor, version.parents FROM clipboard_sync_file_versions AS version
            JOIN clipboard_sync_file_members AS member USING(account_id, epoch, object_id)
            WHERE member.account_id = ? AND member.epoch = ? AND member.entry_id = ?
            ORDER BY version.object_id, version.version_id
            """, arguments: [account.identifier, control.epoch.uuidString, entryID]).map {
                .init(descriptor: try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: $0["descriptor"]),
                    parents: try JSONDecoder().decode([UUID].self, from: $0["parents"]))
            }
    }

    func importSyncFileRejoinVersions(_ versions: [ClipboardSyncFileVersionContent]?,
        entry: ClipboardSyncEntryContent, account: ClipboardSyncAccount,
        record: ClipboardSyncRemoteRecord, in database: Database) throws -> [UUID: [UUID]] {
        guard let versions else { return [:] }
        let selected = entry.items.flatMap(\.representations).compactMap { representation -> ClipboardSyncFileDescriptor? in
            if case .file(let descriptor) = representation { return descriptor }
            return nil
        }
        let objects = Set(selected.map(\.objectID))
        guard Set(versions.map { $0.descriptor.versionID }).count == versions.count,
              versions.allSatisfy({ objects.contains($0.descriptor.objectID)
                  && !$0.parents.contains($0.descriptor.versionID) && Set($0.parents).count == $0.parents.count }),
              selected.allSatisfy({ descriptor in versions.contains { $0.descriptor == descriptor } }) else {
            throw ClipboardSyncServiceError.corruptData
        }
        for version in versions {
            try validateSyncFileDescriptor(version.descriptor, epoch: record.epoch, keyID: record.keyID)
            try storeSyncFileDescriptor(version.descriptor, account: account, epoch: record.epoch,
                localPath: nil, bookmark: nil, identity: nil, transferState: "pending",
                parents: version.parents, publicationRecordID: record.recordID, in: database)
        }
        return Dictionary(uniqueKeysWithValues: versions.map { ($0.descriptor.versionID, $0.parents) })
    }
}
