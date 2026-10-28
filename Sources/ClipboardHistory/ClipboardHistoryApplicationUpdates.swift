import Foundation
import GRDB

extension ClipboardHistoryModule {
    public func applicationUpdatePlan(_ selection: ClipboardHistoryFileLocationSelection) async throws -> ClipboardHistoryApplicationUpdatePlan {
        let generation = syncGeneration
        try admitSync(generation)
        guard !activeApplicationUpdates.contains(selection.locationID) else { throw ClipboardHistoryApplicationUpdateError.stalePlan }
        guard let services = syncServices, let context = try linkedRead({ try syncFileContext(in: $0) }) else {
            throw ClipboardHistoryApplicationUpdateError.stalePlan
        }
        try await admitSync(generation, account: context.account, services: services)
        try await recoverLinkedFileApplications(account: context.account, control: context.control, generation: generation)
        let source = try linkedRead { try Self.linkedLocationSource(Self.linkedFileActionRow(selection, in: $0)) }
        guard source.isApplication || ClipboardApplicationPackage.requiresExplicitUpdate(source.url),
              let versions = try syncFileSelection(objectID: source.objectID), versions.latest.versionID != source.baseVersionID else {
            throw ClipboardHistoryApplicationUpdateError.stalePlan
        }
        let revision = try linkedRead { try Self.applicationVersionRevision(source.objectID,
            accountID: context.account.identifier, epoch: context.control.epoch, in: $0) }
        let inspection = Task.detached(priority: .userInitiated) {
            let sourceProof = try? ClipboardLinkedFileIO.inspect(source.url, expectedIdentity: source.identity)
            let candidate = versions.complete.flatMap { version in
                try? ClipboardLinkedFileIO.inspect(version.url, expectedIdentity: version.identity)
            }
            let witnesses = try? ClipboardApplicationWitness.inspect(source.url)
            return (sourceProof, candidate, witnesses)
        }
        let inspected = await withTaskCancellationHandler { await inspection.value } onCancel: { inspection.cancel() }
        try Task.checkCancellation()
        try await admitSync(generation, account: context.account, services: services)
        let runningGuard: ClipboardApplicationRunningGuard?
        if let existing = applicationRunningGuards[source.id], existing.linkedIdentity == source.identity {
            if let witnesses = inspected.2 { await existing.refreshWitnesses(witnesses) }
            runningGuard = existing
        }
        else if let witnesses = inspected.2 {
            runningGuard = await ClipboardApplicationRunningGuard(witnesses: witnesses, linkedIdentity: source.identity)
            applicationRunningGuards[source.id] = runningGuard
        } else { runningGuard = nil }
        let runningState = await runningGuard?.state() ?? .identityUncertain
        let state: ClipboardHistoryApplicationUpdateState
        if [.detached, .identityUncertain].contains(source.state) || inspected.0 == nil { state = .identityUncertain }
        else if source.state == .paused || source.hasPendingApplication { state = .unavailable }
        else if inspected.0?.digest != source.baseDigest { state = .localChanges }
        else if versions.hasConflict || source.state == .conflict { state = .conflict }
        else if versions.complete?.descriptor.versionID != versions.latest.versionID { state = .requiresDownload }
        else if inspected.1?.digest != versions.latest.contentDigest || inspected.1?.byteCount != versions.latest.originalByteCount { state = .unavailable }
        else if try !linkedVersion(versions.latest.versionID, descendsFrom: source.baseVersionID,
            objectID: source.objectID, account: context.account, control: context.control) { state = .conflict }
        else { state = runningState }
        let snapshot = ClipboardApplicationUpdateSnapshot(id: UUID(), accountID: context.account.identifier,
            epoch: context.control.epoch, keyID: context.control.keyID, entryID: selection.entryID.value,
            objectID: source.objectID,
            location: .init(id: source.id, path: source.url.path, identity: source.identity, revision: source.revision,
                baseVersionID: source.baseVersionID, baseDigest: source.baseDigest, state: source.state.rawValue,
                savedDigest: inspected.0?.digest, byteCount: inspected.0?.byteCount),
            versionID: versions.latest.versionID, versionRevision: revision, state: state)
        guard !activeApplicationUpdates.contains(source.id) else { throw ClipboardHistoryApplicationUpdateError.stalePlan }
        try syncWrite { database in
            let current = try Self.linkedLocationSource(Self.linkedFileActionRow(selection, in: database))
            guard current.identity == source.identity, current.baseVersionID == source.baseVersionID,
                  try Self.applicationVersionRevision(source.objectID, accountID: snapshot.accountID, epoch: snapshot.epoch, in: database) == revision else {
                throw ClipboardHistoryApplicationUpdateError.stalePlan
            }
            try database.execute(sql: "DELETE FROM clipboard_sync_application_plans WHERE location_id = ?", arguments: [source.id.uuidString])
            try database.execute(sql: "INSERT INTO clipboard_sync_application_plans VALUES (?, ?, ?, ?, 'ready', ?)",
                arguments: [snapshot.id.uuidString, snapshot.accountID, snapshot.epoch.uuidString,
                    source.id.uuidString, try JSONEncoder().encode(snapshot)])
            try database.execute(sql: "UPDATE clipboard_sync_linked_locations SET is_application = 1 WHERE id = ?", arguments: [source.id.uuidString])
        }
        return .init(id: snapshot.id, entryID: selection.entryID, objectID: source.objectID,
            locationID: source.id, locationRevision: source.revision, versionID: snapshot.versionID,
            displayName: versions.latest.displayName, locationURL: source.url, state: state)
    }

    public func requestApplicationUpdateDownload(_ plan: ClipboardHistoryApplicationUpdatePlan) async throws {
        let snapshot = try applicationUpdateSnapshot(plan)
        _ = try linkedRead { try Self.validateApplicationUpdate(snapshot, phase: "ready", in: $0) }
        try await requestSyncFileDownload(entryID: plan.entryID, objectID: snapshot.objectID, versionID: snapshot.versionID)
    }

    public func applyApplicationUpdate(_ plan: ClipboardHistoryApplicationUpdatePlan) async throws {
        let generation = syncGeneration
        try admitSync(generation)
        let snapshot = try applicationUpdateSnapshot(plan)
        switch snapshot.state {
        case .ready: break
        case .requiresDownload: throw ClipboardHistoryApplicationUpdateError.downloadRequired(snapshot.versionID)
        case .running: throw ClipboardHistoryApplicationUpdateError.running
        case .identityUncertain: throw ClipboardHistoryApplicationUpdateError.identityUncertain
        case .localChanges: throw ClipboardHistoryApplicationUpdateError.localChanges
        default: throw ClipboardHistoryApplicationUpdateError.candidateUnavailable
        }
        guard let services = syncServices, let context = try linkedRead({ try syncFileContext(in: $0) }),
              context.account.identifier == snapshot.accountID, context.control.epoch == snapshot.epoch,
              context.control.keyID == snapshot.keyID else { throw ClipboardHistoryApplicationUpdateError.stalePlan }
        try await admitSync(generation, account: context.account, services: services)
        let source = try syncWrite { database in
            let source = try Self.validateApplicationUpdate(snapshot, phase: "ready", in: database)
            guard !source.hasPendingApplication else { throw ClipboardHistoryApplicationUpdateError.stalePlan }
            try database.execute(sql: "UPDATE clipboard_sync_application_plans SET phase = 'applying' WHERE id = ?", arguments: [snapshot.id.uuidString])
            return source
        }
        activeApplicationUpdates.insert(source.id)
        defer {
            activeApplicationUpdates.remove(source.id)
            try? syncWrite { try $0.execute(sql: "DELETE FROM clipboard_sync_application_plans WHERE id = ?", arguments: [snapshot.id.uuidString]) }
        }
        guard let selection = try syncFileSelection(objectID: source.objectID), !selection.hasConflict,
              let version = selection.complete, version.descriptor.versionID == snapshot.versionID else {
            throw ClipboardHistoryApplicationUpdateError.candidateUnavailable
        }
        let inspection = Task.detached(priority: .userInitiated) {
            try ClipboardLinkedFileIO.inspect(source.url, expectedIdentity: source.identity)
        }
        let proof = try await withTaskCancellationHandler { try await inspection.value } onCancel: { inspection.cancel() }
        guard proof.digest == source.baseDigest else { throw ClipboardHistoryApplicationUpdateError.localChanges }
        try await admitSync(generation, account: context.account, services: services)
        let runningGuard: ClipboardApplicationRunningGuard
        if let existing = applicationRunningGuards[source.id], existing.linkedIdentity == source.identity { runningGuard = existing }
        else {
            let witnesses = try ClipboardApplicationWitness.inspect(source.url)
            runningGuard = await ClipboardApplicationRunningGuard(witnesses: witnesses, linkedIdentity: source.identity)
            applicationRunningGuards[source.id] = runningGuard
        }
        try await runningGuard.assertStopped()
        linkedFileMutationGate.activate(generation)
        try await applyLinkedFileVersion(version, to: source, account: context.account, control: context.control,
            generation: generation, applicationPlan: snapshot, applicationGuard: runningGuard)
        applicationRunningGuards.removeValue(forKey: source.id)
        let applied = try linkedRead { try Row.fetchOne($0, sql: "SELECT base_version_id FROM clipboard_sync_linked_locations WHERE id = ?", arguments: [source.id.uuidString]) }
        guard (applied?["base_version_id"] as String?) == snapshot.versionID.uuidString else { throw ClipboardHistoryApplicationUpdateError.stalePlan }
    }

    private func applicationUpdateSnapshot(_ plan: ClipboardHistoryApplicationUpdatePlan) throws -> ClipboardApplicationUpdateSnapshot {
        guard let data = try linkedRead({ try Data.fetchOne($0, sql: "SELECT snapshot FROM clipboard_sync_application_plans WHERE id = ?", arguments: [plan.id.uuidString]) }) else {
            throw ClipboardHistoryApplicationUpdateError.stalePlan
        }
        let snapshot = try JSONDecoder().decode(ClipboardApplicationUpdateSnapshot.self, from: data)
        guard snapshot.entryID == plan.entryID.value, snapshot.objectID == plan.objectID,
              snapshot.location.id == plan.locationID, snapshot.location.revision == plan.locationRevision,
              snapshot.versionID == plan.versionID else { throw ClipboardHistoryApplicationUpdateError.stalePlan }
        return snapshot
    }
}
