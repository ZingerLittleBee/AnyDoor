import CryptoKit
import Foundation
import GRDB

extension ClipboardHistoryModule {
    public func syncStatus() -> ClipboardHistorySyncStatus {
        guard let database, availability == .ready else { return ClipboardHistorySyncStatus() }
        do {
            return try database.read { database in
                let settings = try syncSettings(in: database)
                let recovery = try syncRecovery(in: database)
                var reset = try cloudReset(in: database)?.status
                if let current = reset, current.isPending, syncPhase == .failed(.localStorage) {
                    reset = .init(stage: current.stage, deletedRecordCount: current.deletedRecordCount, failure: syncPhase)
                }
                let phase = syncPhase == .disabled ? recovery.phase ?? .connecting : syncPhase
                let accountID = settings.accountID ?? ""
                let data = try Data.fetchOne(database, sql: "SELECT state FROM clipboard_sync_accounts WHERE id = ?", arguments: [accountID])
                let state = try data.map { try JSONDecoder().decode(ClipboardSyncAccountState.self, from: $0) }
                guard settings.enabled else {
                    return ClipboardHistorySyncStatus(phase: phase == .failed(.accountChanged) ? phase : .disabled, cloudReset: reset, canClearCloudData: state?.control != nil)
                }
                let uploaded = try Int.fetchOne(database, sql: """
                    SELECT COUNT(DISTINCT subject_id) FROM clipboard_sync_outbox WHERE account_id = ? AND kind = 'entry' AND acknowledged = 1
                    """, arguments: [accountID]) ?? 0
                let received = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM clipboard_sync_entries WHERE account_id = ? AND origin = 'remote'",
                    arguments: [accountID]) ?? 0
                return ClipboardHistorySyncStatus(isEnabled: true,
                    phase: phase,
                    uploadedEntryCount: uploaded, receivedEntryCount: received,
                    withdrawnEntryCount: try syncWithdrawnCount(accountID: accountID, in: database), lastCompletedAt: state?.lastCompletedAt, cloudReset: reset, canClearCloudData: state?.control != nil)
            }
        } catch {
            return ClipboardHistorySyncStatus(isEnabled: true, phase: .failed(.localStorage))
        }
    }

    public func setSyncEnabled(_ enabled: Bool) async throws {
        let generation = await stopSyncTasks()
        guard generation == syncGeneration else { return }
        _ = try await writableDatabase()
        guard generation == syncGeneration else { return }
        if enabled, let reset = try currentCloudReset(), reset.status.isPending {
            guard let services = syncServices else { throw ClipboardSyncServiceError.capabilityUnavailable }
            let account = try await services.transport.account()
            try await waitForWriteTurn()
            guard generation == syncGeneration else { return }
            if account == reset.account {
                syncSuspended = false
                await retrySync()
                return
            }
        }
        try syncWrite { database in
            try database.execute(sql: "UPDATE clipboard_sync_reset SET activation_authorized = ? WHERE id = 1", arguments: [enabled])
            try database.execute(sql: "UPDATE clipboard_sync_settings SET enabled = ? WHERE id = 1", arguments: [enabled])
            try database.execute(sql: "UPDATE clipboard_sync_recovery SET phase = NULL WHERE id = 1")
        }
        setSyncPhase(enabled ? .connecting : .disabled)
        let pendingReset = (try? hasPendingCloudResets()) ?? false
        guard enabled || pendingReset else { return }
        syncSuspended = false
        await runSync(allowAccountBinding: enabled)
    }

    public func setSyncTagSelected(_ tagID: String, selected: Bool) async throws {
        _ = try await writableDatabase()
        try syncWrite { database in
            guard try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM clipboard_tag_definitions WHERE id = ?)",
                                    arguments: [tagID]) == true else { throw ClipboardHistoryModuleError.tagDefinitionNotFound }
            let accountID = try syncSettings(in: database).accountID ?? ""
            try database.execute(sql: """
                INSERT INTO clipboard_sync_tags(account_id, tag_id, selected, locally_authorized) VALUES (?, ?, ?, 1)
                ON CONFLICT(account_id, tag_id) DO UPDATE SET selected = excluded.selected, locally_authorized = 1
                """, arguments: [accountID, tagID, selected])
            if selected {
                try database.execute(sql: """
                    DELETE FROM clipboard_sync_reset_exclusions WHERE account_id = ?
                      AND local_entry_id IN (SELECT entry_id FROM clipboard_entry_tags WHERE tag_id = ?)
                    """, arguments: [accountID, tagID])
                try database.execute(sql: """
                    DELETE FROM clipboard_sync_tag_blocked_entries WHERE account_id = ?
                      AND local_entry_id IN (SELECT entry_id FROM clipboard_entry_tags WHERE tag_id = ?)
                    """, arguments: [accountID, tagID])
            }
            if selected, let activation = try recordExplicitSyncTagActivation(tagID, in: database) {
                try authorizeSyncRejoin(tagID: tagID, revision: activation, in: database)
            }
            try recordSyncWithdrawals(in: database)
            try Self.bumpHistoryRevision(in: database)
        }
        publishSyncStatus()
        if !syncSuspended { await retrySync() }
    }

    /// Resumes only stored local consent, after the host has completed migration.
    public func resumeSync() async {
        guard availability == .ready else { return }
        let pendingReset = (try? hasPendingCloudResets()) ?? false
        guard syncStatus().isEnabled || pendingReset else { return }
        syncSuspended = false
        await retrySyncAutomatically()
    }

    /// Process shutdown/store replacement does not revoke persisted participation.
    public func suspendSync() async {
        _ = await stopSyncTasks()
    }

    func stopSyncTasks() async -> UInt64 {
        syncSuspended = true
        stopLinkedFileObservers()
        syncGeneration &+= 1
        syncAccountBindingGeneration = nil
        let generation = syncGeneration
        syncPollTask?.cancel()
        syncPollTask = nil
        let pending = syncTask
        syncTask = nil
        pending?.cancel()
        await syncServices?.transport.cancel()
        await pending?.value
        if availability == .ready { try? await recoverLocalLinkedFileApplications() }
        return generation
    }

    public func retrySync() async {
        guard !syncSuspended else { return }
        do {
            try syncWrite { database in
                try database.execute(sql: """
                    UPDATE clipboard_sync_file_retries SET retry_not_before = 0
                    WHERE account_id = (SELECT account_id FROM clipboard_sync_settings WHERE id = 1)
                    """)
            }
        } catch {
            setSyncPhase(.failed(.localStorage))
            return
        }
        await runSync(allowAccountBinding: false)
    }

    func retrySyncAutomatically() async { await runSync(allowAccountBinding: false) }

    private func runSync(allowAccountBinding: Bool) async {
        guard !syncSuspended else { return }
        if let syncTask { await syncTask.value; return }
        if allowAccountBinding { syncAccountBindingGeneration = syncGeneration }
        do {
            let recovery = try currentSyncRecovery()
            if let deadline = recovery.retryNotBefore, deadline > now() {
                setSyncPhase(.failed(.network))
                scheduleSync()
                return
            }
        } catch {
            setSyncPhase(.failed(.localStorage))
            return
        }
        let generation = syncGeneration
        let bindingAuthorized = syncAccountBindingGeneration == generation
        let pendingReset = (try? hasPendingCloudResets()) ?? false
        let task = Task {
            if pendingReset && !bindingAuthorized { await self.discoverPendingCloudReset(generation: generation) }
            else { await self.performSync(generation: generation, allowAccountBinding: bindingAuthorized) }
        }
        syncTask = task
        await task.value
        guard generation == syncGeneration else { return }
        syncTask = nil
        scheduleSync()
    }

    func scheduleSync() {
        guard !syncSuspended, syncTask == nil, syncPollTask == nil,
              let pollingInterval = syncServices?.pollingInterval else { return }
        let retryNotBefore: Date?
        do { retryNotBefore = try requiredDatabase().read { try syncRecovery(in: $0).retryNotBefore } }
        catch { setSyncPhase(.failed(.localStorage)); return }
        let remainingDelay = retryNotBefore.map { max(0, $0.timeIntervalSince(now())) } ?? 0
        let interval = max(pollingInterval, .seconds(remainingDelay))
        syncPollTask = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard let self else { return }
            await self.syncPollingFired()
        }
    }

    private func syncPollingFired() async {
        syncPollTask = nil
        await retrySyncAutomatically()
    }

    func receiveSyncChanges(account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data,
                                    state initial: ClipboardSyncAccountState, services: ClipboardSyncServices,
                                    generation: UInt64) async throws -> ClipboardSyncAccountState {
        var state = initial
        var more = true
        while more {
            let page = try await services.transport.changes(for: account, control: control, cursor: state.cursor)
            try await admitSync(generation, account: account, services: services)
            var unavailableContent = false
            for record in page.records where record.epoch == control.epoch {
                // A body is discovered without downloading it. Its encrypted
                // entry descriptor authorizes a separate version download.
                try await waitForWriteTurn()
                try admitSync(generation)
                try rememberDiscoveredSyncRecord(record, account: account)
                if record.kind == .fileBody { continue }
                guard !((try hasReceivedSyncRecord(record, account: account))) else { continue }
                let chunks: [Data]
                do { chunks = try await services.transport.download(record, for: account) }
                catch ClipboardSyncServiceError.recordUnavailable {
                    unavailableContent = true
                    continue
                }
                try await admitSync(generation, account: account, services: services)
                let content = try ClipboardSyncCodec.open(record, chunks: chunks, account: account, control: control, key: key)
                try await waitForWriteTurn()
                try admitSync(generation)
                try importSyncContent(content, record: record, account: account)
                if case .deletion = content { try await resumeSyncFilePreservations() }
            }
            // A content operation can disappear after metadata discovery. Apply
            // available retirement events, but do not acknowledge a missing body.
            // The next discovery must confirm its removal instead of hiding loss.
            guard !unavailableContent else { throw ClipboardSyncServiceError.recordUnavailable }
            state.cursor = page.cursor
            try syncWrite { try saveSyncAccount(state, in: $0) }
            more = page.hasMore
        }
        return state
    }

    func performSync(generation: UInt64, allowAccountBinding: Bool) async {
        guard let services = syncServices else {
            await finishSync(.capabilityUnavailable, generation: generation)
            return
        }
        do {
            try admitSync(generation)
            setSyncPhase(.connecting)
            let account = try await services.transport.account()
            try admitSync(generation)
            _ = try await writableDatabase()
            try admitSync(generation)
            if let reset = try currentCloudReset(accountID: account.identifier), reset.status.isPending {
                try syncWrite { database in
                    try database.execute(sql: "UPDATE clipboard_sync_settings SET account_id = ?, enabled = 0 WHERE id = 1",
                        arguments: [account.identifier])
                }
                await performCloudReset(generation: generation)
                return
            }
            var state = try syncWrite { database in
                let previous = try syncSettings(in: database).accountID
                if let previous, previous != account.identifier, !allowAccountBinding {
                    throw ClipboardSyncServiceError.accountChanged
                }
                if previous == nil {
                    try database.execute(sql: "UPDATE clipboard_sync_tags SET account_id = ? WHERE account_id = ''", arguments: [account.identifier])
                }
                try database.execute(sql: "UPDATE clipboard_sync_settings SET account_id = ? WHERE id = 1", arguments: [account.identifier])
                return try syncAccountState(account, in: database)
            }
            syncAccountBindingGeneration = nil
            var control = try await services.transport.control(for: account)
            try await admitSync(generation, account: account, services: services)
            if control == nil {
                guard state.control == nil else { throw ClipboardSyncServiceError.missingRemoteState }
                if state.candidate == nil {
                    let keyID = UUID()
                    let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                    let persisted = try await services.keys.create(account: account, keyID: keyID, key: key)
                    try await admitSync(generation, account: account, services: services)
                    guard persisted == key else { throw ClipboardSyncServiceError.corruptData }
                    state.candidate = ClipboardSyncControl(accountID: account.identifier, keyID: keyID,
                        keyCheck: ClipboardSyncCodec.check(key: key, account: account, keyID: keyID),
                        epoch: UUID(), phase: "active", serverToken: nil)
                    try syncWrite { try saveSyncAccount(state, in: $0) }
                }
                guard let candidate = state.candidate else { throw ClipboardSyncServiceError.corruptData }
                let candidateKey = try await services.keys.load(account: account, keyID: candidate.keyID)
                try await admitSync(generation, account: account, services: services)
                guard let candidateKey else {
                    await finishSync(.waitingForKey, generation: generation)
                    return
                }
                guard candidateKey.count == 32,
                      ClipboardSyncCodec.check(key: candidateKey, account: account, keyID: candidate.keyID) == candidate.keyCheck else {
                    throw ClipboardSyncServiceError.corruptData
                }
                control = try await services.transport.createControl(candidate, for: account)
                try await admitSync(generation, account: account, services: services)
            }
            guard var control, control.accountID == account.identifier else { throw ClipboardSyncServiceError.missingRemoteState }
            let activationAuthorized = try cloudActivationAuthorized()
            if let previous = state.control, previous.keyID != control.keyID || previous.keyCheck != control.keyCheck {
                throw ClipboardSyncServiceError.corruptData
            }
            if control.phase == "resetting" ||
                (!activationAuthorized && (control.phase != "active" || state.control.map { $0.epoch != control.epoch } == true)) {
                try stopForRetiredCollection(control, state: &state)
                try await resumeSyncFilePreservations()
                return
            }
            if control.phase == "stopped" {
                let key = try await services.keys.load(account: account, keyID: control.keyID)
                try await admitSync(generation, account: account, services: services)
                guard let key else { await finishSync(.waitingForKey, generation: generation); return }
                guard key.count == 32, ClipboardSyncCodec.check(key: key, account: account, keyID: control.keyID) == control.keyCheck else {
                    throw ClipboardSyncServiceError.corruptData
                }
                if state.candidate == nil || state.candidate?.epoch == state.control?.epoch {
                    state.candidate = ClipboardSyncControl(accountID: account.identifier, keyID: control.keyID,
                        keyCheck: control.keyCheck, epoch: UUID(), phase: "active", serverToken: nil)
                    try syncWrite { try saveSyncAccount(state, in: $0) }
                }
                guard let candidate = state.candidate else { throw ClipboardSyncServiceError.corruptData }
                control = try await services.transport.transition(control, to: "active", epoch: candidate.epoch, for: account)
                try await admitSync(generation, account: account, services: services)
            }
            guard control.phase == "active" else { throw ClipboardSyncServiceError.missingRemoteState }
            if let previous = state.control, previous.epoch != control.epoch {
                try syncWrite { try retireLocalSyncCollection(accountID: account.identifier, in: $0) }
                try await resumeSyncFilePreservations()
                state.cursor = nil
            }
            state.candidate = nil
            try syncWrite { database in
                try database.execute(sql: "UPDATE clipboard_sync_reset SET activation_authorized = 0 WHERE id = 1")
                try database.execute(sql: "DELETE FROM clipboard_sync_resets WHERE account_id = ?", arguments: [account.identifier])
            }
            state.control = control
            try syncWrite { try saveSyncAccount(state, in: $0) }
            let loadedKey = try await services.keys.load(account: account, keyID: control.keyID)
            try await admitSync(generation, account: account, services: services)
            guard let key = loadedKey else {
                await finishSync(.waitingForKey, generation: generation)
                return
            }
            guard key.count == 32, ClipboardSyncCodec.check(key: key, account: account, keyID: control.keyID) == control.keyCheck else {
                throw ClipboardSyncServiceError.corruptData
            }
            setSyncPhase(.transferring)
            deferredSyncFileFailure = nil
            if try needsSyncTextRootReplay(account: account, control: control) {
                state.cursor = nil
            }
            state = try await receiveSyncChanges(account: account, control: control, key: key,
                state: state, services: services, generation: generation)
            try syncWrite { try Self.seedInitialLinkedFileLocations(in: $0) }
            try await resumeFileConflictResolutions(account: account, control: control)
            try await reconcileLinkedFileObservations(account: account, control: control, generation: generation)
            try await receivePendingSyncFiles(account: account, control: control, key: key,
                services: services, generation: generation)
            try await prepareSyncFiles(account: account, control: control, key: key, generation: generation)
            try syncWrite { try Self.seedInitialLinkedFileLocations(in: $0) }
            try await reconcileLinkedFileObservations(account: account, control: control, generation: generation, onlyUnproven: true)
            try await reconcileLinkedFileVersions(account: account, control: control, generation: generation)
            // A location processed earlier in this pass also receives a version
            // just frozen from another local association, independent of ID order.
            try await reconcileLinkedFileVersions(account: account, control: control, generation: generation, canPublish: false)
            try refreshLinkedFileObservers(account: account, control: control, generation: generation)
            try await waitForWriteTurn()
            try admitSync(generation)
            var conflicts = 0
            var stagedRevision: Int64?
            while true {
                // Drain mutations made while a provider request was suspended,
                // including rejoining during cleanup. An unchanged history does
                // not need another full backfill scan for every uploaded record.
                let revision = try syncWrite { try Self.historyRevision(in: $0) }
                if stagedRevision != revision {
                    try await prepareSyncFileRejoins(account: account, control: control, key: key, generation: generation)
                    try stageSyncBackfill(account: account, control: control, key: key)
                    stagedRevision = try syncWrite { try Self.historyRevision(in: $0) }
                }
                let ordinary = try nextSyncUpload(account: account, control: control)
                let restoration = ordinary == nil ? try nextSyncFileRestoration(account: account, control: control) : nil
                if let upload = ordinary ?? restoration {
                    let restoring = restoration != nil
                    do {
                        try await admitSync(generation, account: account, services: services)
                        guard try syncWrite({ database in
                            if restoring {
                                guard try syncFileRestorationIsPending(upload.record, account: account, control: control, in: database) else { return false }
                                try database.execute(sql: "UPDATE clipboard_sync_subject_records SET purged = 0 WHERE account_id = ? AND epoch = ? AND record_id = ?",
                                    arguments: [account.identifier, control.epoch.uuidString, upload.record.recordID])
                                return true
                            }
                            return try Bool.fetchOne(database, SQLRequest<Bool>(literal: """
                                SELECT EXISTS(SELECT 1 FROM clipboard_sync_outbox AS outbox
                                  WHERE outbox.record_id = \(upload.record.recordID) AND outbox.account_id = \(account.identifier)
                                    AND outbox.acknowledged = 0 AND (\(Self.syncFileOutboxAuthority(accountID: account.identifier))))
                                """)) ?? false
                        }) else { continue }
                        let committed: ClipboardSyncControl
                        switch upload {
                        case .inline(let value):
                            committed = try await services.transport.commit(value, for: account, control: control)
                        case .file(let value):
                            committed = try await services.transport.commitFile(value, for: account, control: control) { bytes in
                                if restoring {
                                    try await self.recordSyncFileRestorationProgress(bytes, record: value.record, account: account, generation: generation)
                                } else {
                                    try await self.recordSyncFileUploadProgress(bytes, record: value.record, generation: generation)
                                }
                            }
                        }
                        try await admitSync(generation, account: account, services: services)
                        guard committed.epoch == control.epoch, committed.keyID == control.keyID else {
                            throw ClipboardSyncServiceError.missingRemoteState
                        }
                        control = committed
                        state.control = committed
                        _ = try await writableDatabase()
                        try admitSync(generation)
                        try syncWrite { database in
                            if restoring {
                                try recordSyncFileRestorationAcknowledged(upload.record, account: account, in: database)
                            } else {
                                try database.execute(sql: "UPDATE clipboard_sync_outbox SET acknowledged = 1 WHERE record_id = ?",
                                    arguments: [upload.record.recordID])
                                try database.execute(sql: "DELETE FROM clipboard_sync_chunks WHERE record_id = ?", arguments: [upload.record.recordID])
                                if upload.record.kind == .fileBody {
                                    try recordSyncFileRestorationAcknowledged(upload.record, account: account, in: database)
                                }
                            }
                            try saveSyncAccount(state, in: database)
                            if upload.record.kind == .fileBody { try Self.bumpHistoryRevision(in: database) }
                        }
                        if upload.record.kind == .fileBody { publishMutation() }
                        conflicts = 0
                    } catch ClipboardSyncServiceError.conflict {
                        conflicts += 1
                        guard conflicts < 4 else { throw ClipboardSyncServiceError.network(retryAfter: nil) }
                        guard let refreshed = try await services.transport.control(for: account),
                              refreshed.epoch == control.epoch, refreshed.keyID == control.keyID, refreshed.phase == "active" else {
                            throw ClipboardSyncServiceError.missingRemoteState
                        }
                        try await admitSync(generation, account: account, services: services)
                        control = refreshed
                        state.control = refreshed
                        // A new control token may authorize a deletion or withdrawal.
                        // Import that authority before deciding whether the old outbox still exists.
                        state = try await receiveSyncChanges(account: account, control: control, key: key,
                            state: state, services: services, generation: generation)
                    } catch {
                        try recordSyncFileUploadFailure(error, record: upload.record, generation: generation)
                        throw error
                    }
                } else if let retired = try nextDeletedSyncContent(account: account, control: control) {
                    do {
                        try await admitSync(generation, account: account, services: services)
                        let cleaned = try await services.transport.purge(retired, for: account, control: control)
                        try await admitSync(generation, account: account, services: services)
                        guard cleaned.epoch == control.epoch, cleaned.keyID == control.keyID, cleaned.phase == "active" else {
                            throw ClipboardSyncServiceError.missingRemoteState
                        }
                        control = cleaned
                        state.control = cleaned
                        _ = try await writableDatabase()
                        try admitSync(generation)
                        try syncWrite { database in
                            try database.execute(sql: "UPDATE clipboard_sync_subject_records SET purged = 1 WHERE account_id = ? AND epoch = ? AND record_id = ?",
                                arguments: [account.identifier, control.epoch.uuidString, retired.recordID])
                            try saveSyncAccount(state, in: database)
                        }
                        conflicts = 0
                    } catch ClipboardSyncServiceError.conflict {
                        conflicts += 1
                        guard conflicts < 4 else { throw ClipboardSyncServiceError.network(retryAfter: nil) }
                        guard let refreshed = try await services.transport.control(for: account),
                              refreshed.epoch == control.epoch, refreshed.keyID == control.keyID, refreshed.phase == "active" else {
                            throw ClipboardSyncServiceError.missingRemoteState
                        }
                        try await admitSync(generation, account: account, services: services)
                        control = refreshed
                        state.control = refreshed
                        state = try await receiveSyncChanges(account: account, control: control, key: key,
                            state: state, services: services, generation: generation)
                    }
                } else {
                    break
                }
            }
            state.lastCompletedAt = now()
            try await resumeSyncFilePreservations()
            try acknowledgeLinkedFileVersions(account: account, control: control)
            try completeFileConflictResolutions(account: account, control: control)
            try syncWrite { try saveSyncAccount(state, in: $0) }
            await finishSync(deferredSyncFileFailure ?? .upToDate, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            guard generation == syncGeneration, !syncSuspended else { return }
            var retryAfter: TimeInterval?
            if case .network(let delay) = error as? ClipboardSyncServiceError { retryAfter = delay }
            await finishSync(syncFailurePhase(error), generation: generation, retryAfter: retryAfter)
        }
    }

    func finishSync(_ phase: ClipboardHistorySyncPhase, generation: UInt64,
                            retryAfter: TimeInterval? = nil) async {
        do {
            try await waitForWriteTurn()
            try admitSync(generation)
            let deadline = retryAfter.flatMap { delay in
                delay.isFinite && delay > 0 ? now().addingTimeInterval(delay) : nil
            }
            try syncWrite { database in
                let data = phase == .upToDate ? nil : try JSONEncoder().encode(phase)
                try database.execute(sql: "UPDATE clipboard_sync_recovery SET phase = ?, retry_not_before = ? WHERE id = 1",
                    arguments: [data, deadline?.timeIntervalSince1970])
                if phase == .failed(.accountChanged) {
                    try database.execute(sql: "UPDATE clipboard_sync_settings SET enabled = 0 WHERE id = 1")
                }
            }
            if phase == .failed(.accountChanged) {
                syncSuspended = true
                stopLinkedFileObservers()
                syncAccountBindingGeneration = nil
                syncPollTask?.cancel()
                syncPollTask = nil
            }
            setSyncPhase(phase)
        } catch is CancellationError {
            return
        } catch {
            guard generation == syncGeneration, !syncSuspended else { return }
            syncSuspended = true
            stopLinkedFileObservers()
            setSyncPhase(.failed(.localStorage))
        }
    }

    func admitSync(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == syncGeneration, !syncSuspended, availability == .ready,
              try requiredDatabase().read({ try syncSettings(in: $0).enabled }) else { throw CancellationError() }
    }

    func admitSync(_ generation: UInt64, account: ClipboardSyncAccount, services: ClipboardSyncServices) async throws {
        try admitSync(generation)
        let observed: ClipboardSyncAccount
        do { observed = try await services.transport.account() }
        catch ClipboardSyncServiceError.corruptData { throw ClipboardSyncServiceError.corruptAuthority }
        guard observed == account else { throw ClipboardSyncServiceError.accountChanged }
        try await waitForWriteTurn()
        try admitSync(generation)
    }

    func syncFailurePhase(_ error: Error) -> ClipboardHistorySyncPhase {
        if ClipboardSyncFileErrors.isAccessDenied(error) { return .failed(.localFileAccessDenied) }
        if ClipboardSyncFileErrors.isSourceChanged(error) { return .failed(.sourceChanged) }
        guard let error = error as? ClipboardSyncServiceError else { return .failed(.localStorage) }
        switch error {
        case .accountUnavailable: return .waitingForAccount
        case .accountChanged: return .failed(.accountChanged)
        case .capabilityUnavailable: return .capabilityUnavailable
        case .keyLocked: return .keyLocked
        case .keyUnavailable: return .waitingForKey
        case .accessDenied: return .accessDenied
        case .network, .conflict: return .failed(.network)
        case .quota: return .failed(.quota)
        case .localStorage: return .failed(.localStorage)
        case .localFileAccessDenied: return .failed(.localFileAccessDenied)
        case .recordUnavailable: return .failed(.network)
        case .missingRemoteState: return .failed(.recoveryRequired)
        case .corruptData, .corruptAuthority: return .failed(.corruptData)
        case .unsupportedVersion: return .failed(.unsupportedVersion)
        }
    }

    func setSyncPhase(_ phase: ClipboardHistorySyncPhase) {
        syncPhase = phase
        publishSyncStatus()
    }

    func publishSyncStatus() {
        notificationCenter.post(name: .clipboardHistorySyncDidChange, object: nil)
    }
}
