import Darwin
import Dispatch
import Foundation
import GRDB

/// Dispatch owns the descriptor until its cancellation handler runs. Both event
/// sources use the same serial queue, and the subtree stream stops before the
/// descriptor can close. Immutable ownership and synchronized native cancellation
/// justify this SDK boundary's Sendable conformance.
final class ClipboardLinkedFileObservation: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "dev.bybee.AnyDoor.clipboard.linked-files")
    let path: String
    let identity: Data
    private let source: any DispatchSourceFileSystemObject
    private let tree: ClipboardLinkedTreeObservation?

    init?(url: URL, identity: Data, onChange: @escaping @Sendable (ClipboardLinkedFileIdentityEvent) -> Void) {
        let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        var status = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &status) == 0,
              [mode_t(S_IFREG), mode_t(S_IFDIR)].contains(status.st_mode & mode_t(S_IFMT)),
              ClipboardSyncFileIO.isAvailable(path: url.path, identity: identity),
              lstat(url.path, &pathStatus) == 0,
              pathStatus.st_dev == status.st_dev, pathStatus.st_ino == status.st_ino else {
            close(descriptor)
            return nil
        }
        self.path = url.path
        self.identity = identity
        let notify: @Sendable () -> Void = {
            var status = stat()
            let unlinked = fstat(descriptor, &status) == 0 && status.st_nlink == 0
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let path: URL?
            if fcntl(descriptor, F_GETPATH, &buffer) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                path = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
            } else { path = nil }
            onChange(ClipboardLinkedFileIdentityEvent(identity: identity, candidate: path, unlinked: unlinked))
        }
        if status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
            guard let observation = ClipboardLinkedTreeObservation(url: url, queue: Self.queue, onChange: notify) else {
                close(descriptor)
                return nil
            }
            tree = observation
        } else { tree = nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: Self.queue)
        source.setEventHandler(handler: notify)
        source.setCancelHandler { close(descriptor) }
        source.activate()
    }

    func cancel() {
        tree?.cancel()
        source.cancel()
    }
    deinit { cancel() }
}

struct ClipboardLinkedLocationSource: Sendable {
    let id: UUID
    let objectID: UUID
    let url: URL
    let identity: Data
    let bookmark: Data
    let revision: UInt64
    let nativeIdentity: ClipboardLinkedNativeIdentity?
    let hasPendingApplication: Bool
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
        linkedFileIdentityEvents.removeAll()
    }

    func refreshLinkedFileObservers(account: ClipboardSyncAccount, control: ClipboardSyncControl, generation: UInt64) throws {
        try admitSync(generation)
        let sources = try linkedRead { try Self.linkedLocationSources(accountID: account.identifier, epoch: control.epoch, in: $0) }
        let liveIDs = Set(sources.map(\.id))
        for id in linkedFileObservers.keys where !liveIDs.contains(id) {
            linkedFileObservers.removeValue(forKey: id)?.cancel()
            linkedFileObservationTasks.removeValue(forKey: id)?.cancel()
            linkedFileObservationRevisions.removeValue(forKey: id)
            linkedFileIdentityEvents.removeValue(forKey: id)
        }
        for source in sources {
            if let existing = linkedFileObservers[source.id], existing.path == source.url.path, existing.identity == source.identity { continue }
            linkedFileObservers.removeValue(forKey: source.id)?.cancel()
            linkedFileObservers[source.id] = ClipboardLinkedFileObservation(url: source.url, identity: source.identity) { [weak self] event in
                Task { await self?.linkedFileDidChange(source.id, event: event, account: account, epoch: control.epoch, generation: generation) }
            }
        }
    }

    private func linkedFileDidChange(_ id: UUID, event: ClipboardLinkedFileIdentityEvent, account: ClipboardSyncAccount, epoch: UUID, generation: UInt64) {
        guard generation == syncGeneration, !syncSuspended else { return }
        linkedFileIdentityEvents[id] = event
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
    func reconcileLinkedFileObservations(account: ClipboardSyncAccount, control: ClipboardSyncControl, generation: UInt64, onlyUnproven: Bool = false) async throws {
        // Start hints before inspecting saved content. A change during the scan
        // then schedules another full reconciliation instead of falling between
        // the content proof and the initial watcher registration.
        try refreshLinkedFileObservers(account: account, control: control, generation: generation)
        let sources = try linkedRead { try Self.linkedLocationSources(accountID: account.identifier, epoch: control.epoch, in: $0) }
        for source in sources where !onlyUnproven || source.nativeIdentity == nil {
            _ = try await observeLinkedLocation(source.id, account: account, epoch: control.epoch, generation: generation)
        }
    }

    private func observeLinkedLocation(_ id: UUID, account: ClipboardSyncAccount, epoch: UUID, generation: UInt64) async throws -> Bool {
        guard let services = syncServices else { return false }
        try await admitSync(generation, account: account, services: services)
        guard let source = try linkedRead({ try Self.linkedLocationSources(accountID: account.identifier, epoch: epoch, id: id, in: $0).first }) else { return false }
        guard !source.hasPendingApplication else { return false }
        let event = linkedFileIdentityEvents[id].flatMap { $0.identity == source.identity ? $0 : nil }
        let inspection = Task.detached(priority: .utility) {
            Result { try ClipboardLinkedIdentityResolution.inspect(source, event: event) }
        }
        let result = await withTaskCancellationHandler {
            await inspection.value
        } onCancel: { inspection.cancel() }
        try Task.checkCancellation()
        try await admitSync(generation, account: account, services: services)
        let changed = try syncWrite { database in
            guard let current = try Self.linkedLocationSources(accountID: account.identifier, epoch: epoch, id: id, in: database).first,
                  current.revision == source.revision,
                  current.identity == source.identity, current.baseVersionID == source.baseVersionID else { return false }
            let state: ClipboardHistoryLinkedFileLocationState
            let digest: Data?
            let proof: ClipboardLinkedFileProof?
            switch result {
            case .success(let inspected):
                proof = inspected
                digest = inspected.digest
                if current.state == .conflict { state = .conflict }
                else if inspected.digest != current.baseDigest { state = .localChanges }
                else { state = current.state == .pendingUpload ? .pendingUpload : .current }
            case .failure(let error):
                proof = nil
                digest = nil
                switch error as? ClipboardLinkedIdentityFailure {
                case .removed: state = .detached
                case .replaced: state = .identityUncertain
                default: state = .unavailable
                }
            }
            let previous = try Data.fetchOne(database, sql: "SELECT observed_digest FROM clipboard_sync_linked_locations WHERE id = ?", arguments: [id.uuidString])
            guard state != current.state || digest != previous || proof.map({ $0.url != current.url || $0.nativeIdentity != current.nativeIdentity || $0.identity != current.identity }) == true else { return false }
            try database.execute(sql: """
                UPDATE clipboard_sync_linked_locations SET state = ?, observed_digest = ?,
                  path = ?, bookmark = ?, identity = ?, native_identity = ? WHERE id = ?
                """, arguments: [state.rawValue, digest, proof?.url.path ?? current.url.path,
                    proof?.bookmark ?? current.bookmark, proof?.identity ?? current.identity,
                    try (proof?.nativeIdentity ?? current.nativeIdentity)?.encoded(), id.uuidString])
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
              AND location.state NOT IN ('detached', 'identityUncertain', 'paused')
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
                    identity: row["identity"], bookmark: row["bookmark"], revision: row["revision"],
                    nativeIdentity: try (row["native_identity"] as Data?).map { try JSONDecoder().decode(ClipboardLinkedNativeIdentity.self, from: $0) },
                    hasPendingApplication: (row["applying_version_id"] as String?) != nil,
                    baseVersionID: base, baseDigest: row["base_digest"], state: state)
            }
    }
}
