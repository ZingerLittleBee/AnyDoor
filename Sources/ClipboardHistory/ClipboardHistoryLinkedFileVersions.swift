import Foundation
import GRDB

extension ClipboardHistoryModule {
    func acknowledgeLinkedFileVersions(account: ClipboardSyncAccount, control: ClipboardSyncControl) throws {
        let sources = try linkedRead { try Self.linkedLocationSources(accountID: account.identifier, epoch: control.epoch, in: $0) }
        for source in sources where source.state == .pendingUpload {
            guard try syncFileVersionIsCommitted(objectID: source.objectID, versionID: source.baseVersionID) else { continue }
            try syncWrite { database in
                try database.execute(sql: """
                    UPDATE clipboard_sync_linked_locations SET state = 'current', pending_version_id = NULL
                    WHERE id = ? AND base_version_id = ? AND state = 'pendingUpload'
                    """, arguments: [source.id.uuidString, source.baseVersionID.uuidString])
                try Self.bumpHistoryRevision(in: database)
            }
            publishMutation()
        }
    }

    /// One transfer/version path serves original files, receiving working copies,
    /// and explicit associations. Every location keeps its actual edited base.
    func reconcileLinkedFileVersions(account: ClipboardSyncAccount, control: ClipboardSyncControl, generation: UInt64, canPublish: Bool = true) async throws {
        guard let services = syncServices else { return }
        try admitSync(generation)
        linkedFileMutationGate.activate(generation)
        try await recoverLinkedFileApplications(account: account, control: control, generation: generation)
        let sources = try linkedRead { try Self.linkedLocationSources(accountID: account.identifier, epoch: control.epoch, in: $0) }
        for source in sources {
            try await admitSync(generation, account: account, services: services)
            guard !activeApplicationUpdates.contains(source.id) else { continue }
            if try linkedRead({ try Bool.fetchOne($0, sql: """
                SELECT EXISTS(SELECT 1 FROM clipboard_sync_file_resolutions
                  WHERE account_id = ? AND epoch = ? AND object_id = ? AND phase = 'preparing')
                """, arguments: [account.identifier, control.epoch.uuidString, source.objectID.uuidString]) }) == true { continue }
            guard let selection = try syncFileSelection(objectID: source.objectID) else { continue }
            if !selection.hasConflict, selection.latest.versionID == source.baseVersionID,
               source.state == .current || !canPublish { continue }
            let inspection = Task.detached(priority: .utility) {
                let proof = try ClipboardLinkedFileIO.inspect(source.url, expectedIdentity: source.identity)
                return (proof, source.isApplication || ClipboardApplicationPackage.requiresExplicitUpdate(source.url))
            }
            let proof: ClipboardLinkedFileProof
            let isApplication: Bool
            do { (proof, isApplication) = try await withTaskCancellationHandler { try await inspection.value } onCancel: { inspection.cancel() } }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
            try await admitSync(generation, account: account, services: services)
            guard !activeApplicationUpdates.contains(source.id),
                  try linkedSourceIsCurrent(source, account: account, control: control) else { continue }
            if isApplication, !source.isApplication {
                try syncWrite { try $0.execute(sql: "UPDATE clipboard_sync_linked_locations SET is_application = 1 WHERE id = ?",
                    arguments: [source.id.uuidString]) }
            }
            if source.state == .conflict {
                guard proof.digest == source.baseDigest, !selection.hasConflict,
                      try linkedVersion(selection.latest.versionID, descendsFrom: source.baseVersionID,
                        objectID: source.objectID, account: account, control: control),
                      let pending = try linkedRead({ try String.fetchOne($0,
                        sql: "SELECT pending_version_id FROM clipboard_sync_linked_locations WHERE id = ?", arguments: [source.id.uuidString]) }),
                      let pendingID = UUID(uuidString: pending),
                      try linkedVersion(selection.latest.versionID, descendsFrom: pendingID,
                        objectID: source.objectID, account: account, control: control) else { continue }
            }
            if selection.hasConflict || (proof.digest != source.baseDigest && selection.latest.versionID != source.baseVersionID) {
                try setLinkedConflict(source, remoteVersion: selection.latest.versionID)
                continue
            }
            if proof.digest != source.baseDigest {
                guard canPublish else { continue }
                let versionID = try await publishFileVersion(sourceURL: source.url, objectID: source.objectID,
                    parents: [source.baseVersionID], expectedSourceIdentity: source.identity)
                try await admitSync(generation, account: account, services: services)
                guard let frozen = try syncFileSelection(objectID: source.objectID)?.complete,
                      frozen.descriptor.versionID == versionID, let digest = frozen.descriptor.contentDigest else {
                    throw ClipboardSyncServiceError.corruptData
                }
                let postFreeze = Task.detached(priority: .utility) {
                    try? ClipboardLinkedFileIO.inspect(source.url, expectedIdentity: source.identity)
                }
                let saved = await postFreeze.value
                try await admitSync(generation, account: account, services: services)
                let state: ClipboardHistoryLinkedFileLocationState = saved.map { $0.digest == digest ? .pendingUpload : .localChanges } ?? .unavailable
                try syncWrite { database in
                    guard let current = try Self.linkedLocationSources(accountID: account.identifier, epoch: control.epoch, id: source.id, in: database).first,
                          current.revision == source.revision, current.identity == source.identity, current.baseVersionID == source.baseVersionID else { return }
                    try database.execute(sql: """
                        UPDATE clipboard_sync_linked_locations SET base_version_id = ?, base_digest = ?,
                          state = ?, pending_version_id = ?, observed_digest = ? WHERE id = ?
                        """, arguments: [versionID.uuidString, digest, state.rawValue, versionID.uuidString, saved?.digest, source.id.uuidString])
                    try Self.bumpHistoryRevision(in: database)
                }
                publishMutation()
                continue
            }
            guard let complete = selection.complete, complete.descriptor.versionID == selection.latest.versionID,
                  complete.descriptor.versionID != source.baseVersionID else { continue }
            guard try linkedVersion(complete.descriptor.versionID, descendsFrom: source.baseVersionID,
                objectID: source.objectID, account: account, control: control) else {
                try setLinkedConflict(source, remoteVersion: complete.descriptor.versionID)
                continue
            }
            // Receiving a complete package does not authorize replacing an
            // application at a linked location. Only Apply Update can do that.
            guard !isApplication else { continue }
            let work = ClipboardSyncFileWork.linkedLocation(source.id)
            guard try !shouldDeferSyncFileWork(work, account: account, control: control) else { continue }
            do {
                try await applyLinkedFileVersion(complete, to: source, account: account, control: control, generation: generation)
                try syncWrite { try completeSyncFileWork(work, account: account, control: control, in: $0) }
            } catch {
                guard Self.isIsolatedSyncFileFailure(error) else { throw error }
                try deferSyncFileWork(work, error: error, account: account, control: control, generation: generation)
                publishMutation()
            }
        }
    }

    private func linkedSourceIsCurrent(_ source: ClipboardLinkedLocationSource, account: ClipboardSyncAccount, control: ClipboardSyncControl) throws -> Bool {
        try linkedRead { database in
            guard let current = try Self.linkedLocationSources(accountID: account.identifier, epoch: control.epoch, id: source.id, in: database).first else { return false }
            return current.revision == source.revision && current.identity == source.identity && current.baseVersionID == source.baseVersionID
        }
    }

    private func setLinkedConflict(_ source: ClipboardLinkedLocationSource, remoteVersion: UUID) throws {
        try syncWrite { database in
            try database.execute(sql: "UPDATE clipboard_sync_linked_locations SET state = 'conflict', pending_version_id = ? WHERE id = ?",
                arguments: [remoteVersion.uuidString, source.id.uuidString])
            try Self.bumpHistoryRevision(in: database)
        }
        publishMutation()
    }

    func linkedVersion(_ version: UUID, descendsFrom ancestor: UUID, objectID: UUID,
        account: ClipboardSyncAccount, control: ClipboardSyncControl) throws -> Bool {
        try linkedRead { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT version_id, parents FROM clipboard_sync_file_versions
                WHERE account_id = ? AND epoch = ? AND object_id = ?
                """, arguments: [account.identifier, control.epoch.uuidString, objectID.uuidString])
            var graph: [UUID: [UUID]] = [:]
            for row in rows {
                guard let id = UUID(uuidString: row["version_id"]) else { continue }
                graph[id] = try JSONDecoder().decode([UUID].self, from: row["parents"])
            }
            let nodes = graph.map { ClipboardSyncVersionNode(id: $0.key, parents: Set($0.value)) }
            guard ClipboardSyncVersionGraph.isComplete(nodes) else { return false }
            var pending = [version]
            var visited = Set<UUID>()
            while let next = pending.popLast() {
                if next == ancestor { return true }
                if visited.insert(next).inserted { pending.append(contentsOf: graph[next] ?? []) }
            }
            return false
        }
    }

    func applyLinkedFileVersion(_ version: ClipboardSyncVerifiedFileVersion, to source: ClipboardLinkedLocationSource,
        account: ClipboardSyncAccount, control: ClipboardSyncControl, generation: UInt64,
        applicationPlan: ClipboardApplicationUpdateSnapshot? = nil,
        applicationGuard: ClipboardApplicationRunningGuard? = nil) async throws {
        guard let services = syncServices else { return }
        guard applicationPlan != nil || !(source.isApplication || ClipboardApplicationPackage.requiresExplicitUpdate(source.url)) else {
            throw ClipboardHistoryApplicationUpdateError.stalePlan
        }
        let preparation = Task.detached(priority: .utility) { try ClipboardLinkedFileIO.prepareReplacement(version, at: source.url) }
        let replacement = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        var journaled = false
        defer { if !journaled { try? FileManager.default.removeItem(at: replacement.url) } }
        try await admitSync(generation, account: account, services: services)
        guard try linkedSourceIsCurrent(source, account: account, control: control) else { return }
        try syncWrite { database in
            try database.execute(sql: """
                UPDATE clipboard_sync_linked_locations SET applying_version_id = ?, applying_digest = ?,
                  replacement_path = ?, replacement_identity = ? WHERE id = ?
                """, arguments: [version.descriptor.versionID.uuidString, replacement.digest,
                    replacement.url.path, replacement.identity, source.id.uuidString])
        }
        journaled = true
        let faults = faultInjector
        let gate = linkedFileMutationGate
        let database = try requiredDatabase()
        let application = Task.detached(priority: .utility) {
            try ClipboardLinkedFileIO.applyReplacement(replacement, to: source, faultInjector: faults) { mutation in
                let authorizedMutation: @Sendable () throws -> Bool = {
                    try gate.perform(generation: generation) {
                        // Serialize the last authority read with deletion, withdrawal,
                        // and reset writes. No hashing or network I/O holds this turn.
                        try database.write { database in
                            if let applicationPlan { _ = try Self.validateApplicationUpdate(applicationPlan, phase: "applying", in: database) }
                            guard try Bool.fetchOne(database, sql: "SELECT enabled = 1 AND account_id = ? FROM clipboard_sync_settings WHERE id = 1",
                                arguments: [account.identifier]) == true,
                                  let current = try Self.linkedLocationSources(accountID: account.identifier, epoch: control.epoch, id: source.id, in: database).first,
                                  current.revision == source.revision, current.baseVersionID == source.baseVersionID, current.identity == source.identity else {
                                throw CancellationError()
                            }
                            return try mutation()
                        }
                    }
                }
                if let applicationGuard { return try applicationGuard.perform(authorizedMutation) }
                return try authorizedMutation()
            }
        }
        let proof = try await withTaskCancellationHandler { try await application.value } onCancel: { application.cancel() }
        try faultInjector.check(.linkedFileAfterReplacement)
        try await admitSync(generation, account: account, services: services)
        guard try linkedSourceIsCurrent(source, account: account, control: control) else { return }
        if let proof {
            // A retained editor FD can save to the displaced inode after the
            // exchange proof. Keep that visible output when adopting the new one.
            try finishLinkedApplication(source, versionID: version.descriptor.versionID, digest: replacement.digest, proof: proof)
        } else {
            try setLinkedConflict(source, remoteVersion: version.descriptor.versionID)
            try clearLinkedApplication(source.id)
            try? FileManager.default.removeItem(at: replacement.url)
        }
    }

    private func finishLinkedApplication(_ source: ClipboardLinkedLocationSource, versionID: UUID, digest: Data, proof: ClipboardLinkedFileProof) throws {
        try syncWrite { database in
            try database.execute(sql: """
                UPDATE clipboard_sync_linked_locations SET base_version_id = ?, base_digest = ?,
                  bookmark = ?, identity = ?, native_identity = ?, observed_digest = ?, state = ?, pending_version_id = NULL,
                  applying_version_id = NULL, applying_digest = NULL, replacement_path = NULL, replacement_identity = NULL
                WHERE id = ?
                """, arguments: [versionID.uuidString, digest, proof.bookmark, proof.identity, try proof.nativeIdentity?.encoded(), proof.digest,
                    proof.digest == digest ? "current" : "localChanges", source.id.uuidString])
            try Self.bumpHistoryRevision(in: database)
        }
        publishMutation()
    }

    private func clearLinkedApplication(_ id: UUID) throws {
        try syncWrite { database in
            try database.execute(sql: """
                UPDATE clipboard_sync_linked_locations SET applying_version_id = NULL, applying_digest = NULL,
                  replacement_path = NULL, replacement_identity = NULL WHERE id = ?
                """, arguments: [id.uuidString])
        }
    }

    /// A replaced inode is adopted only through the journal's recorded identity.
    /// Edits made after the exchange stay dirty against the installed version.
    func recoverLinkedFileApplications(account: ClipboardSyncAccount, control: ClipboardSyncControl, generation: UInt64) async throws {
        guard let services = syncServices else { return }
        let sources = try linkedRead { try Self.linkedLocationSources(accountID: account.identifier, epoch: control.epoch, in: $0) }
        for source in sources {
            guard !activeApplicationUpdates.contains(source.id) else { continue }
            guard let row = try linkedRead({ try Row.fetchOne($0, sql: "SELECT * FROM clipboard_sync_linked_locations WHERE id = ? AND applying_version_id IS NOT NULL", arguments: [source.id.uuidString]) }),
                  let version = UUID(uuidString: row["applying_version_id"]), let digest: Data = row["applying_digest"],
                  let identity: Data = row["replacement_identity"], let path: String = row["replacement_path"] else { continue }
            try await admitSync(generation, account: account, services: services)
            let inspection = Task.detached(priority: .utility) { try? ClipboardLinkedFileIO.inspect(source.url, expectedIdentity: identity) }
            let proof = await inspection.value
            try await admitSync(generation, account: account, services: services)
            guard try linkedApplicationJournalIsCurrent(source, version: version, digest: digest,
                replacementIdentity: identity, replacementPath: path, account: account, control: control) else { continue }
            if let proof {
                // Preserve the displaced output across admission, including
                // saves made through an editor FD after the initial exchange.
                let faults = faultInjector
                let checkpoint = Task.detached(priority: .utility) {
                    try faults.check(.linkedFileBeforeRecoveryCommit)
                }
                try await checkpoint.value
                try await admitSync(generation, account: account, services: services)
                guard try linkedApplicationJournalIsCurrent(source, version: version, digest: digest,
                    replacementIdentity: identity, replacementPath: path, account: account, control: control) else { continue }
                try finishLinkedApplication(source, versionID: version, digest: digest, proof: proof)
            } else {
                // No exchange occurred. Remove only our verified replacement.
                if ClipboardSyncFileIO.isAvailable(path: path, identity: identity) { try? FileManager.default.removeItem(atPath: path) }
                try clearLinkedApplication(source.id)
            }
        }
    }

    /// An I/O continuation owns only the exact location revision and replacement
    /// journal it inspected. A pause, newer journal, or explicit update wins.
    private func linkedApplicationJournalIsCurrent(_ source: ClipboardLinkedLocationSource,
        version: UUID, digest: Data, replacementIdentity: Data, replacementPath: String,
        account: ClipboardSyncAccount, control: ClipboardSyncControl) throws -> Bool {
        guard !activeApplicationUpdates.contains(source.id) else { return false }
        return try linkedRead { database in
            guard let current = try Self.linkedLocationSources(accountID: account.identifier,
                epoch: control.epoch, id: source.id, in: database).first,
                  current.revision == source.revision, current.identity == source.identity,
                  current.baseVersionID == source.baseVersionID, current.baseDigest == source.baseDigest,
                  current.url == source.url else { return false }
            return try Bool.fetchOne(database, sql: """
                SELECT EXISTS(SELECT 1 FROM clipboard_sync_linked_locations
                  WHERE id = ? AND applying_version_id = ? AND applying_digest = ?
                    AND replacement_identity = ? AND replacement_path = ?)
                """, arguments: [source.id.uuidString, version.uuidString, digest, replacementIdentity, replacementPath]) == true
        }
    }
}
