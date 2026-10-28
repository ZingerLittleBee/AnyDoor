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
                let phase = syncPhase == .disabled ? recovery.phase ?? .connecting : syncPhase
                guard settings.enabled else {
                    return ClipboardHistorySyncStatus(phase: phase == .failed(.accountChanged) ? phase : .disabled)
                }
                let accountID = settings.accountID ?? ""
                let uploaded = try Int.fetchOne(database, sql: """
                    SELECT COUNT(DISTINCT subject_id) FROM clipboard_sync_outbox WHERE account_id = ? AND kind = 'entry' AND acknowledged = 1
                    """, arguments: [accountID]) ?? 0
                let received = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM clipboard_sync_entries WHERE account_id = ? AND origin = 'remote'",
                    arguments: [accountID]) ?? 0
                let data = try Data.fetchOne(database, sql: "SELECT state FROM clipboard_sync_accounts WHERE id = ?", arguments: [accountID])
                let state = try data.map { try JSONDecoder().decode(ClipboardSyncAccountState.self, from: $0) }
                return ClipboardHistorySyncStatus(isEnabled: true,
                    phase: phase,
                    uploadedEntryCount: uploaded, receivedEntryCount: received, lastCompletedAt: state?.lastCompletedAt)
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
        try syncWrite { database in
            try database.execute(sql: "UPDATE clipboard_sync_settings SET enabled = ? WHERE id = 1", arguments: [enabled])
            try database.execute(sql: "UPDATE clipboard_sync_recovery SET phase = NULL WHERE id = 1")
        }
        setSyncPhase(enabled ? .connecting : .disabled)
        guard enabled else { return }
        syncSuspended = false
        await runSync(allowAccountBinding: true)
    }

    public func setSyncTagSelected(_ tagID: String, selected: Bool) async throws {
        _ = try await writableDatabase()
        try syncWrite { database in
            guard try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM clipboard_tag_definitions WHERE id = ?)",
                                    arguments: [tagID]) == true else { throw ClipboardHistoryModuleError.tagDefinitionNotFound }
            let accountID = try syncSettings(in: database).accountID ?? ""
            // Final-tag withdrawal has its own lifecycle. Additional selected
            // collections already share the same any-tag eligibility query.
            guard try selected || canDeselectSyncTag(tagID, accountID: accountID, in: database) else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            try database.execute(sql: """
                INSERT INTO clipboard_sync_tags(account_id, tag_id, selected, locally_authorized) VALUES (?, ?, ?, 1)
                ON CONFLICT(account_id, tag_id) DO UPDATE SET selected = excluded.selected, locally_authorized = 1
                """, arguments: [accountID, tagID, selected])
            if selected {
                try database.execute(sql: """
                    DELETE FROM clipboard_sync_tag_blocked_entries WHERE account_id = ?
                      AND local_entry_id IN (SELECT entry_id FROM clipboard_entry_tags WHERE tag_id = ?)
                    """, arguments: [accountID, tagID])
            }
            try Self.bumpHistoryRevision(in: database)
        }
        publishSyncStatus()
        if !syncSuspended { await retrySync() }
    }

    /// Resumes only stored local consent, after the host has completed migration.
    public func resumeSync() async {
        guard availability == .ready, syncStatus().isEnabled else { return }
        syncSuspended = false
        await retrySync()
    }

    /// Process shutdown/store replacement does not revoke persisted participation.
    public func suspendSync() async {
        _ = await stopSyncTasks()
    }

    private func stopSyncTasks() async -> UInt64 {
        syncSuspended = true
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
        return generation
    }

    public func retrySync() async { await runSync(allowAccountBinding: false) }

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
        let task = Task { await self.performSync(generation: generation, allowAccountBinding: bindingAuthorized) }
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
        await retrySync()
    }

    private func performSync(generation: UInt64, allowAccountBinding: Bool) async {
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
            guard var control, control.accountID == account.identifier, control.phase == "active" else {
                throw ClipboardSyncServiceError.missingRemoteState
            }
            if let previous = state.control,
               previous.keyID != control.keyID || previous.epoch != control.epoch {
                throw ClipboardSyncServiceError.missingRemoteState
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
            if try needsSyncTextRootReplay(account: account, control: control) {
                state.cursor = nil
            }
            var more = true
            while more {
                let page = try await services.transport.changes(for: account, control: control, cursor: state.cursor)
                try await admitSync(generation, account: account, services: services)
                for record in page.records where record.epoch == control.epoch {
                    // A body is discovered without downloading it. Its encrypted
                    // entry descriptor authorizes a separate version download.
                    if record.kind == .fileBody { continue }
                    guard !((try hasReceivedSyncRecord(record, account: account))) else { continue }
                    let chunks = try await services.transport.download(record, for: account)
                    try await admitSync(generation, account: account, services: services)
                    let content = try ClipboardSyncCodec.open(record, chunks: chunks, account: account, control: control, key: key)
                    try await waitForWriteTurn()
                    try admitSync(generation)
                    try importSyncContent(content, record: record, account: account)
                }
                state.cursor = page.cursor
                try syncWrite { try saveSyncAccount(state, in: $0) }
                more = page.hasMore
            }
            try await receivePendingSyncFiles(account: account, control: control, key: key,
                services: services, generation: generation)
            try await prepareSyncFiles(account: account, control: control, key: key, generation: generation)
            try await waitForWriteTurn()
            try admitSync(generation)
            try stageSyncBackfill(account: account, control: control, key: key)
            var conflicts = 0
            while let upload = try nextSyncUpload(account: account, control: control) {
                do {
                    try await admitSync(generation, account: account, services: services)
                    let committed: ClipboardSyncControl
                    switch upload {
                    case .inline(let value):
                        committed = try await services.transport.commit(value, for: account, control: control)
                    case .file(let value):
                        committed = try await services.transport.commitFile(value, for: account, control: control) { bytes in
                            try await self.recordSyncFileUploadProgress(bytes, record: value.record, generation: generation)
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
                        try database.execute(sql: "UPDATE clipboard_sync_outbox SET acknowledged = 1 WHERE record_id = ?",
                            arguments: [upload.record.recordID])
                        try database.execute(sql: "DELETE FROM clipboard_sync_chunks WHERE record_id = ?", arguments: [upload.record.recordID])
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
                } catch {
                    try recordSyncFileUploadFailure(error, record: upload.record, generation: generation)
                    throw error
                }
            }
            state.lastCompletedAt = now()
            try syncWrite { try saveSyncAccount(state, in: $0) }
            await finishSync(.upToDate, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            guard generation == syncGeneration, !syncSuspended else { return }
            var retryAfter: TimeInterval?
            if case .network(let delay) = error as? ClipboardSyncServiceError { retryAfter = delay }
            await finishSync(syncFailurePhase(error), generation: generation, retryAfter: retryAfter)
        }
    }

    private func finishSync(_ phase: ClipboardHistorySyncPhase, generation: UInt64,
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
        guard try await services.transport.account() == account else { throw ClipboardSyncServiceError.accountChanged }
        try await waitForWriteTurn()
        try admitSync(generation)
    }

    private func syncFailurePhase(_ error: Error) -> ClipboardHistorySyncPhase {
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
        case .missingRemoteState: return .failed(.recoveryRequired)
        case .corruptData: return .failed(.corruptData)
        case .unsupportedVersion: return .failed(.unsupportedVersion)
        }
    }

    private func setSyncPhase(_ phase: ClipboardHistorySyncPhase) {
        syncPhase = phase
        publishSyncStatus()
    }

    private func publishSyncStatus() {
        notificationCenter.post(name: .clipboardHistorySyncDidChange, object: nil)
    }
}
