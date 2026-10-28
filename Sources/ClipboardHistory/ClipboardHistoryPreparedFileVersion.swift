import Foundation
import GRDB

/// Immutable encrypted artifacts prepared before a caller's final SQL admission.
/// A conflict journal can retain this DTO without publishing a partial decision.
struct ClipboardSyncPreparedFileVersion: Codable, Sendable {
    let descriptor: ClipboardSyncFileDescriptor
    let parents: [UUID]
    let uploadDirectory: URL
    let sourceURL: URL
    let bookmark: Data
    let identity: Data
    let publication: ClipboardSyncUpload
}

extension ClipboardHistoryModule {
    func prepareFileVersion(sourceURL: URL, objectID: UUID, versionID: UUID, publicationID: UUID,
        parents: [UUID], expectedSourceIdentity: Data, displayName: String,
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data) async throws -> ClipboardSyncPreparedFileVersion {
        let bookmark = try sourceURL.bookmarkData(options: [], includingResourceValuesForKeys: [.fileResourceIdentifierKey], relativeTo: nil)
        let frozen = try await ClipboardSyncFileTransfer.freeze(url: sourceURL, bookmark: bookmark, identity: expectedSourceIdentity,
            directory: storeRoot.appendingPathComponent("SyncTransfers/Uploads/\(versionID.uuidString)"),
            account: account, control: control, key: key, objectID: objectID, versionID: versionID)
        let descriptor = ClipboardSyncFileDescriptor(objectID: objectID, versionID: versionID,
            displayName: displayName, originalByteCount: frozen.originalByteCount,
            contentDigest: frozen.contentDigest, body: frozen.upload.record, state: .available, bodyFormat: frozen.bodyFormat, kind: frozen.kind, encodedByteCount: frozen.encodedByteCount)
        let event = try ClipboardSyncCodec.seal(.fileVersion(.init(descriptor: descriptor, parents: parents)),
            account: account, control: control, key: key, operationID: publicationID)
        return .init(descriptor: descriptor, parents: parents, uploadDirectory: frozen.upload.directory,
            sourceURL: sourceURL, bookmark: bookmark, identity: expectedSourceIdentity, publication: event)
    }

    func storePreparedFileVersion(_ prepared: ClipboardSyncPreparedFileVersion,
        account: ClipboardSyncAccount, control: ClipboardSyncControl, in database: Database) throws {
        guard let body = prepared.descriptor.body else { throw ClipboardSyncServiceError.corruptData }
        if try Bool.fetchOne(database, sql: """
            SELECT EXISTS(SELECT 1 FROM clipboard_sync_file_versions WHERE account_id = ? AND epoch = ? AND object_id = ? AND version_id = ?)
            """, arguments: [account.identifier, control.epoch.uuidString, prepared.descriptor.objectID.uuidString, prepared.descriptor.versionID.uuidString]) == true {
            try storeSyncFileDescriptor(prepared.descriptor, account: account, epoch: control.epoch,
                localPath: nil, bookmark: nil, identity: nil, transferState: "pending", parents: prepared.parents, in: database)
            return
        }
        try storeSyncFileUpload(.init(record: body, directory: prepared.uploadDirectory),
            objectID: prepared.descriptor.objectID, account: account, in: database)
        try storeSyncFileDescriptor(prepared.descriptor, account: account, epoch: control.epoch,
            localPath: prepared.sourceURL.path, bookmark: prepared.bookmark, identity: prepared.identity,
            transferState: "complete", parents: prepared.parents, publicationRecordID: prepared.publication.record.recordID, in: database)
        try storeSyncUpload(prepared.publication, subjectID: prepared.descriptor.objectID.uuidString, account: account, in: database)
    }
}
