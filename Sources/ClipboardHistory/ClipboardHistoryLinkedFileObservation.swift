import Darwin
import Dispatch
import Foundation
import GRDB
import os

/// Dispatch owns the descriptor until its cancellation handler runs. Both event
/// sources use the same serial queue, and the subtree stream stops before the
/// descriptor can close. Immutable ownership and synchronized native cancellation
/// justify this SDK boundary's Sendable conformance.
final class ClipboardLinkedFileObservation: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "dev.bybee.AnyDoor.clipboard.linked-files")
    // Count live native descriptors, including asynchronous cancellation, across
    // all module instances. Recursive members do not consume separate slots.
    private static let descriptorCount = OSAllocatedUnfairLock(initialState: 0)
    private static let maximumDescriptors = 64
    let path: String
    let identity: Data
    private let source: any DispatchSourceFileSystemObject
    private let tree: ClipboardLinkedTreeObservation?

    init?(url: URL, identity: Data, onChange: @escaping @Sendable (ClipboardLinkedFileIdentityEvent) -> Void) {
        guard Self.descriptorCount.withLock({ count in
            guard count < Self.maximumDescriptors else { return false }
            count += 1
            return true
        }) else { return nil }
        var reserved = true
        defer { if reserved { Self.descriptorCount.withLock { $0 -= 1 } } }
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
        source.setCancelHandler {
            close(descriptor)
            Self.descriptorCount.withLock { $0 -= 1 }
        }
        reserved = false
        source.activate()
    }

    func cancel() {
        tree?.cancel()
        source.cancel()
    }
    deinit { cancel() }
}

struct ClipboardLinkedLocationSource: Codable, Sendable {
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
    var isApplication: Bool = false
}

extension ClipboardHistoryModule {
    func stopLinkedFileObservers() {
        linkedFileReconciliationTask?.cancel()
        linkedFileReconciliationTask = nil
        linkedFileMutationGate.revoke()
        for observer in linkedFileObservers.values { observer.cancel() }
        linkedFileObservers.removeAll()
        for task in linkedFileObservationTasks.values { task.cancel() }
        linkedFileObservationTasks.removeAll()
        linkedFileObservationRevisions.removeAll()
        linkedFileIdentityEvents.removeAll()
        linkedFileObservationCache.removeAll()
        applicationRunningGuards.removeAll()
    }

    func refreshLinkedFileObservers(account: ClipboardSyncAccount, control: ClipboardSyncControl, generation: UInt64) throws {
        try admitSync(generation)
        let sources = try linkedRead { try Self.linkedLocationSources(accountID: account.identifier, epoch: control.epoch, in: $0) }
        let liveIDs = Set(sources.map(\.id))
        linkedFileObservationCache = linkedFileObservationCache.filter { liveIDs.contains($0.key) }
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
        if linkedFileObservers.count == sources.count {
            linkedFileReconciliationTask?.cancel()
            linkedFileReconciliationTask = nil
        } else if linkedFileReconciliationTask == nil {
            // Rotate a bounded set of local inspections even when provider
            // polling is disabled. Unchanged or unavailable locations do not
            // authorize a provider request or a full reconciliation pass.
            linkedFileReconciliationTask = Task { [weak self] in
                var after: String?
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let next = await self?.reconcileUnobservedLinkedFiles(account: account,
                        epoch: control.epoch, generation: generation, after: after), next.continues else { return }
                    after = next.after
                }
            }
        }
    }

    private func reconcileUnobservedLinkedFiles(account: ClipboardSyncAccount, epoch: UUID,
        generation: UInt64, after: String?) async -> (continues: Bool, after: String?) {
        guard !Task.isCancelled, generation == syncGeneration, !syncSuspended else { return (false, after) }
        do {
            let sources = try linkedRead { try Self.linkedLocationSources(accountID: account.identifier, epoch: epoch, in: $0) }
                .filter { linkedFileObservers[$0.id] == nil && linkedFileObservationTasks[$0.id] == nil }
            let cursor = after ?? ""
            let following = sources.filter { $0.id.uuidString > cursor }
            let preceding = sources.filter { $0.id.uuidString <= cursor }
            let batch = (following + preceding).prefix(16)
            var changed = false
            for source in batch {
                changed = try await observeLinkedLocation(source.id, account: account, epoch: epoch,
                    generation: generation, automatic: true, providerIndependent: true) || changed
            }
            if changed { await retrySyncAutomatically() }
            return (!Task.isCancelled && generation == syncGeneration && !syncSuspended, batch.last?.id.uuidString ?? after)
        } catch is CancellationError {
            return (false, after)
        } catch {
            return (generation == syncGeneration && !syncSuspended, after)
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
                let changed = try await self.observeLinkedLocation(id, account: account, epoch: epoch, generation: generation, automatic: true)
                if changed { await self.retrySyncAutomatically() }
                await self.finishLinkedFileObservation(id, revision: revision)
            } catch ClipboardSyncServiceError.accountChanged {
                await self?.retrySyncAutomatically()
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

    private func observeLinkedLocation(_ id: UUID, account: ClipboardSyncAccount, epoch: UUID,
        generation: UInt64, automatic: Bool = false, providerIndependent: Bool = false) async throws -> Bool {
        guard let services = syncServices else { return false }
        try await admitLinkedFileObservation(generation, account: account, epoch: epoch, services: services,
            automatic: automatic, providerIndependent: providerIndependent)
        guard let source = try linkedRead({ try Self.linkedLocationSources(accountID: account.identifier, epoch: epoch, id: id, in: $0).first }) else { return false }
        guard !source.hasPendingApplication else { return false }
        let event = linkedFileIdentityEvents[id].flatMap { $0.identity == source.identity ? $0 : nil }
        let cached = providerIndependent && event == nil ? linkedFileObservationCache[id] : nil
        let faults = faultInjector
        let inspection = Task.detached(priority: .utility) {
            if Task.isCancelled { return .failure(CancellationError()) as Result<(ClipboardLinkedFileProof, ClipboardLinkedObservationCache?), any Error>? }
            if let cached, (try? cached.isUnchanged(source)) == true {
                return nil as Result<(ClipboardLinkedFileProof, ClipboardLinkedObservationCache?), any Error>?
            }
            return Result {
                try Task.checkCancellation()
                let proof = try ClipboardLinkedIdentityResolution.inspect(source, event: event, faults: faults)
                return (proof, try? ClipboardLinkedObservationCache(source: source, proof: proof))
            }
        }
        let inspected = await withTaskCancellationHandler {
            await inspection.value
        } onCancel: { inspection.cancel() }
        try Task.checkCancellation()
        try await admitLinkedFileObservation(generation, account: account, epoch: epoch, services: services,
            automatic: automatic, providerIndependent: providerIndependent)
        guard let inspected else { return false }
        let result = inspected.map { $0.0 }
        if case .success(let value) = inspected { linkedFileObservationCache[id] = value.1 }
        else { linkedFileObservationCache.removeValue(forKey: id) }
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

    private func admitLinkedFileObservation(_ generation: UInt64, account: ClipboardSyncAccount, epoch: UUID,
        services: ClipboardSyncServices, automatic: Bool, providerIndependent: Bool) async throws {
        guard providerIndependent else {
            try await admitSyncFileObservation(generation, account: account, epoch: epoch, services: services, automatic: automatic)
            return
        }
        // A local observation only records saved-byte/availability facts. Any
        // resulting publication still revalidates the provider's account in
        // the ordinary sync pass, including its explicit-retry and delay gates.
        try await waitForWriteTurn()
        try admitSync(generation)
        guard let context = try syncFileRead({ try syncFileContext(in: $0) }),
              context.account == account, context.control.epoch == epoch, context.control.phase == "active" else {
            throw ClipboardSyncServiceError.accountChanged
        }
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
            """)).map(linkedLocationSource)
    }

    static func linkedLocationSource(_ row: Row) throws -> ClipboardLinkedLocationSource {
                guard let id = UUID(uuidString: row["id"]), let objectID = UUID(uuidString: row["object_id"]),
                      let base = UUID(uuidString: row["base_version_id"]),
                      let state = ClipboardHistoryLinkedFileLocationState(rawValue: row["state"]) else {
                    throw ClipboardHistoryModuleError.storageFailure
                }
                return ClipboardLinkedLocationSource(id: id, objectID: objectID, url: URL(fileURLWithPath: row["path"]),
                    identity: row["identity"], bookmark: row["bookmark"], revision: row["revision"],
                    nativeIdentity: try (row["native_identity"] as Data?).map { try JSONDecoder().decode(ClipboardLinkedNativeIdentity.self, from: $0) },
                    hasPendingApplication: (row["applying_version_id"] as String?) != nil,
                    baseVersionID: base, baseDigest: row["base_digest"], state: state,
                    isApplication: row["is_application"] ?? false)
    }
}
