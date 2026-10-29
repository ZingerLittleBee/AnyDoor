import Foundation
import GRDB

extension ClipboardHistoryModule {
    /// Prepare a fresh, account-bound confirmation without changing participation.
    public func prepareMissingCloudCollectionRecovery() async throws -> ClipboardHistoryMissingCloudCollectionRecoveryConfirmation {
        guard let services = syncServices else { throw ClipboardSyncServiceError.capabilityUnavailable }
        let state = try missingCloudCollectionState()
        guard let previous = state.control else { throw ClipboardHistoryModuleError.operationUnavailable }
        let confirmation = ClipboardHistoryMissingCloudCollectionRecoveryConfirmation(account: state.account, previousControl: previous)
        let generation = syncGeneration
        let store = storeEpoch
        guard try await services.transport.account() == state.account else { throw ClipboardSyncServiceError.accountChanged }
        let absent = try await missingCloudControlIsAbsent(account: state.account, generation: generation, services: services)
        guard absent else { throw ClipboardHistoryModuleError.invalidConfirmation }
        guard try await services.transport.account() == state.account else { throw ClipboardSyncServiceError.accountChanged }
        try await waitForWriteTurn()
        try admitMissingCloudCollectionRecovery(confirmation, generation: generation, store: store)
        return confirmation
    }

    /// Retire only local publication authority. A later explicit On and fresh tag
    /// selection create and publish the new epoch; unknown cloud data is untouched.
    public func recoverMissingCloudCollection(_ confirmation: ClipboardHistoryMissingCloudCollectionRecoveryConfirmation) async throws {
        guard let services = syncServices else { throw ClipboardSyncServiceError.capabilityUnavailable }
        try admitMissingCloudCollectionRecovery(confirmation, generation: syncGeneration, store: storeEpoch)
        let wasSuspended = syncSuspended
        let generation = await stopSyncTasks()
        let store = storeEpoch
        var retired = false
        defer {
            if !retired, generation == syncGeneration, store == storeEpoch {
                syncSuspended = wasSuspended
                if !wasSuspended { scheduleSync() }
            }
        }
        _ = try await writableDatabase()
        try admitMissingCloudCollectionRecovery(confirmation, generation: generation, store: store)
        guard try await services.transport.account() == confirmation.account else { throw ClipboardSyncServiceError.accountChanged }
        let key = try await services.keys.load(account: confirmation.account, keyID: confirmation.previousControl.keyID)
        guard let key else { throw ClipboardSyncServiceError.keyUnavailable }
        guard key.count == 32, ClipboardSyncCodec.check(key: key, account: confirmation.account,
            keyID: confirmation.previousControl.keyID) == confirmation.previousControl.keyCheck else {
            throw ClipboardSyncServiceError.corruptData
        }
        let absent = try await missingCloudControlIsAbsent(account: confirmation.account, generation: generation, services: services)
        guard absent else { throw ClipboardHistoryModuleError.invalidConfirmation }
        guard try await services.transport.account() == confirmation.account else { throw ClipboardSyncServiceError.accountChanged }
        try await waitForWriteTurn()
        try admitMissingCloudCollectionRecovery(confirmation, generation: generation, store: store)
        try syncWrite { database in
            var state = try syncAccountState(confirmation.account, in: database)
            try retireLocalSyncCollection(accountID: confirmation.account.identifier, in: database)
            state.control = nil
            state.candidate = ClipboardSyncControl(accountID: confirmation.account.identifier,
                keyID: confirmation.previousControl.keyID, keyCheck: confirmation.previousControl.keyCheck,
                epoch: UUID(), phase: "active", serverToken: nil)
            state.cursor = nil
            state.lastCompletedAt = nil
            state.missingControl = nil
            try saveSyncAccount(state, in: database)
            if var reset = try cloudReset(in: database, accountID: confirmation.account.identifier), reset.status.isPending {
                reset.stage = .superseded
                reset.failure = nil
                reset.retryNotBefore = nil
                try saveCloudReset(reset, in: database)
            }
            try database.execute(sql: "UPDATE clipboard_sync_settings SET enabled = 0 WHERE id = 1")
            try database.execute(sql: "UPDATE clipboard_sync_reset SET activation_authorized = 0 WHERE id = 1")
            try database.execute(sql: "UPDATE clipboard_sync_recovery SET phase = NULL, retry_not_before = NULL WHERE id = 1")
            try Self.bumpHistoryRevision(in: database)
        }
        retired = true
        setSyncPhase(.disabled)
        publishMutation()
        try await resumeSyncFilePreservations()
    }

    private func missingCloudCollectionState() throws -> ClipboardSyncAccountState {
        try requiredDatabase().read { database in
            guard let accountID = try syncSettings(in: database).accountID,
                  let data = try Data.fetchOne(database, sql: "SELECT state FROM clipboard_sync_accounts WHERE id = ?", arguments: [accountID]) else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            let state = try JSONDecoder().decode(ClipboardSyncAccountState.self, from: data)
            guard state.account.identifier == accountID, state.control != nil, state.missingControl == true else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            return state
        }
    }

    private func admitMissingCloudCollectionRecovery(_ confirmation: ClipboardHistoryMissingCloudCollectionRecoveryConfirmation,
        generation: UInt64, store: Int) throws {
        try Task.checkCancellation()
        guard generation == syncGeneration, store == storeEpoch, availability == .ready else { throw CancellationError() }
        guard try currentSyncAccountID() == confirmation.account.identifier else { throw ClipboardSyncServiceError.accountChanged }
        let current = try missingCloudCollectionState()
        guard current.account == confirmation.account, current.control == confirmation.previousControl else {
            throw ClipboardHistoryModuleError.invalidConfirmation
        }
    }

    private func missingCloudControlIsAbsent(account: ClipboardSyncAccount, generation: UInt64,
        services: ClipboardSyncServices) async throws -> Bool {
        do { return try await observedSyncControl(for: account, generation: generation, services: services) == nil }
        catch ClipboardSyncServiceError.missingRemoteState { return true }
    }

    /// Absence is recorded only at the collection-control read boundary. Generic
    /// body, key, or provider failures never authorize starting a new collection.
    func observedSyncControl(for account: ClipboardSyncAccount, generation: UInt64,
        services: ClipboardSyncServices) async throws -> ClipboardSyncControl? {
        let result: Result<ClipboardSyncControl?, Error>
        do { result = .success(try await services.transport.control(for: account)) }
        catch ClipboardSyncServiceError.missingRemoteState { result = .failure(ClipboardSyncServiceError.missingRemoteState) }
        catch { throw error }
        try await waitForWriteTurn()
        try Task.checkCancellation()
        guard generation == syncGeneration, availability == .ready else { throw CancellationError() }
        guard try currentSyncAccountID() == account.identifier else { throw ClipboardSyncServiceError.accountChanged }
        let missing: Bool
        switch result {
        case .success(let control): missing = control == nil
        case .failure: missing = true
        }
        try syncWrite { database in
            var state = try syncAccountState(account, in: database)
            guard state.control != nil else { return }
            state.missingControl = missing ? true : nil
            try saveSyncAccount(state, in: database)
        }
        return try result.get()
    }
}
