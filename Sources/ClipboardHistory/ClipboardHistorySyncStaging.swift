import Foundation
import GRDB

extension ClipboardHistoryModule {
    /// The caller supplies an immutable operation and atomically consumes only
    /// that operation's still-current pending revision after preparation.
    func stageSyncOperation(_ content: ClipboardSyncContent, subjectID: String, operationID: UUID = UUID(),
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data, generation: UInt64,
        consume: (Database, ClipboardSyncRemoteRecord) throws -> Bool) async throws {
        try admitSync(generation)
        let faults = faultInjector
        let preparation = Task.detached(priority: .utility) {
            try faults.check(.syncOperationPreparation)
            try Task.checkCancellation()
            return try ClipboardSyncCodec.seal(content, account: account, control: control, key: key, operationID: operationID)
        }
        let upload = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        try await waitForWriteTurn()
        try admitSync(generation)
        try syncWrite { database in
            guard try syncStagingContextMatches(account: account, control: control, in: database),
                  try consume(database, upload.record) else { return }
            try storeSyncUpload(upload, subjectID: subjectID, account: account, in: database)
        }
    }

    func syncSubjectCanStage(_ sharedID: String, account: ClipboardSyncAccount, control: ClipboardSyncControl,
        in database: Database) throws -> Bool {
        try Bool.fetchOne(database, SQLRequest<Bool>(literal: """
            SELECT EXISTS(SELECT 1 FROM clipboard_sync_entries AS shared
            JOIN clipboard_entries AS entry ON entry.id = shared.local_entry_id
            WHERE shared.account_id = \(account.identifier) AND shared.epoch = \(control.epoch.uuidString)
              AND shared.shared_id = \(sharedID)
              AND (\(Self.syncEntryPublicationAuthority(accountID: account.identifier))))
            """)) == true
    }

    /// Capture local registers once per subject, without a store-wide writer
    /// transaction or a repeated processed-prefix scan for each staged record.
    func recordSyncStagingState(account: ClipboardSyncAccount, control: ClipboardSyncControl,
        generation: UInt64) async throws {
        var afterTag = ""
        while true {
            try await waitForWriteTurn()
            try admitSync(generation)
            let next = try syncWrite { database -> String? in
                guard let tag = try String.fetchOne(database, sql: """
                    SELECT tag_id FROM clipboard_sync_tags WHERE account_id = ? AND tag_id > ? ORDER BY tag_id LIMIT 1
                    """, arguments: [account.identifier, afterTag]) else { return nil }
                try recordLocalSyncTags(accountID: account.identifier, tagID: tag, in: database)
                return tag
            }
            guard let next else { break }
            afterTag = next
            await Task.yield()
        }
        var afterSubject = ""
        while true {
            try await waitForWriteTurn()
            try admitSync(generation)
            let next = try syncWrite { database -> String? in
                guard let subject = try String.fetchOne(database, sql: """
                    SELECT shared_id FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ? AND shared_id > ?
                    ORDER BY shared_id LIMIT 1
                    """, arguments: [account.identifier, control.epoch.uuidString, afterSubject]) else { return nil }
                try recordSyncWithdrawal(sharedID: subject, accountID: account.identifier, epoch: control.epoch.uuidString, in: database)
                try recordLocalSyncMemberships(account: account, epoch: control.epoch, sharedID: subject, in: database)
                return subject
            }
            guard let next else { return }
            afterSubject = next
            await Task.yield()
        }
    }
}
