import Foundation
import GRDB

struct ClipboardSyncResetJournal: Codable, Sendable {
    let account: ClipboardSyncAccount
    let previous: ClipboardSyncControl
    var resetID: UUID
    var cursor: Data?
    var deletedRecordCount = 0
    var stage = ClipboardHistoryCloudResetStatus.Stage.preparing
    var failure: ClipboardHistorySyncPhase?
    var retryNotBefore: Date?

    var status: ClipboardHistoryCloudResetStatus {
        .init(stage: stage, deletedRecordCount: deletedRecordCount, failure: failure)
    }
}

extension ClipboardHistoryModule {
    public func prepareCloudReset() async throws -> ClipboardHistoryCloudResetConfirmation {
        guard let services = syncServices else { throw ClipboardSyncServiceError.capabilityUnavailable }
        let generation = syncGeneration
        let store = storeEpoch
        let account = try await services.transport.account()
        guard generation == syncGeneration, store == storeEpoch, availability == .ready else { throw CancellationError() }
        guard try currentSyncAccountID() == account.identifier else { throw ClipboardSyncServiceError.accountChanged }
        guard let control = try await services.transport.control(for: account) else { throw ClipboardSyncServiceError.missingRemoteState }
        guard try await services.transport.account() == account else { throw ClipboardSyncServiceError.accountChanged }
        guard generation == syncGeneration, store == storeEpoch, availability == .ready else { throw CancellationError() }
        return .init(account: account, control: control)
    }

    public func clearCloudDataAndStopSync(_ confirmation: ClipboardHistoryCloudResetConfirmation) async throws {
        guard try currentSyncAccountID() == confirmation.account.identifier else { throw ClipboardSyncServiceError.accountChanged }
        let generation = await stopSyncTasks()
        guard generation == syncGeneration else { return }
        _ = try await writableDatabase()
        guard generation == syncGeneration else { return }
        guard try currentSyncAccountID() == confirmation.account.identifier else { throw ClipboardSyncServiceError.accountChanged }
        let existing = try currentCloudReset()
        let journal: ClipboardSyncResetJournal
        if let existing, existing.account == confirmation.account, existing.status.isPending {
            journal = existing
        } else {
            journal = ClipboardSyncResetJournal(account: confirmation.account, previous: confirmation.control,
                resetID: confirmation.control.phase == "active" ? UUID() : confirmation.control.epoch)
        }
        try syncWrite { database in
            try database.execute(sql: "UPDATE clipboard_sync_settings SET enabled = 0 WHERE id = 1")
            try database.execute(sql: "UPDATE clipboard_sync_reset SET activation_authorized = 0 WHERE id = 1")
            try saveCloudReset(journal, in: database)
        }
        syncSuspended = false
        publishSyncStatus()
        await retrySync()
    }

    func cloudReset(in database: Database, accountID: String? = nil) throws -> ClipboardSyncResetJournal? {
        let scope = try accountID ?? syncSettings(in: database).accountID
        guard let scope else { return nil }
        return try Data.fetchOne(database, sql: "SELECT journal FROM clipboard_sync_resets WHERE account_id = ?", arguments: [scope])
            .map { try JSONDecoder().decode(ClipboardSyncResetJournal.self, from: $0) }
    }

    func currentCloudReset(accountID: String? = nil) throws -> ClipboardSyncResetJournal? {
        try requiredDatabase().read { try cloudReset(in: $0, accountID: accountID) }
    }

    func hasPendingCloudResets() throws -> Bool {
        try requiredDatabase().read { database in
            try Data.fetchAll(database, sql: "SELECT journal FROM clipboard_sync_resets").contains {
                try JSONDecoder().decode(ClipboardSyncResetJournal.self, from: $0).status.isPending
            }
        }
    }

    func currentSyncAccountID() throws -> String? {
        try requiredDatabase().read { try syncSettings(in: $0).accountID }
    }

    func cloudActivationAuthorized() throws -> Bool {
        try requiredDatabase().read {
            try Bool.fetchOne($0, sql: "SELECT activation_authorized FROM clipboard_sync_reset WHERE id = 1") == true
        }
    }

    func saveCloudReset(_ journal: ClipboardSyncResetJournal, in database: Database) throws {
        try database.execute(sql: """
            INSERT INTO clipboard_sync_resets(account_id, journal) VALUES (?, ?)
            ON CONFLICT(account_id) DO UPDATE SET journal = excluded.journal
            """, arguments: [journal.account.identifier, try JSONEncoder().encode(journal)])
    }

    /// Keep user history, tags, memberships, and cross-account authorization
    /// records. Only this collection's publication state is retired.
    func retireLocalSyncCollection(accountID: String, in database: Database) throws {
        // Snapshot file ownership and unuploaded saved work before outbox
        // cascades remove the only encrypted transfer/publication references.
        for row in try Row.fetchAll(database, sql: "SELECT epoch, shared_id FROM clipboard_sync_entries WHERE account_id = ?",
            arguments: [accountID]) {
            let epoch: String = row["epoch"], shared: String = row["shared_id"]
            try Self.rememberSyncFileOwnership(sharedID: shared, accountID: accountID, epoch: epoch, in: database)
            try Self.captureSyncFilePreservations(sharedID: shared, accountID: accountID, epoch: epoch, in: database)
            try Self.captureSyncFileCleanup(sharedID: shared, accountID: accountID, epoch: epoch, retired: true, in: database)
        }
        try database.execute(sql: """
            INSERT OR IGNORE INTO clipboard_sync_reset_exclusions(account_id, local_entry_id)
            SELECT ?, shared.local_entry_id FROM clipboard_sync_entries AS shared
              JOIN clipboard_entries AS entry ON entry.id = shared.local_entry_id
              WHERE shared.account_id = ?
            UNION SELECT ?, entry_id FROM clipboard_sync_file_members WHERE account_id = ?
            UNION SELECT ?, membership.entry_id FROM clipboard_entry_tags AS membership
              JOIN clipboard_sync_tags AS selected ON selected.tag_id = membership.tag_id
              WHERE selected.account_id = ? AND selected.selected = 1
            """, arguments: [accountID, accountID, accountID, accountID, accountID, accountID])
        try database.execute(sql: "DELETE FROM clipboard_sync_outbox WHERE account_id = ?", arguments: [accountID])
        try database.execute(sql: "DELETE FROM clipboard_sync_file_rejoins WHERE account_id = ?", arguments: [accountID])
        try database.execute(sql: "DELETE FROM clipboard_sync_tag_states WHERE account_id = ?", arguments: [accountID])
        try database.execute(sql: "DELETE FROM clipboard_sync_tag_merge_outbox WHERE account_id = ?", arguments: [accountID])
        try database.execute(sql: "DELETE FROM clipboard_sync_tag_aliases WHERE account_id = ?", arguments: [accountID])
        try database.execute(sql: "UPDATE clipboard_sync_tags SET selected = 0, locally_authorized = 0, record_id = NULL WHERE account_id = ?",
            arguments: [accountID])
    }

    func stopForRetiredCollection(_ control: ClipboardSyncControl, state: inout ClipboardSyncAccountState) throws {
        stopLinkedFileObservers()
        state.control = control
        state.cursor = nil
        state.candidate = nil
        try syncWrite { database in
            try retireLocalSyncCollection(accountID: state.account.identifier, in: database)
            try saveSyncAccount(state, in: database)
            try database.execute(sql: "UPDATE clipboard_sync_settings SET enabled = 0 WHERE id = 1")
            try database.execute(sql: "UPDATE clipboard_sync_reset SET activation_authorized = 0 WHERE id = 1")
            try database.execute(sql: "UPDATE clipboard_sync_recovery SET phase = NULL, retry_not_before = NULL WHERE id = 1")
        }
        syncSuspended = !(try hasPendingCloudResets())
        setSyncPhase(.disabled)
    }

    /// Old account journals remain dormant while another account participates.
    /// Resolving the current system account never grants ordinary sync consent.
    func discoverPendingCloudReset(generation: UInt64) async {
        do {
            guard let services = syncServices else { throw ClipboardSyncServiceError.capabilityUnavailable }
            try admitCloudResetDiscovery(generation)
            let account = try await services.transport.account()
            try admitCloudResetDiscovery(generation)
            if let journal = try currentCloudReset(accountID: account.identifier), journal.status.isPending {
                try await waitForWriteTurn()
                try admitCloudResetDiscovery(generation)
                try syncWrite { database in
                    try database.execute(sql: "UPDATE clipboard_sync_settings SET account_id = ?, enabled = 0 WHERE id = 1",
                        arguments: [account.identifier])
                    try database.execute(sql: "UPDATE clipboard_sync_reset SET activation_authorized = 0 WHERE id = 1")
                }
                if let deadline = journal.retryNotBefore, deadline > now() { publishSyncStatus(); return }
                await performCloudReset(generation: generation)
            } else if syncStatus().isEnabled {
                await performSync(generation: generation, allowAccountBinding: false)
            } else if let bound = try currentCloudReset(), bound.status.isPending, bound.account != account {
                throw ClipboardSyncServiceError.accountChanged
            }
        } catch is CancellationError {
            return
        } catch {
            if let journal = try? currentCloudReset(), journal.status.isPending {
                await failCloudReset(error, journal: journal, generation: generation)
            } else {
                let delay: TimeInterval?
                if case ClipboardSyncServiceError.network(let retryAfter) = error { delay = retryAfter } else { delay = nil }
                await finishSync(syncFailurePhase(error), generation: generation, retryAfter: delay)
            }
        }
    }

    func admitCloudResetDiscovery(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == syncGeneration, !syncSuspended, availability == .ready else { throw CancellationError() }
    }

    func performCloudReset(generation: UInt64) async {
        guard var journal = try? currentCloudReset(), journal.status.isPending else { return }
        do {
            guard let services = syncServices else { throw ClipboardSyncServiceError.capabilityUnavailable }
            try await admitCloudReset(generation, account: journal.account, services: services)
            guard var control = try await services.transport.control(for: journal.account) else {
                throw ClipboardSyncServiceError.missingRemoteState
            }
            try await admitCloudReset(generation, account: journal.account, services: services)
            guard control.keyID == journal.previous.keyID, control.keyCheck == journal.previous.keyCheck else {
                throw ClipboardSyncServiceError.corruptData
            }
            if control.phase == "active", control.epoch != journal.previous.epoch {
                // Another explicit activation has already moved beyond the
                // retired collection. Do not clear its data or claim this
                // device observed completion of the previous clear.
                journal.stage = .superseded
                journal.failure = nil
                try syncWrite { database in
                    try retireLocalSyncCollection(accountID: journal.account.identifier, in: database)
                    try saveCloudReset(journal, in: database)
                }
                try await resumeSyncFilePreservations()
                syncSuspended = !(try hasPendingCloudResets())
                setSyncPhase(.disabled)
                return
            }
            if control.phase == "active" {
                guard journal.stage == .preparing else { throw ClipboardSyncServiceError.missingRemoteState }
                control = try await services.transport.transition(control, to: "resetting", epoch: journal.resetID, for: journal.account)
                try await admitCloudReset(generation, account: journal.account, services: services)
            }
            guard ["resetting", "stopped"].contains(control.phase) else { throw ClipboardSyncServiceError.missingRemoteState }
            // A concurrent reset wins the same retirement. Restart enumeration
            // when adopting it; never retain another operation's cursor.
            if journal.resetID != control.epoch { journal.resetID = control.epoch; journal.cursor = nil }
            journal.stage = .clearing
            journal.failure = nil
            journal.retryNotBefore = nil
            try syncWrite { database in
                try retireLocalSyncCollection(accountID: journal.account.identifier, in: database)
                try saveCloudReset(journal, in: database)
            }
            try await resumeSyncFilePreservations()
            publishSyncStatus()
            while control.phase == "resetting" {
                let page = try await services.transport.clearPage(for: journal.account, control: control, cursor: journal.cursor)
                try await admitCloudReset(generation, account: journal.account, services: services)
                guard page.control.epoch == journal.resetID, page.control.keyID == control.keyID,
                      page.control.phase == "resetting" else { throw ClipboardSyncServiceError.missingRemoteState }
                control = page.control
                journal.cursor = page.cursor
                journal.deletedRecordCount += page.deletedRecordCount
                try syncWrite { try saveCloudReset(journal, in: $0) }
                publishSyncStatus()
                if !page.hasMore {
                    control = try await services.transport.transition(control, to: "stopped", epoch: journal.resetID, for: journal.account)
                    try await admitCloudReset(generation, account: journal.account, services: services)
                }
            }
            guard control.phase == "stopped", control.epoch == journal.resetID else { throw ClipboardSyncServiceError.missingRemoteState }
            journal.stage = .completed
            journal.failure = nil
            journal.retryNotBefore = nil
            try syncWrite { database in
                var state = try syncAccountState(journal.account, in: database)
                state.control = control
                state.candidate = nil
                state.cursor = nil
                try saveSyncAccount(state, in: database)
                try saveCloudReset(journal, in: database)
                try database.execute(sql: "UPDATE clipboard_sync_recovery SET phase = NULL, retry_not_before = NULL WHERE id = 1")
            }
            syncSuspended = !(try hasPendingCloudResets())
            setSyncPhase(.disabled)
        } catch is CancellationError {
            return
        } catch {
            await failCloudReset(error, journal: journal, generation: generation)
        }
    }

    private func failCloudReset(_ error: Error, journal: ClipboardSyncResetJournal, generation: UInt64) async {
        do {
            try await waitForWriteTurn()
            try admitCloudReset(generation)
            var journal = journal
            journal.failure = syncFailurePhase(error)
            let delay: TimeInterval?
            if case ClipboardSyncServiceError.network(let retryAfter) = error { delay = retryAfter } else { delay = nil }
            journal.retryNotBefore = delay.flatMap { $0.isFinite && $0 > 0 ? now().addingTimeInterval($0) : nil }
            try syncWrite { try saveCloudReset(journal, in: $0) }
            publishSyncStatus()
        } catch {
            guard generation == syncGeneration, !syncSuspended else { return }
            setSyncPhase(.failed(.localStorage))
        }
    }

    func admitCloudReset(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == syncGeneration, !syncSuspended, availability == .ready,
              let journal = try currentCloudReset(), journal.status.isPending else { throw CancellationError() }
    }

    func admitCloudReset(_ generation: UInt64, account: ClipboardSyncAccount, services: ClipboardSyncServices) async throws {
        try admitCloudReset(generation)
        guard try await services.transport.account() == account else { throw ClipboardSyncServiceError.accountChanged }
        try await waitForWriteTurn()
        try admitCloudReset(generation)
    }
}
