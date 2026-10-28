import CryptoKit
import Foundation
import GRDB

struct ClipboardSyncFileResolutionBranch: Codable, Sendable {
    let locationID: UUID
    let versionID: UUID
    let publicationID: UUID
}

struct ClipboardSyncFileResolutionJournal: Codable, Sendable {
    let choice: ClipboardHistoryFileConflictChoice
    let resultID: UUID
    let publicationID: UUID
    let branches: [ClipboardSyncFileResolutionBranch]
    var prepared: [ClipboardSyncPreparedFileVersion]
}

extension ClipboardHistoryModule {
    /// A choice consumes the persisted snapshot, never caller-supplied paths or
    /// descriptors. Dirty branches and the merge enter the outbox atomically.
    public func resolveFileConflict(_ plan: ClipboardHistoryFileConflictPlan,
        choosing choice: ClipboardHistoryFileConflictChoice) async throws -> UUID {
        await retrySync()
        let result = try await executeFileConflictResolution(planID: plan.id, choice: choice)
        await retrySync()
        return result
    }

    func executeFileConflictResolution(planID: UUID, choice: ClipboardHistoryFileConflictChoice) async throws -> UUID {
        guard activeFileConflictResolutions.insert(planID).inserted else { throw ClipboardHistoryModuleError.operationUnavailable }
        defer { activeFileConflictResolutions.remove(planID) }
        let generation = syncGeneration
        let store = storeEpoch
        try admitSync(generation)
        guard let services = syncServices else { throw ClipboardHistoryModuleError.operationUnavailable }
        let snapshot = try linkedRead { database in
            guard let data = try Data.fetchOne(database, sql: "SELECT snapshot FROM clipboard_sync_file_conflict_plans WHERE id = ?",
                arguments: [planID.uuidString]) else { throw ClipboardHistoryFileConflictError.stalePlan }
            return try JSONDecoder().decode(ClipboardSyncFileConflictSnapshot.self, from: data)
        }
        let entryID = ClipboardHistoryEntryID(snapshot.entryID)
        let basis = try linkedRead { try fileConflictBasis(entryID: entryID, objectID: snapshot.objectID, in: $0) }
        let account = basis.account
        let control = basis.control
        try await admitSyncFilePublication(generation, account: account, control: control, services: services)
        var journal: ClipboardSyncFileResolutionJournal
        if let existing = try linkedRead({ try Row.fetchOne($0, sql: "SELECT phase, journal FROM clipboard_sync_file_resolutions WHERE plan_id = ?",
            arguments: [planID.uuidString]) }) {
            journal = try JSONDecoder().decode(ClipboardSyncFileResolutionJournal.self, from: existing["journal"])
            guard journal.choice == choice else { throw ClipboardHistoryFileConflictError.stalePlan }
            let phase: String = existing["phase"]
            if phase == "staged" || phase == "complete" { return journal.resultID }
            guard phase == "preparing" else { throw ClipboardHistoryFileConflictError.stalePlan }
        } else {
            try Self.validateConflictBasis(basis, snapshot: snapshot)
            journal = .init(choice: choice, resultID: UUID(), publicationID: UUID(),
                branches: snapshot.locations.filter { $0.savedDigest != nil && $0.savedDigest != $0.baseDigest }
                    .map { .init(locationID: $0.id, versionID: UUID(), publicationID: UUID()) }, prepared: [])
            try syncWrite { database in
                try Self.validateConflictBasis(try fileConflictBasis(entryID: entryID, objectID: snapshot.objectID, in: database), snapshot: snapshot)
                try database.execute(sql: """
                    INSERT INTO clipboard_sync_file_resolutions(plan_id, account_id, epoch, object_id, phase, journal)
                    VALUES (?, ?, ?, ?, 'preparing', ?)
                    """, arguments: [planID.uuidString, account.identifier, control.epoch.uuidString,
                        snapshot.objectID.uuidString, try JSONEncoder().encode(journal)])
                for version in Set(snapshot.heads + snapshot.locations.map(\.baseVersionID) + journal.branches.map(\.versionID) + [journal.resultID]) {
                    try Self.pinFileConflictVersion(version, planID: planID, snapshot: snapshot, in: database)
                }
            }
        }
        do {
            try Self.validateConflictBasis(basis, snapshot: snapshot)
            guard let key = try await services.keys.load(account: account, keyID: control.keyID), key.count == 32,
                  ClipboardSyncCodec.check(key: key, account: account, keyID: control.keyID) == control.keyCheck else {
                throw ClipboardSyncServiceError.keyUnavailable
            }
            try await admitSyncFilePublication(generation, account: account, control: control, services: services)
            let initialProofs = try await inspectConflictLocations(snapshot)
            let selected: ClipboardLinkedFileProof
            switch choice {
            case .localLocation(let id):
                guard journal.branches.contains(where: { $0.locationID == id }), let proof = initialProofs[id] else {
                    throw ClipboardHistoryFileConflictError.candidateUnavailable
                }
                selected = proof
            case .version(let id):
                guard snapshot.heads.contains(id), let version = basis.versions.first(where: { $0.descriptor.versionID == id }),
                      version.descriptor.state == .available else { throw ClipboardHistoryFileConflictError.candidateUnavailable }
                guard let path = version.path, let identity = version.identity else { throw ClipboardHistoryFileConflictError.downloadRequired(id) }
                let inspection = Task.detached { try? ClipboardLinkedFileIO.inspect(URL(fileURLWithPath: path), expectedIdentity: identity) }
                guard let proof = await inspection.value, proof.digest == version.descriptor.contentDigest,
                      proof.byteCount == version.descriptor.originalByteCount else { throw ClipboardHistoryFileConflictError.downloadRequired(id) }
                selected = proof
            }
            for branch in journal.branches where !journal.prepared.contains(where: { $0.descriptor.versionID == branch.versionID }) {
                guard let location = snapshot.locations.first(where: { $0.id == branch.locationID }),
                      let proof = initialProofs[branch.locationID] else { throw ClipboardHistoryFileConflictError.stalePlan }
                try await admitSyncFilePublication(generation, account: account, control: control, services: services)
                try linkedRead { try Self.validateConflictBasis(fileConflictBasis(entryID: entryID, objectID: snapshot.objectID, in: $0), snapshot: snapshot) }
                let prepared = try await prepareFileVersion(sourceURL: proof.url, objectID: snapshot.objectID,
                    versionID: branch.versionID, publicationID: branch.publicationID, parents: [location.baseVersionID],
                    expectedSourceIdentity: proof.identity, displayName: basis.versions[0].descriptor.displayName,
                    account: account, control: control, key: key)
                try await admitSyncFilePublication(generation, account: account, control: control, services: services)
                guard storeEpoch == store else { throw CancellationError() }
                guard prepared.descriptor.contentDigest == location.savedDigest,
                      prepared.descriptor.originalByteCount == location.byteCount else { throw ClipboardHistoryFileConflictError.stalePlan }
                journal.prepared.append(prepared)
                try saveFileResolutionJournal(journal, planID: planID)
                try faultInjector.check(.fileConflictAfterBranchFreeze)
            }
            if !journal.prepared.contains(where: { $0.descriptor.versionID == journal.resultID }) {
                try await admitSyncFilePublication(generation, account: account, control: control, services: services)
                try linkedRead { try Self.validateConflictBasis(fileConflictBasis(entryID: entryID, objectID: snapshot.objectID, in: $0), snapshot: snapshot) }
                let nodes = basis.nodes + journal.prepared.map { ClipboardSyncVersionNode(id: $0.descriptor.versionID, parents: Set($0.parents)) }
                let parents = ClipboardSyncVersionGraph.heads(nodes).sorted { $0.uuidString < $1.uuidString }
                let prepared = try await prepareFileVersion(sourceURL: selected.url, objectID: snapshot.objectID,
                    versionID: journal.resultID, publicationID: journal.publicationID, parents: parents,
                    expectedSourceIdentity: selected.identity, displayName: basis.versions[0].descriptor.displayName,
                    account: account, control: control, key: key)
                try await admitSyncFilePublication(generation, account: account, control: control, services: services)
                guard storeEpoch == store else { throw CancellationError() }
                guard prepared.descriptor.contentDigest == selected.digest, prepared.descriptor.originalByteCount == selected.byteCount else {
                    throw ClipboardHistoryFileConflictError.stalePlan
                }
                journal.prepared.append(prepared)
                try saveFileResolutionJournal(journal, planID: planID)
            }
            for prepared in journal.prepared {
                try await Self.verifyPreparedFileVersion(prepared, account: account, control: control, key: key)
            }
            try await admitSyncFilePublication(generation, account: account, control: control, services: services)
            guard let result = journal.prepared.first(where: { $0.descriptor.versionID == journal.resultID }) else { throw ClipboardSyncServiceError.corruptData }
            let output = try await ClipboardSyncFilePublication.construct(descriptor: result.descriptor,
                encryptedDirectory: result.uploadDirectory, root: syncWorkingRoot,
                account: account, control: control, key: key)
            defer { ClipboardSyncFilePublication.discard(output) }
            // Refresh metadata after the potentially long freezes. No bodies are
            // fetched here, including an unchosen large remote candidate.
            let state = try linkedRead { database in
                guard let data = try Data.fetchOne(database, sql: "SELECT state FROM clipboard_sync_accounts WHERE id = ?", arguments: [account.identifier]) else {
                    throw ClipboardHistoryModuleError.operationUnavailable
                }
                return try JSONDecoder().decode(ClipboardSyncAccountState.self, from: data)
            }
            _ = try await receiveSyncChanges(account: account, control: control, key: key, state: state, services: services, generation: generation)
            let proofs = try await inspectConflictLocations(snapshot)
            try await admitSyncFilePublication(generation, account: account, control: control, services: services)
            guard storeEpoch == store else { throw CancellationError() }
            try faultInjector.check(.fileConflictBeforeStaging)
            try syncWrite { database in
                try Self.validateConflictBasis(fileConflictBasis(entryID: entryID, objectID: snapshot.objectID, in: database), snapshot: snapshot)
                guard proofs.values.allSatisfy({ $0.stamp.matches($0.url) }) else { throw ClipboardHistoryFileConflictError.stalePlan }
                let published = try ClipboardSyncFilePublication.publish(output, descriptor: result.descriptor,
                    root: syncWorkingRoot, accountID: account.identifier, faults: faultInjector)
                for prepared in journal.prepared where prepared.descriptor.versionID != journal.resultID {
                    try storePreparedFileVersion(prepared, account: account, control: control, in: database)
                }
                let immutableResult = ClipboardSyncPreparedFileVersion(descriptor: result.descriptor, parents: result.parents,
                    uploadDirectory: result.uploadDirectory, sourceURL: published.url, bookmark: published.bookmark,
                    identity: published.identity, publication: result.publication)
                try storePreparedFileVersion(immutableResult, account: account, control: control, in: database)
                for location in snapshot.locations {
                    guard let digest = location.savedDigest else { continue }
                    let same = digest == result.descriptor.contentDigest
                    let branch = journal.branches.first { $0.locationID == location.id }
                    let base = same ? journal.resultID : branch?.versionID ?? location.baseVersionID
                    try database.execute(sql: """
                        UPDATE clipboard_sync_linked_locations SET base_version_id = ?, base_digest = ?,
                          observed_digest = ?, state = ?, pending_version_id = ? WHERE id = ?
                        """, arguments: [base.uuidString, digest, digest, same ? "pendingUpload" : "current",
                            same ? journal.resultID.uuidString : nil, location.id.uuidString])
                }
                try database.execute(sql: "UPDATE clipboard_sync_file_resolutions SET phase = 'staged' WHERE plan_id = ?", arguments: [planID.uuidString])
                try Self.bumpHistoryRevision(in: database)
            }
            try faultInjector.check(.fileConflictAfterStaging)
            publishMutation()
            return journal.resultID
        } catch {
            if error is ClipboardHistoryFileConflictError {
                try? syncWrite { database in
                    try database.execute(sql: "UPDATE clipboard_sync_file_resolutions SET phase = 'needsReview' WHERE plan_id = ? AND phase = 'preparing'", arguments: [planID.uuidString])
                }
            }
            throw error
        }
    }

    static func validateConflictBasis(_ basis: ClipboardSyncFileConflictBasis, snapshot: ClipboardSyncFileConflictSnapshot) throws {
        guard basis.account.identifier == snapshot.accountID, basis.control.epoch == snapshot.epoch,
              basis.control.keyID == snapshot.keyID, basis.control.phase == "active", basis.heads == snapshot.heads,
              conflictLocationFactsMatch(snapshot.locations, sources: basis.locations) else { throw ClipboardHistoryFileConflictError.stalePlan }
        guard !basis.nodes.isEmpty, basis.nodes.allSatisfy({ ClipboardSyncVersionGraph.isComplete($0.id, nodes: basis.nodes) }) else {
            throw ClipboardHistoryFileConflictError.incompleteAncestry
        }
    }

    func inspectConflictLocations(_ snapshot: ClipboardSyncFileConflictSnapshot) async throws -> [UUID: ClipboardLinkedFileProof] {
        let inspection = Task.detached(priority: .userInitiated) {
            var proofs: [UUID: ClipboardLinkedFileProof] = [:]
            for location in snapshot.locations {
                let proof = try? ClipboardLinkedFileIO.inspect(URL(fileURLWithPath: location.path), expectedIdentity: location.identity)
                guard proof?.digest == location.savedDigest, proof?.byteCount == location.byteCount else { throw ClipboardHistoryFileConflictError.stalePlan }
                if let proof { proofs[location.id] = proof }
            }
            return proofs
        }
        return try await withTaskCancellationHandler { try await inspection.value } onCancel: { inspection.cancel() }
    }

    private func saveFileResolutionJournal(_ journal: ClipboardSyncFileResolutionJournal, planID: UUID) throws {
        try syncWrite { database in
            try database.execute(sql: "UPDATE clipboard_sync_file_resolutions SET journal = ? WHERE plan_id = ? AND phase = 'preparing'",
                arguments: [try JSONEncoder().encode(journal), planID.uuidString])
        }
    }

    func resumeFileConflictResolutions(account: ClipboardSyncAccount, control: ClipboardSyncControl) async throws {
        let pending = try linkedRead { database in
            try Row.fetchAll(database, sql: """
                SELECT plan_id, journal FROM clipboard_sync_file_resolutions
                WHERE account_id = ? AND epoch = ? AND phase = 'preparing'
                """, arguments: [account.identifier, control.epoch.uuidString]).map { row in
                    guard let id = UUID(uuidString: row["plan_id"]) else { throw ClipboardSyncServiceError.corruptData }
                    return (id, try JSONDecoder().decode(ClipboardSyncFileResolutionJournal.self, from: row["journal"]))
                }
        }
        for (id, journal) in pending where !activeFileConflictResolutions.contains(id) {
            do { _ = try await executeFileConflictResolution(planID: id, choice: journal.choice) }
            catch is ClipboardHistoryFileConflictError { continue }
        }
    }

    func completeFileConflictResolutions(account: ClipboardSyncAccount, control: ClipboardSyncControl) throws {
        let pending = try linkedRead { database in
            try Row.fetchAll(database, sql: """
                SELECT plan_id, object_id, journal FROM clipboard_sync_file_resolutions
                WHERE account_id = ? AND epoch = ? AND phase = 'staged'
                """, arguments: [account.identifier, control.epoch.uuidString])
        }
        for row in pending {
            let journal = try JSONDecoder().decode(ClipboardSyncFileResolutionJournal.self, from: row["journal"])
            guard let objectID = UUID(uuidString: row["object_id"]),
                  try syncFileVersionIsCommitted(objectID: objectID, versionID: journal.resultID) else { continue }
            try syncWrite { database in
                // An unavailable/dirty location still needs every retained input.
                guard try Bool.fetchOne(database, sql: """
                    SELECT NOT EXISTS(SELECT 1 FROM clipboard_sync_linked_locations
                      WHERE account_id = ? AND epoch = ? AND object_id = ? AND (base_version_id != ? OR state != 'current'))
                    """, arguments: [account.identifier, control.epoch.uuidString, objectID.uuidString, journal.resultID.uuidString]) == true else { return }
                try database.execute(sql: "UPDATE clipboard_sync_file_resolutions SET phase = 'complete' WHERE plan_id = ?", arguments: [row["plan_id"] as String])
                try database.execute(sql: "DELETE FROM clipboard_sync_file_conflict_pins WHERE plan_id = ?", arguments: [row["plan_id"] as String])
            }
        }
    }

    static func pinFileConflictVersion(_ version: UUID, planID: UUID, snapshot: ClipboardSyncFileConflictSnapshot, in database: Database) throws {
        try database.execute(sql: """
            INSERT OR IGNORE INTO clipboard_sync_file_conflict_pins(plan_id, account_id, epoch, object_id, version_id) VALUES (?, ?, ?, ?, ?)
            """, arguments: [planID.uuidString, snapshot.accountID, snapshot.epoch.uuidString, snapshot.objectID.uuidString, version.uuidString])
    }

    @concurrent
    static func verifyPreparedFileVersion(_ prepared: ClipboardSyncPreparedFileVersion,
        account: ClipboardSyncAccount, control: ClipboardSyncControl, key: Data) async throws {
        guard let body = prepared.descriptor.body else { throw ClipboardSyncServiceError.corruptData }
        var plain = SHA256(), encrypted = SHA256()
        var count: Int64 = 0, cipherCount: Int64 = 0
        for index in 0..<body.chunkCount {
            try Task.checkCancellation()
            let bytes = try ClipboardSyncFileTransfer.readSegment(in: prepared.uploadDirectory, index: index)
            let data = try ClipboardSyncCodec.openFileSegment(bytes, descriptor: prepared.descriptor,
                account: account, control: control, key: key, index: index)
            plain.update(data: data); encrypted.update(data: bytes)
            count += Int64(data.count); cipherCount += Int64(bytes.count)
        }
        guard count == prepared.descriptor.originalByteCount, Data(plain.finalize()) == prepared.descriptor.contentDigest,
              cipherCount == body.encryptedByteCount, Data(encrypted.finalize()) == body.digest else { throw ClipboardSyncServiceError.corruptData }
    }
}
