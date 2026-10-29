import Foundation
import GRDB

extension ClipboardHistoryModule {
    /// Confirm the current replacement without accepting its key or changing either collection.
    public func prepareReplacedCloudCollectionRecovery() async throws -> ClipboardHistoryReplacedCloudCollectionRecoveryConfirmation {
        guard let services = syncServices else { throw ClipboardSyncServiceError.capabilityUnavailable }
        let state = try replacedCloudCollectionState()
        guard let previous = state.control else { throw ClipboardHistoryModuleError.operationUnavailable }
        let generation = syncGeneration
        let store = storeEpoch
        guard try await services.transport.account() == state.account else { throw ClipboardSyncServiceError.accountChanged }
        guard let replacement = try await observedSyncControl(for: state.account, generation: generation, services: services),
              state.canRecoverReplacement(replacement) else { throw ClipboardHistoryModuleError.invalidConfirmation }
        let confirmation = ClipboardHistoryReplacedCloudCollectionRecoveryConfirmation(
            account: state.account, previousControl: previous, replacementControl: replacement)
        guard try await services.transport.account() == state.account else { throw ClipboardSyncServiceError.accountChanged }
        try await waitForWriteTurn()
        try admitReplacedCloudCollectionRecovery(confirmation, generation: generation, store: store)
        return confirmation
    }

    /// Retire only this Mac's old publication authority. Explicit On later verifies
    /// the replacement key; retained history still requires fresh tag selection.
    public func recoverReplacedCloudCollection(_ confirmation: ClipboardHistoryReplacedCloudCollectionRecoveryConfirmation) async throws {
        guard let services = syncServices else { throw ClipboardSyncServiceError.capabilityUnavailable }
        try admitReplacedCloudCollectionRecovery(confirmation, generation: syncGeneration, store: storeEpoch)
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
        try admitReplacedCloudCollectionRecovery(confirmation, generation: generation, store: store)
        guard try await services.transport.account() == confirmation.account else { throw ClipboardSyncServiceError.accountChanged }
        let key = try await services.keys.load(account: confirmation.account, keyID: confirmation.previousControl.keyID)
        guard let key else { throw ClipboardSyncServiceError.keyUnavailable }
        guard key.count == 32, ClipboardSyncCodec.check(key: key, account: confirmation.account,
            keyID: confirmation.previousControl.keyID) == confirmation.previousControl.keyCheck else {
            throw ClipboardSyncServiceError.corruptData
        }
        guard try await services.transport.account() == confirmation.account else { throw ClipboardSyncServiceError.accountChanged }
        let replacement = try await observedSyncControl(for: confirmation.account, generation: generation, services: services)
        guard replacement == confirmation.replacementControl else { throw ClipboardHistoryModuleError.invalidConfirmation }
        guard try await services.transport.account() == confirmation.account else { throw ClipboardSyncServiceError.accountChanged }
        try await waitForWriteTurn()
        try admitReplacedCloudCollectionRecovery(confirmation, generation: generation, store: store)
        try syncWrite { database in
            try retireRecoveredCloudCollection(account: confirmation.account, previous: confirmation.previousControl, in: database)
        }
        retired = true
        setSyncPhase(.disabled)
        publishMutation()
        try await resumeSyncFilePreservations()
    }

    private func replacedCloudCollectionState() throws -> ClipboardSyncAccountState {
        try requiredDatabase().read { database in
            guard let accountID = try syncSettings(in: database).accountID,
                  let data = try Data.fetchOne(database, sql: "SELECT state FROM clipboard_sync_accounts WHERE id = ?", arguments: [accountID]) else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            let state = try JSONDecoder().decode(ClipboardSyncAccountState.self, from: data)
            guard state.account.identifier == accountID, state.recoverableReplacementControl != nil else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            return state
        }
    }

    private func admitReplacedCloudCollectionRecovery(_ confirmation: ClipboardHistoryReplacedCloudCollectionRecoveryConfirmation,
        generation: UInt64, store: Int) throws {
        try Task.checkCancellation()
        guard generation == syncGeneration, store == storeEpoch, availability == .ready else { throw CancellationError() }
        guard try currentSyncAccountID() == confirmation.account.identifier else { throw ClipboardSyncServiceError.accountChanged }
        let current = try replacedCloudCollectionState()
        guard current.account == confirmation.account, current.control == confirmation.previousControl,
              current.recoverableReplacementControl == confirmation.replacementControl else {
            throw ClipboardHistoryModuleError.invalidConfirmation
        }
    }
}
