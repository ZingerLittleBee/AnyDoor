import Darwin
import Dispatch
import Foundation
import GRDB

/// Dispatch owns the descriptor until its cancellation handler runs. Every
/// property is immutable and Dispatch cancellation is thread-safe/idempotent;
/// this narrow wrapper can lose unchecked Sendable when the SDK source existential
/// carries that guarantee itself. No mutable module state crosses the callback.
final class ClipboardLinkedFileObservation: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "dev.bybee.AnyDoor.clipboard.linked-files")
    let path: String
    let identity: Data
    private let source: any DispatchSourceFileSystemObject

    init?(url: URL, identity: Data, onChange: @escaping @Sendable () -> Void) {
        let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(descriptor)
            return nil
        }
        self.path = url.path
        self.identity = identity
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: Self.queue)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.activate()
    }

    func cancel() { source.cancel() }
    deinit { source.cancel() }
}

struct ClipboardLinkedLocationSource: Sendable {
    let id: UUID
    let objectID: UUID
    let url: URL
    let identity: Data
    let baseVersionID: UUID
    let baseDigest: Data
    let state: ClipboardHistoryLinkedFileLocationState
}

extension ClipboardHistoryModule {
    func stopLinkedFileObservers() {
        linkedFileMutationGate.revoke()
        for observer in linkedFileObservers.values { observer.cancel() }
        linkedFileObservers.removeAll()
        for task in linkedFileObservationTasks.values { task.cancel() }
        linkedFileObservationTasks.removeAll()
        linkedFileObservationRevisions.removeAll()
    }

    func refreshLinkedFileObservers(account: ClipboardSyncAccount, control: ClipboardSyncControl, generation: UInt64) throws {
        try admitSync(generation)
        let sources = try linkedRead { try Self.linkedLocationSources(accountID: account.identifier, epoch: control.epoch, in: $0) }
        let liveIDs = Set(sources.map(\.id))
        for id in linkedFileObservers.keys where !liveIDs.contains(id) {
            linkedFileObservers.removeValue(forKey: id)?.cancel()
            linkedFileObservationTasks.removeValue(forKey: id)?.cancel()
            linkedFileObservationRevisions.removeValue(forKey: id)
        }
        for source in sources {
            if let existing = linkedFileObservers[source.id], existing.path == source.url.path, existing.identity == source.identity { continue }
            linkedFileObservers.removeValue(forKey: source.id)?.cancel()
            linkedFileObservers[source.id] = ClipboardLinkedFileObservation(url: source.url, identity: source.identity) { [weak self] in
                Task { await self?.linkedFileDidChange(source.id, account: account, epoch: control.epoch, generation: generation) }
            }
        }
    }

    private func linkedFileDidChange(_ id: UUID, account: ClipboardSyncAccount, epoch: UUID, generation: UInt64) {
        guard generation == syncGeneration, !syncSuspended else { return }
        let revision = (linkedFileObservationRevisions[id] ?? 0) &+ 1
        linkedFileObservationRevisions[id] = revision
        linkedFileObservationTasks[id]?.cancel()
        linkedFileObservationTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                let changed = try await self.observeLinkedLocation(id, account: account, epoch: epoch, generation: generation)
                if changed { await self.retrySync() }
                await self.finishLinkedFileObservation(id, revision: revision)
            } catch ClipboardSyncServiceError.accountChanged {
                await self?.retrySync()
                await self?.finishLinkedFileObservation(id, revision: revision)
            } catch {
                await self?.finishLinkedFileObservation(id, revision: revision)
            }
        }
    }

    private func finishLinkedFileObservation(_ id: UUID, revision: UInt64) {
        guard linkedFileObservationRevisions[id] == revision else { return }
        linkedFileObservationTasks.removeValue(forKey: id)
    }

    /// Reconcile on resume/poll as well as notifications: an event is a hint,
    /// not durable evidence that a file's saved bytes are unchanged.
    func reconcileLinkedFileObservations(account: ClipboardSyncAccount, control: ClipboardSyncControl, generation: UInt64) async throws {
        let sources = try linkedRead { try Self.linkedLocationSources(accountID: account.identifier, epoch: control.epoch, in: $0) }
        for source in sources {
            _ = try await observeLinkedLocation(source.id, account: account, epoch: control.epoch, generation: generation)
        }
    }

    private func observeLinkedLocation(_ id: UUID, account: ClipboardSyncAccount, epoch: UUID, generation: UInt64) async throws -> Bool {
        guard let services = syncServices else { return false }
        try await admitSync(generation, account: account, services: services)
        guard let source = try linkedRead({ try Self.linkedLocationSources(accountID: account.identifier, epoch: epoch, id: id, in: $0).first }) else { return false }
        let inspection = Task.detached(priority: .utility) {
            Result { try ClipboardLinkedFileIO.inspect(source.url, expectedIdentity: source.identity) }
        }
        let result = await withTaskCancellationHandler {
            await inspection.value
        } onCancel: { inspection.cancel() }
        try Task.checkCancellation()
        try await admitSync(generation, account: account, services: services)
        let changed = try syncWrite { database in
            guard let current = try Self.linkedLocationSources(accountID: account.identifier, epoch: epoch, id: id, in: database).first,
                  current.identity == source.identity, current.baseVersionID == source.baseVersionID else { return false }
            let state: ClipboardHistoryLinkedFileLocationState
            let digest: Data?
            switch result {
            case .success(let proof):
                digest = proof.digest
                if current.state == .conflict { state = .conflict }
                else if proof.digest != current.baseDigest { state = .localChanges }
                else { state = current.state == .pendingUpload ? .pendingUpload : .current }
            case .failure:
                digest = nil
                state = .unavailable
            }
            let previous = try Data.fetchOne(database, sql: "SELECT observed_digest FROM clipboard_sync_linked_locations WHERE id = ?", arguments: [id.uuidString])
            guard state != current.state || digest != previous else { return false }
            try database.execute(sql: "UPDATE clipboard_sync_linked_locations SET state = ?, observed_digest = ? WHERE id = ?",
                arguments: [state.rawValue, digest, id.uuidString])
            try Self.bumpHistoryRevision(in: database)
            return true
        }
        if changed { publishMutation() }
        return changed
    }

    static func linkedLocationSources(accountID: String, epoch: UUID, id: UUID? = nil, in database: Database) throws -> [ClipboardLinkedLocationSource] {
        try Row.fetchAll(database, SQLRequest<Row>(literal: """
            SELECT location.* FROM clipboard_sync_linked_locations AS location
            WHERE location.account_id = \(accountID) AND location.epoch = \(epoch.uuidString)
              AND (\(id?.uuidString) IS NULL OR location.id = \(id?.uuidString))
              AND EXISTS (SELECT 1 FROM clipboard_sync_file_members AS member
                JOIN clipboard_entries AS entry ON entry.id = member.entry_id
                WHERE member.account_id = location.account_id AND member.epoch = location.epoch
                  AND member.object_id = location.object_id AND \(SQL(sql: liveSyncFileMember))
                  AND (\(syncEntryPublicationAuthority(accountID: accountID))))
            ORDER BY location.id
            """)).map { row in
                guard let id = UUID(uuidString: row["id"]), let objectID = UUID(uuidString: row["object_id"]),
                      let base = UUID(uuidString: row["base_version_id"]),
                      let state = ClipboardHistoryLinkedFileLocationState(rawValue: row["state"]) else {
                    throw ClipboardHistoryModuleError.storageFailure
                }
                return ClipboardLinkedLocationSource(id: id, objectID: objectID, url: URL(fileURLWithPath: row["path"]),
                    identity: row["identity"], baseVersionID: base, baseDigest: row["base_digest"], state: state)
            }
    }
}
