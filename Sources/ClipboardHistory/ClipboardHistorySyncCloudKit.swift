import CloudKit
import CryptoKit
import Foundation
import os

/// CloudKit only sees opaque metadata and encrypted assets. Domain decisions,
/// keys, retry journals, and account consent remain in ClipboardHistoryModule.
actor ClipboardSyncCloudKit: ClipboardSyncTransport {
    /// Replaces only the external, account-scoped record read. Native callers
    /// retain the checked database and owned CloudKit operation lifecycle.
    typealias RecordReader = @Sendable (ClipboardSyncAccount, [CKRecord.ID], [String]) async throws
        -> [CKRecord.ID: Result<CKRecord, Error>]
    private typealias RecordFetch = @Sendable ([CKRecord.ID], [String]) async throws
        -> [CKRecord.ID: Result<CKRecord, Error>]

    /// External native account and operation submission, kept together so an
    /// isolated adapter fixture never falls through to the signed live service.
    struct NativeOperations: Sendable {
        let accountOwner: @Sendable () async throws -> String
        let add: @Sendable (CKDatabaseOperation) -> Void
    }

    private struct Database: Sendable {
        let account: ClipboardSyncAccount
        let add: @Sendable (CKDatabaseOperation) -> Void
    }

    private static let controlName = "control.v1"
    private static let controlType = "ClipboardSyncControlV1"
    private static let objectType = "ClipboardSyncObjectV1"
    private static let chunkType = "ClipboardSyncChunkV1"
    private static let controlKeys = [
        "protocolVersion", "accountID", "keyID", "keyCheck", "epoch", "phase", "commitMarker",
    ]
    private static let chunkMetadataKeys = ["operationID", "epoch", "keyID", "chunkIndex", "chunkDigest"]
    private static let metadataKeys = controlKeys + chunkMetadataKeys + ["metadata"]
    private static let batchSize = 100

    private var container: CKContainer?
    private var cancellationGeneration = 0
    private var operations: [UUID: CKDatabaseOperation] = [:]
    private let recordReader: RecordReader?
    private let nativeOperations: NativeOperations?

    init(recordReader: RecordReader? = nil, nativeOperations: NativeOperations? = nil) {
        self.recordReader = recordReader
        self.nativeOperations = nativeOperations
    }

    func account() async throws -> ClipboardSyncAccount {
        let generation = cancellationGeneration
        do {
            let owner: String
            if let nativeOperations {
                owner = try await nativeOperations.accountOwner()
            } else {
                let container = try checkedContainer()
                let status = try await container.accountStatus()
                try checkCancellation(generation)
                guard status == .available else {
                    throw ClipboardSyncServiceError.accountUnavailable
                }
                owner = try await container.userRecordID().recordName
            }
            try checkCancellation(generation)
            let account = ClipboardSyncAccount(
                container: ClipboardSyncNativeConfiguration.container,
                environment: ClipboardSyncNativeConfiguration.environment,
                owner: owner
            )
            try ClipboardSyncNativeConfiguration.validate(account)
            return account
        } catch {
            try checkCancellation(generation)
            throw Self.failure(error)
        }
    }

    func control(for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl? {
        let generation = cancellationGeneration
        let fetch = try await recordFetcher(for: account)
        try checkCancellation(generation)
        do {
            let record = try await fetchOptionalRecord(
                controlID(account), desiredKeys: Self.controlKeys, fetch: fetch
            )
            try checkCancellation(generation)
            return try record.map { try decodeControl($0, account: account) }
        } catch {
            try checkCancellation(generation)
            // The module still requires explicit recovery for an established
            // collection. After retirement, absence permits its fresh candidate.
            if Self.hasCode(error, .zoneNotFound) || Self.hasCode(error, .userDeletedZone) { return nil }
            throw Self.failure(error)
        }
    }

    func createControl(
        _ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount
    ) async throws -> ClipboardSyncControl {
        let generation = cancellationGeneration
        let database = try await checkedDatabase(for: account)
        try checkCancellation(generation)
        guard candidate.accountID == account.identifier, candidate.serverToken == nil,
              candidate.phase == "active", candidate.keyCheck.count == 32
        else { throw ClipboardSyncServiceError.corruptData }
        do {
            try await ensureZone(zoneID(account), database: database)
            try checkCancellation(generation)
            if let current = try await control(for: account) {
                try checkCancellation(generation)
                return current
            }
            try checkCancellation(generation)
            let record = try controlRecord(candidate, account: account)
            let saved = try await saveAtomically([record], database: database)
            try checkCancellation(generation)
            guard let authoritative = saved[record.recordID] else {
                throw ClipboardSyncServiceError.corruptData
            }
            return try decodeControl(authoritative, account: account)
        } catch {
            // A conflicting initializer or a lost successful response chooses
            // the server's immutable key identity, never the local candidate.
            try checkCancellation(generation)
            if let authoritative = try? await control(for: account) {
                try checkCancellation(generation)
                return authoritative
            }
            try checkCancellation(generation)
            throw Self.failure(error)
        }
    }

    func changes(
        for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?
    ) async throws -> ClipboardSyncChanges {
        let generation = cancellationGeneration
        let database = try await checkedDatabase(for: account)
        try checkCancellation(generation)
        try validateControl(control, account: account)
        let token = try cursor.map(Self.decodeChangeToken)
        let fetched: NativeChanges
        do {
            fetched = try await fetchChanges(
                zoneID(account), token: token, database: database
            )
        } catch {
            try checkCancellation(generation)
            guard Self.hasCode(error, .changeTokenExpired) else {
                throw Self.failure(error)
            }
            // The module's durable inbox makes a full replay safe; an expired
            // provider cursor is not a reason to discard locally retained data.
            do {
                fetched = try await fetchChanges(
                    zoneID(account), token: nil, database: database
                )
            } catch {
                try checkCancellation(generation)
                throw Self.failure(error)
            }
        }
        try checkCancellation(generation)
        guard fetched.deletedRecordIDs.allSatisfy({ Self.ownsZone($0.zoneID, account: account) }) else {
            throw ClipboardSyncServiceError.accountChanged
        }
        guard !fetched.deletedRecordIDs.contains(where: { Self.sameRecord($0, controlID(account), account: account) }) else {
            throw ClipboardSyncServiceError.missingRemoteState
        }
        // A retained zone includes deletion history from completed resets. A
        // content deletion is not the loss of the permanent authority record.
        var requiresAuthorityRefresh = !fetched.deletedRecordIDs.isEmpty
        var records: [ClipboardSyncRemoteRecord] = []
        for record in fetched.records {
            guard Self.ownsZone(record.recordID.zoneID, account: account) else {
                throw ClipboardSyncServiceError.accountChanged
            }
            switch record.recordType {
            case Self.objectType:
                let remote = try decodeMetadata(record)
                if remote.epoch == control.epoch, remote.keyID == control.keyID {
                    records.append(remote)
                }
            case Self.controlType:
                let observed = try decodeControl(record, account: account)
                if observed.epoch != control.epoch || observed.keyID != control.keyID || observed.phase != "active" {
                    requiresAuthorityRefresh = true
                }
            case Self.chunkType:
                // Unpublished immutable chunks are not complete history.
                break
            default:
                throw ClipboardSyncServiceError.unsupportedVersion
            }
        }
        if requiresAuthorityRefresh {
            let authoritative = try await self.control(for: account)
            try checkCancellation(generation)
            guard let authoritative, authoritative.epoch == control.epoch,
                  authoritative.keyID == control.keyID, authoritative.keyCheck == control.keyCheck,
                  authoritative.phase == "active" else { throw ClipboardSyncServiceError.missingRemoteState }
        }
        return ClipboardSyncChanges(
            records: records.sorted { $0.recordID < $1.recordID },
            cursor: try NSKeyedArchiver.archivedData(
                withRootObject: fetched.token, requiringSecureCoding: true
            ),
            hasMore: fetched.moreComing
        )
    }

    func download(
        _ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount
    ) async throws -> [Data] {
        let generation = cancellationGeneration
        let fetch = try await recordFetcher(for: account)
        try checkCancellation(generation)
        try validateMetadata(record)
        var chunks: [Data] = []
        var byteCount: Int64 = 0
        var digest = SHA256()
        for start in stride(from: 0, to: record.chunkCount, by: Self.batchSize) {
            try checkCancellation(generation)
            let end = start + min(Self.batchSize, record.chunkCount - start)
            let ids = (start..<end).map { chunkID(record, index: $0, account: account) }
            let fetched: [CKRecord.ID: Result<CKRecord, Error>]
            do {
                fetched = try await fetch(ids, Self.chunkMetadataKeys + ["asset"])
            } catch {
                try checkCancellation(generation)
                throw Self.failure(error)
            }
            try checkCancellation(generation)
            for (offset, id) in ids.enumerated() {
                guard let result = fetched[id] else { throw ClipboardSyncServiceError.corruptData }
                let chunk = try Self.requiredChunk(result)
                try validateChunk(chunk, remote: record, index: start + offset)
                guard let asset = chunk["asset"] as? CKAsset, let url = asset.fileURL else {
                    throw ClipboardSyncServiceError.corruptData
                }
                let data: Data
                do { data = try Data(contentsOf: url) }
                catch { throw ClipboardSyncServiceError.localStorage }
                guard chunk["chunkDigest"] as? Data == Data(SHA256.hash(data: data)) else {
                    throw ClipboardSyncServiceError.corruptData
                }
                let addition = byteCount.addingReportingOverflow(Int64(data.count))
                guard !addition.overflow, addition.partialValue <= record.encryptedByteCount else {
                    throw ClipboardSyncServiceError.corruptData
                }
                byteCount = addition.partialValue
                digest.update(data: data)
                chunks.append(data)
            }
        }
        guard byteCount == record.encryptedByteCount, Data(digest.finalize()) == record.digest else {
            throw ClipboardSyncServiceError.corruptData
        }
        return chunks
    }

    func commit(
        _ upload: ClipboardSyncUpload,
        for account: ClipboardSyncAccount,
        control: ClipboardSyncControl
    ) async throws -> ClipboardSyncControl {
        let generation = cancellationGeneration
        let database = try await checkedDatabase(for: account)
        try checkCancellation(generation)
        try validateControl(control, account: account)
        try validateUpload(upload, control: control)
        do {
            if let completed = try await completedCommit(
                upload.record, account: account, database: database
            ) {
                try checkCancellation(generation)
                return completed
            }
            try checkCancellation(generation)
            let staging = try makeStagingDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }
            var currentControl = control
            // Chunks may exceed a provider operation's record count. Each
            // bounded batch is fenced by the same control CAS. The manifest
            // becomes visible only after every chunk has been acknowledged.
            for start in stride(from: 0, to: upload.chunks.count, by: Self.batchSize) {
                try checkCancellation(generation)
                let end = start + min(Self.batchSize, upload.chunks.count - start)
                let ids = (start..<end).map { chunkID(upload.record, index: $0, account: account) }
                let previous = try await fetchRecords(
                    ids, desiredKeys: Self.chunkMetadataKeys, database: database
                )
                try checkCancellation(generation)
                var pending: [CKRecord] = []
                for (offset, index) in (start..<end).enumerated() {
                    let id = ids[offset]
                    let chunkDigest = Data(SHA256.hash(data: upload.chunks[index]))
                    guard let existing = previous[id] else {
                        throw ClipboardSyncServiceError.corruptData
                    }
                    switch existing {
                    case .success(let record):
                        try validateChunk(record, remote: upload.record, index: index)
                        guard record["chunkDigest"] as? Data == chunkDigest else {
                            throw ClipboardSyncServiceError.corruptData
                        }
                    case .failure(let error):
                        guard Self.hasCode(error, .unknownItem) else { throw error }
                        let url = staging.appendingPathComponent("\(index).ciphertext")
                        do {
                            try upload.chunks[index].write(to: url, options: .withoutOverwriting)
                            try FileManager.default.setAttributes(
                                [.posixPermissions: 0o600], ofItemAtPath: url.path
                            )
                        } catch { throw ClipboardSyncServiceError.localStorage }
                        let record = CKRecord(recordType: Self.chunkType, recordID: id)
                        record["operationID"] = upload.record.operationID.uuidString as NSString
                        record["epoch"] = upload.record.epoch.uuidString as NSString
                        record["keyID"] = upload.record.keyID.uuidString as NSString
                        record["chunkIndex"] = index as NSNumber
                        record["chunkDigest"] = chunkDigest as NSData
                        record["asset"] = CKAsset(fileURL: url)
                        pending.append(record)
                    }
                }
                if !pending.isEmpty {
                    currentControl = try await commitBatch(
                        pending, control: currentControl, account: account, database: database
                    )
                    try checkCancellation(generation)
                }
            }
            let manifest = CKRecord(
                recordType: Self.objectType,
                recordID: CKRecord.ID(recordName: upload.record.recordID, zoneID: zoneID(account))
            )
            manifest["metadata"] = try JSONEncoder().encode(upload.record) as NSData
            let result = try await commitBatch(
                [manifest], control: currentControl, account: account, database: database
            )
            try checkCancellation(generation)
            return result
        } catch {
            try checkCancellation(generation)
            // An immutable manifest is the receipt. Another writer may have
            // advanced control after our successful but unacknowledged commit.
            if let completed = try? await completedCommit(
                upload.record, account: account, database: database
            ) {
                try checkCancellation(generation)
                return completed
            }
            try checkCancellation(generation)
            throw Self.failure(error)
        }
    }

    func transition(_ control: ClipboardSyncControl, to phase: String, epoch: UUID,
                    for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl {
        let generation = cancellationGeneration
        let database = try await checkedDatabase(for: account)
        try checkCancellation(generation)
        let allowed = (control.phase == "active" && phase == "resetting" && epoch != control.epoch)
            || (control.phase == "resetting" && phase == "stopped" && epoch == control.epoch)
            || (control.phase == "stopped" && phase == "active" && epoch != control.epoch)
        guard allowed, control.accountID == account.identifier, control.serverToken != nil else {
            throw ClipboardSyncServiceError.missingRemoteState
        }
        let next = ClipboardSyncControl(accountID: control.accountID, keyID: control.keyID,
            keyCheck: control.keyCheck, epoch: epoch, phase: phase, serverToken: control.serverToken)
        do {
            let record = try controlRecord(next, account: account)
            let saved = try await saveAtomically([record], database: database)
            try checkCancellation(generation)
            guard let result = saved[record.recordID] else { throw ClipboardSyncServiceError.corruptData }
            return try decodeControl(result, account: account)
        } catch {
            try checkCancellation(generation)
            throw Self.failure(error)
        }
    }

    func clearPage(for account: ClipboardSyncAccount, control: ClipboardSyncControl,
                   cursor: Data?) async throws -> ClipboardSyncCleanupPage {
        let generation = cancellationGeneration
        let database = try await checkedDatabase(for: account)
        try checkCancellation(generation)
        do {
            guard let current = try await self.control(for: account), current.phase == "resetting",
                  control.phase == "resetting", current.epoch == control.epoch,
                  current.keyID == control.keyID, current.keyCheck == control.keyCheck else {
                throw ClipboardSyncServiceError.missingRemoteState
            }
            try checkCancellation(generation)
            let fetched: NativeChanges
            do {
                fetched = try await fetchChanges(zoneID(account), token: try cursor.map(Self.decodeChangeToken), database: database)
            } catch {
                try checkCancellation(generation)
                guard Self.hasCode(error, .changeTokenExpired) else { throw error }
                fetched = try await fetchChanges(zoneID(account), token: nil, database: database)
            }
            try checkCancellation(generation)
            var ids: [CKRecord.ID] = []
            for record in fetched.records {
                guard Self.ownsZone(record.recordID.zoneID, account: account) else { throw ClipboardSyncServiceError.accountChanged }
                switch record.recordType {
                case Self.controlType:
                    _ = try decodeControl(record, account: account)
                case Self.objectType:
                    let metadata = try decodeMetadata(record)
                    guard metadata.epoch != current.epoch else { throw ClipboardSyncServiceError.corruptData }
                    ids.append(record.recordID)
                case Self.chunkType:
                    guard let value = record["epoch"] as? String, let epoch = UUID(uuidString: value), epoch != current.epoch,
                          let operation = record["operationID"] as? String, let operationID = UUID(uuidString: operation),
                          let key = record["keyID"] as? String, UUID(uuidString: key) != nil,
                          let index = record["chunkIndex"] as? NSNumber, index.intValue >= 0,
                          record.recordID.recordName == "chunk.\(operationID.uuidString.lowercased()).\(index.intValue)",
                          (record["chunkDigest"] as? Data)?.count == 32 else { throw ClipboardSyncServiceError.corruptData }
                    ids.append(record.recordID)
                default: throw ClipboardSyncServiceError.unsupportedVersion
                }
            }
            // The page may be replayed after an ambiguous successful deletion.
            // Refetch metadata only and omit already absent records. A concurrent
            // cleaner must still win the same control CAS before deleting any.
            if !ids.isEmpty {
                let live = try await fetchRecords(ids, desiredKeys: Self.metadataKeys, database: database)
                try checkCancellation(generation)
                ids = try ids.filter { id in
                    guard let result = live[id] else { throw ClipboardSyncServiceError.corruptData }
                    switch result {
                    case .success: return true
                    case .failure(let error):
                        if Self.hasCode(error, .unknownItem) { return false }
                        throw error
                    }
                }
            }
            var advanced = current
            if !ids.isEmpty {
                let fence = try controlRecord(current, account: account)
                let saved = try await saveAtomically([fence], deleting: ids, database: database)
                try checkCancellation(generation)
                guard let result = saved[fence.recordID] else { throw ClipboardSyncServiceError.corruptData }
                advanced = try decodeControl(result, account: account)
            }
            let token = try NSKeyedArchiver.archivedData(withRootObject: fetched.token, requiringSecureCoding: true)
            return ClipboardSyncCleanupPage(control: advanced, cursor: token, deletedRecordCount: ids.count,
                hasMore: fetched.moreComing || !ids.isEmpty)
        } catch {
            try checkCancellation(generation)
            throw Self.failure(error)
        }
    }

    func purge(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount,
               control: ClipboardSyncControl) async throws -> ClipboardSyncControl {
        let generation = cancellationGeneration
        let database = try await checkedDatabase(for: account)
        try checkCancellation(generation)
        try validateControl(control, account: account)
        try validateMetadata(record)
        guard record.epoch == control.epoch, record.keyID == control.keyID else {
            throw ClipboardSyncServiceError.corruptData
        }
        var current = control
        do {
            // Keep the manifest until every chunk batch has been removed. A
            // lost response can repeat each batch without losing its identity.
            for start in stride(from: 0, to: record.chunkCount, by: Self.batchSize) {
                let end = start + min(Self.batchSize, record.chunkCount - start)
                let ids = (start..<end).map { chunkID(record, index: $0, account: account) }
                let fetched = try await fetchRecords(ids, desiredKeys: Self.chunkMetadataKeys, database: database)
                try checkCancellation(generation)
                var present: [CKRecord.ID] = []
                for (offset, id) in ids.enumerated() {
                    guard let result = fetched[id] else { throw ClipboardSyncServiceError.corruptData }
                    switch result {
                    case .success(let chunk):
                        try validateChunk(chunk, remote: record, index: start + offset)
                        present.append(id)
                    case .failure(let error):
                        guard Self.hasCode(error, .unknownItem) else { throw error }
                    }
                }
                if !present.isEmpty {
                    let fence = try controlRecord(current, account: account)
                    let saved = try await saveAtomically([fence], deleting: present, database: database)
                    try checkCancellation(generation)
                    guard let authoritative = saved[fence.recordID] else { throw ClipboardSyncServiceError.corruptData }
                    current = try decodeControl(authoritative, account: account)
                }
            }
            let id = CKRecord.ID(recordName: record.recordID, zoneID: zoneID(account))
            let manifest = try await fetchOptionalRecord(id, desiredKeys: ["metadata"], database: database)
            try checkCancellation(generation)
            if let manifest {
                guard try decodeMetadata(manifest) == record else { throw ClipboardSyncServiceError.corruptData }
                let fence = try controlRecord(current, account: account)
                let saved = try await saveAtomically([fence], deleting: [id], database: database)
                try checkCancellation(generation)
                guard let authoritative = saved[fence.recordID] else { throw ClipboardSyncServiceError.corruptData }
                current = try decodeControl(authoritative, account: account)
            }
            return current
        } catch {
            try checkCancellation(generation)
            throw Self.failure(error)
        }
    }

    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount,
        control: ClipboardSyncControl, progress: @Sendable (Int64) async throws -> Void
    ) async throws -> ClipboardSyncControl {
        let generation = cancellationGeneration
        let database = try await checkedDatabase(for: account)
        try checkCancellation(generation)
        try validateControl(control, account: account)
        try validateMetadata(upload.record)
        guard upload.record.epoch == control.epoch, upload.record.keyID == control.keyID else {
            throw ClipboardSyncServiceError.missingRemoteState
        }
        try await progress(0)
        do {
            if let completed = try await completedCommit(upload.record, account: account, database: database) {
                try checkCancellation(generation)
                try await progress(upload.record.encryptedByteCount)
                return completed
            }
            var current = control
            var digest = SHA256()
            var byteCount: Int64 = 0
            for start in stride(from: 0, to: upload.record.chunkCount, by: Self.batchSize) {
                try checkCancellation(generation)
                let end = start + min(Self.batchSize, upload.record.chunkCount - start)
                let ids = (start..<end).map { chunkID(upload.record, index: $0, account: account) }
                let existing = try await fetchRecords(ids, desiredKeys: Self.chunkMetadataKeys, database: database)
                try checkCancellation(generation)
                var pending: [CKRecord] = []
                for (offset, index) in (start..<end).enumerated() {
                    try checkCancellation(generation)
                    let bytes = try ClipboardSyncFileTransfer.readSegment(in: upload.directory, index: index)
                    let chunkDigest = Data(SHA256.hash(data: bytes))
                    digest.update(data: bytes)
                    let addition = byteCount.addingReportingOverflow(Int64(bytes.count))
                    guard !addition.overflow, addition.partialValue <= upload.record.encryptedByteCount else {
                        throw ClipboardSyncServiceError.corruptData
                    }
                    byteCount = addition.partialValue
                    guard let previous = existing[ids[offset]] else { throw ClipboardSyncServiceError.corruptData }
                    switch previous {
                    case .success(let record):
                        try validateChunk(record, remote: upload.record, index: index)
                        guard record["chunkDigest"] as? Data == chunkDigest else { throw ClipboardSyncServiceError.corruptData }
                    case .failure(let error):
                        guard Self.hasCode(error, .unknownItem) else { throw error }
                        let record = CKRecord(recordType: Self.chunkType, recordID: ids[offset])
                        record["operationID"] = upload.record.operationID.uuidString as NSString
                        record["epoch"] = upload.record.epoch.uuidString as NSString
                        record["keyID"] = upload.record.keyID.uuidString as NSString
                        record["chunkIndex"] = index as NSNumber
                        record["chunkDigest"] = chunkDigest as NSData
                        record["asset"] = CKAsset(fileURL: ClipboardSyncFileTransfer.segmentURL(in: upload.directory, index: index))
                        pending.append(record)
                    }
                }
                if !pending.isEmpty {
                    current = try await commitBatch(pending, control: current, account: account, database: database)
                }
                try checkCancellation(generation)
                try await progress(byteCount)
                try checkCancellation(generation)
            }
            guard byteCount == upload.record.encryptedByteCount, Data(digest.finalize()) == upload.record.digest else {
                throw ClipboardSyncServiceError.corruptData
            }
            let manifest = CKRecord(recordType: Self.objectType,
                recordID: .init(recordName: upload.record.recordID, zoneID: zoneID(account)))
            manifest["metadata"] = try JSONEncoder().encode(upload.record) as NSData
            let completed = try await commitBatch([manifest], control: current, account: account, database: database)
            try checkCancellation(generation)
            return completed
        } catch {
            try checkCancellation(generation)
            if let completed = try? await completedCommit(upload.record, account: account, database: database) {
                try checkCancellation(generation)
                return completed
            }
            throw Self.failure(error)
        }
    }

    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int,
        for account: ClipboardSyncAccount) async throws -> Data {
        let generation = cancellationGeneration
        let fetch = try await recordFetcher(for: account)
        try checkCancellation(generation)
        try validateMetadata(record)
        guard index >= 0, index < record.chunkCount else { throw ClipboardSyncServiceError.corruptData }
        let id = chunkID(record, index: index, account: account)
        do {
            let results = try await fetch([id], Self.chunkMetadataKeys + ["asset"])
            try checkCancellation(generation)
            guard let result = results[id] else { throw ClipboardSyncServiceError.corruptData }
            let chunk = try Self.requiredChunk(result)
            try validateChunk(chunk, remote: record, index: index)
            guard let url = (chunk["asset"] as? CKAsset)?.fileURL else {
                throw ClipboardSyncServiceError.corruptData
            }
            let bytes = try ClipboardSyncFileTransfer.readAsset(at: url)
            guard chunk["chunkDigest"] as? Data == Data(SHA256.hash(data: bytes)) else {
                throw ClipboardSyncServiceError.corruptData
            }
            try checkCancellation(generation)
            return bytes
        } catch {
            try checkCancellation(generation)
            throw Self.failure(error)
        }
    }

    func cancel() {
        // Safe before activation: cancelling must not construct a container,
        // inspect the system account, or touch synchronizable Keychain items.
        cancellationGeneration += 1
        for operation in operations.values { operation.cancel() }
    }

    private func checkedContainer() throws -> CKContainer {
        try Task.checkCancellation()
        try ClipboardSyncNativeConfiguration.requireCapabilities()
        if let container { return container }
        let created = CKContainer(identifier: ClipboardSyncNativeConfiguration.container)
        container = created
        return created
    }

    private func checkedDatabase(for expected: ClipboardSyncAccount) async throws -> Database {
        let generation = cancellationGeneration
        try ClipboardSyncNativeConfiguration.validate(expected)
        let observed = try await account()
        try checkCancellation(generation)
        guard observed == expected else { throw ClipboardSyncServiceError.accountChanged }
        if let nativeOperations { return Database(account: expected, add: nativeOperations.add) }
        let database = try checkedContainer().privateCloudDatabase
        return Database(account: expected, add: { database.add($0) })
    }

    private func recordFetcher(for account: ClipboardSyncAccount) async throws -> RecordFetch {
        try Task.checkCancellation()
        try ClipboardSyncNativeConfiguration.validate(account)
        if let recordReader {
            return { ids, keys in
                try Self.normalizedRecords(try await recordReader(account, ids, keys), requested: ids, account: account)
            }
        }
        // Bind once per entry point, as before, rather than repeating native
        // account discovery for every bounded batch in an ordinary download.
        let database = try await checkedDatabase(for: account)
        return { ids, keys in try await self.fetchRecords(ids, desiredKeys: keys, database: database) }
    }

    private func checkCancellation(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == cancellationGeneration else { throw CancellationError() }
    }

    private func zoneID(_ account: ClipboardSyncAccount) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "ClipboardSyncV1-\(account.identifier)", ownerName: account.owner)
    }

    /// CloudKit accepts both names for the checked private-database owner. The
    /// concrete account identity remains part of the zone and domain authority.
    private nonisolated static func ownsZone(_ zone: CKRecordZone.ID, account: ClipboardSyncAccount) -> Bool {
        zone.zoneName == "ClipboardSyncV1-\(account.identifier)"
            && (zone.ownerName == account.owner || zone.ownerName == CKCurrentUserDefaultName)
    }

    private nonisolated static func sameRecord(_ lhs: CKRecord.ID, _ rhs: CKRecord.ID,
        account: ClipboardSyncAccount) -> Bool {
        lhs.recordName == rhs.recordName && ownsZone(lhs.zoneID, account: account) && ownsZone(rhs.zoneID, account: account)
    }

    /// Index callbacks by the requested identity, accepting only the known
    /// current-owner alias. Never rewrite a returned record's CAS system fields.
    private nonisolated static func normalizedResults<Value>(_ results: [CKRecord.ID: Value],
        requested: [CKRecord.ID], account: ClipboardSyncAccount) throws -> [CKRecord.ID: Value] {
        guard requested.allSatisfy({ ownsZone($0.zoneID, account: account) }) else {
            throw ClipboardSyncServiceError.accountChanged
        }
        let byName = Dictionary(grouping: requested, by: \.recordName)
        guard byName.values.allSatisfy({ $0.count == 1 }), results.count == requested.count else {
            throw ClipboardSyncServiceError.corruptData
        }
        var normalized: [CKRecord.ID: Value] = [:]
        for (id, value) in results {
            guard ownsZone(id.zoneID, account: account) else { throw ClipboardSyncServiceError.accountChanged }
            guard let target = byName[id.recordName]?.first, normalized[target] == nil else {
                throw ClipboardSyncServiceError.corruptData
            }
            normalized[target] = value
        }
        return normalized
    }

    private nonisolated static func normalizedRecords(_ results: [CKRecord.ID: Result<CKRecord, Error>],
        requested: [CKRecord.ID], account: ClipboardSyncAccount) throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        let normalized = try normalizedResults(results, requested: requested, account: account)
        for (id, result) in normalized {
            if case .success(let record) = result {
                guard ownsZone(record.recordID.zoneID, account: account) else { throw ClipboardSyncServiceError.accountChanged }
                guard sameRecord(record.recordID, id, account: account) else { throw ClipboardSyncServiceError.corruptData }
            }
        }
        return normalized
    }

    private func controlID(_ account: ClipboardSyncAccount) -> CKRecord.ID {
        CKRecord.ID(recordName: Self.controlName, zoneID: zoneID(account))
    }

    private func chunkID(
        _ record: ClipboardSyncRemoteRecord, index: Int, account: ClipboardSyncAccount
    ) -> CKRecord.ID {
        CKRecord.ID(
            recordName: "chunk.\(record.operationID.uuidString.lowercased()).\(index)",
            zoneID: zoneID(account)
        )
    }

    private func validateControl(_ control: ClipboardSyncControl, account: ClipboardSyncAccount) throws {
        guard control.accountID == account.identifier, control.phase == "active",
              control.keyCheck.count == 32, control.serverToken != nil
        else { throw ClipboardSyncServiceError.missingRemoteState }
    }

    private func validateMetadata(_ record: ClipboardSyncRemoteRecord) throws {
        guard !record.recordID.isEmpty, record.recordID.utf8.count <= 255,
              record.recordID != Self.controlName, !record.recordID.hasPrefix("chunk."),
              record.chunkCount > 0, record.encryptedByteCount > 0,
              Int64(record.chunkCount) <= record.encryptedByteCount,
              record.digest.count == 32
        else { throw ClipboardSyncServiceError.corruptData }
    }

    private func validateUpload(_ upload: ClipboardSyncUpload, control: ClipboardSyncControl) throws {
        try validateMetadata(upload.record)
        guard upload.record.epoch == control.epoch, upload.record.keyID == control.keyID,
              upload.chunks.count == upload.record.chunkCount
        else { throw ClipboardSyncServiceError.corruptData }
        var digest = SHA256()
        var count: Int64 = 0
        for chunk in upload.chunks {
            // The domain codec produces 4 MiB units. This provider guard is
            // per asset, not an application-level maximum object size.
            guard !chunk.isEmpty, chunk.count <= 50_000_000 else {
                throw ClipboardSyncServiceError.corruptData
            }
            let addition = count.addingReportingOverflow(Int64(chunk.count))
            guard !addition.overflow else { throw ClipboardSyncServiceError.corruptData }
            count = addition.partialValue
            digest.update(data: chunk)
        }
        guard count == upload.record.encryptedByteCount,
              Data(digest.finalize()) == upload.record.digest
        else { throw ClipboardSyncServiceError.corruptData }
    }

    private func validateChunk(_ chunk: CKRecord, remote: ClipboardSyncRemoteRecord, index: Int) throws {
        guard chunk.recordType == Self.chunkType,
              chunk["operationID"] as? String == remote.operationID.uuidString,
              chunk["epoch"] as? String == remote.epoch.uuidString,
              chunk["keyID"] as? String == remote.keyID.uuidString,
              (chunk["chunkIndex"] as? NSNumber)?.intValue == index,
              (chunk["chunkDigest"] as? Data)?.count == 32
        else { throw ClipboardSyncServiceError.corruptData }
    }

    private func decodeMetadata(_ record: CKRecord) throws -> ClipboardSyncRemoteRecord {
        guard record.recordType == Self.objectType, let data = record["metadata"] as? Data else {
            throw ClipboardSyncServiceError.corruptData
        }
        let metadata: ClipboardSyncRemoteRecord
        do { metadata = try JSONDecoder().decode(ClipboardSyncRemoteRecord.self, from: data) }
        catch { throw ClipboardSyncServiceError.unsupportedVersion }
        try validateMetadata(metadata)
        guard metadata.recordID == record.recordID.recordName else {
            throw ClipboardSyncServiceError.corruptData
        }
        return metadata
    }

    private func decodeControl(_ record: CKRecord, account: ClipboardSyncAccount) throws -> ClipboardSyncControl {
        guard record.recordType == Self.controlType, Self.sameRecord(record.recordID, controlID(account), account: account),
              (record["protocolVersion"] as? NSNumber)?.intValue == 1,
              record["accountID"] as? String == account.identifier,
              let key = record["keyID"] as? String, let keyID = UUID(uuidString: key),
              let keyCheck = record["keyCheck"] as? Data, keyCheck.count == 32,
              let epochValue = record["epoch"] as? String, let epoch = UUID(uuidString: epochValue),
              let phase = record["phase"] as? String,
              ["active", "resetting", "stopped"].contains(phase)
        else { throw ClipboardSyncServiceError.corruptData }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return ClipboardSyncControl(
            accountID: account.identifier, keyID: keyID, keyCheck: keyCheck,
            epoch: epoch, phase: phase, serverToken: archiver.encodedData
        )
    }

    private func controlRecord(_ control: ClipboardSyncControl, account: ClipboardSyncAccount) throws -> CKRecord {
        let record: CKRecord
        if let token = control.serverToken {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: token)
            unarchiver.requiresSecureCoding = true
            defer { unarchiver.finishDecoding() }
            guard let decoded = CKRecord(coder: unarchiver),
                  Self.sameRecord(decoded.recordID, controlID(account), account: account), decoded.recordType == Self.controlType
            else { throw ClipboardSyncServiceError.corruptData }
            record = decoded
        } else {
            record = CKRecord(recordType: Self.controlType, recordID: controlID(account))
        }
        record["protocolVersion"] = 1 as NSNumber
        record["accountID"] = account.identifier as NSString
        record["keyID"] = control.keyID.uuidString as NSString
        record["keyCheck"] = control.keyCheck as NSData
        record["epoch"] = control.epoch.uuidString as NSString
        record["phase"] = control.phase as NSString
        record["commitMarker"] = UUID().uuidString as NSString
        return record
    }

    private func commitBatch(
        _ content: [CKRecord], control: ClipboardSyncControl,
        account: ClipboardSyncAccount, database: Database
    ) async throws -> ClipboardSyncControl {
        let generation = cancellationGeneration
        try validateControl(control, account: account)
        let fence = try controlRecord(control, account: account)
        let saved = try await saveAtomically([fence] + content, database: database)
        try checkCancellation(generation)
        guard let authoritative = saved[fence.recordID] else {
            throw ClipboardSyncServiceError.corruptData
        }
        return try decodeControl(authoritative, account: account)
    }

    private func completedCommit(
        _ expected: ClipboardSyncRemoteRecord, account: ClipboardSyncAccount, database: Database
    ) async throws -> ClipboardSyncControl? {
        let generation = cancellationGeneration
        let id = CKRecord.ID(recordName: expected.recordID, zoneID: zoneID(account))
        let observed = try await fetchOptionalRecord(id, desiredKeys: ["metadata"], database: database)
        try checkCancellation(generation)
        guard let record = observed else { return nil }
        guard try decodeMetadata(record) == expected else { throw ClipboardSyncServiceError.corruptData }
        let authoritative = try await control(for: account)
        try checkCancellation(generation)
        guard let current = authoritative, current.epoch == expected.epoch,
              current.keyID == expected.keyID, current.phase == "active"
        else { throw ClipboardSyncServiceError.missingRemoteState }
        return current
    }

    private func makeStagingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnyDoorClipboardSync-\(UUID())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            return url
        } catch { throw ClipboardSyncServiceError.localStorage }
    }

    private static func decodeChangeToken(_ data: Data) throws -> CKServerChangeToken {
        guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else {
            throw ClipboardSyncServiceError.corruptData
        }
        return token
    }

    private func fetchOptionalRecord(
        _ id: CKRecord.ID, desiredKeys: [String], database: Database
    ) async throws -> CKRecord? {
        try await fetchOptionalRecord(id, desiredKeys: desiredKeys) { ids, keys in
            try await self.fetchRecords(ids, desiredKeys: keys, database: database)
        }
    }

    private func fetchOptionalRecord(
        _ id: CKRecord.ID, desiredKeys: [String], fetch: RecordFetch
    ) async throws -> CKRecord? {
        let generation = cancellationGeneration
        let results = try await fetch([id], desiredKeys)
        try checkCancellation(generation)
        guard let result = results[id] else { throw ClipboardSyncServiceError.corruptData }
        switch result {
        case .success(let record): return record
        case .failure(let error):
            if Self.hasCode(error, .unknownItem) { return nil }
            throw error
        }
    }

    /// Only a requested immutable chunk's own missing-record result is local
    /// to that body. Operation, zone, and control failures keep their authority.
    private nonisolated static func requiredChunk(_ result: Result<CKRecord, Error>) throws -> CKRecord {
        do { return try result.get() }
        catch {
            if (error as? CKError)?.code == .unknownItem { throw ClipboardSyncServiceError.recordUnavailable }
            throw failure(error)
        }
    }

    private func fetchRecords(
        _ ids: [CKRecord.ID], desiredKeys: [String], database: Database
    ) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        let operation = CKFetchRecordsOperation(recordIDs: ids)
        operation.desiredKeys = desiredKeys
        let results = OSAllocatedUnfairLock(initialState: [CKRecord.ID: Result<CKRecord, Error>]())
        operation.perRecordResultBlock = { id, result in results.withLock { $0[id] = result } }
        let fetched: [CKRecord.ID: Result<CKRecord, Error>] = try await run(operation, database: database) { continuation in
            operation.fetchRecordsResultBlock = { outcome in
                let collected = results.withLock { $0 }
                if collected.count == ids.count {
                    continuation.resume(returning: collected)
                } else {
                    switch outcome {
                    case .failure(let error): continuation.resume(throwing: error)
                    case .success: continuation.resume(throwing: ClipboardSyncServiceError.corruptData)
                    }
                }
            }
        }
        return try Self.normalizedRecords(fetched, requested: ids, account: database.account)
    }

    private func saveAtomically(_ records: [CKRecord], deleting ids: [CKRecord.ID] = [], database: Database) async throws -> [CKRecord.ID: CKRecord] {
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: ids)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = true
        let results = OSAllocatedUnfairLock(initialState: [CKRecord.ID: Result<CKRecord, Error>]())
        operation.perRecordSaveBlock = { id, result in results.withLock { $0[id] = result } }
        let deletions = OSAllocatedUnfairLock(initialState: [CKRecord.ID: Result<Void, Error>]())
        operation.perRecordDeleteBlock = { id, result in deletions.withLock { $0[id] = result } }
        return try await run(operation, database: database) { continuation in
            operation.modifyRecordsResultBlock = { outcome in
                let collected = results.withLock { $0 }
                do {
                    // Prefer the actual CAS/account error over sibling
                    // batchRequestFailed errors in an atomic operation.
                    let deleted = deletions.withLock { $0 }
                    let deleteErrors = deleted.values.compactMap { result -> Error? in
                        if case .failure(let error) = result { return error }; return nil
                    }
                    let saveErrors = collected.values.compactMap { result -> Error? in
                        if case .failure(let error) = result { return error }
                        return nil
                    }
                    let operationError: Error?
                    if case .failure(let error) = outcome { operationError = error } else { operationError = nil }
                    if let error = Self.atomicModificationFailure(saveErrors: saveErrors, deleteErrors: deleteErrors,
                        operationError: operationError) { throw error }
                    try outcome.get()
                    guard collected.count == records.count, deleted.count == ids.count else { throw ClipboardSyncServiceError.corruptData }
                    _ = try Self.normalizedResults(deleted, requested: ids, account: database.account)
                    let normalized = try Self.normalizedRecords(collected, requested: records.map(\.recordID), account: database.account)
                    continuation.resume(returning: try normalized.mapValues { try $0.get() })
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func ensureZone(_ id: CKRecordZone.ID, database: Database) async throws {
        let generation = cancellationGeneration
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: [CKRecordZone(zoneID: id)])
        let zone = OSAllocatedUnfairLock<Result<CKRecordZone, Error>?>(initialState: nil)
        operation.perRecordZoneSaveBlock = { _, result in zone.withLock { $0 = result } }
        let saved: CKRecordZone = try await run(operation, database: database) { continuation in
            operation.modifyRecordZonesResultBlock = { outcome in
                do {
                    try outcome.get()
                    guard let result = zone.withLock({ $0 }) else { throw ClipboardSyncServiceError.corruptData }
                    continuation.resume(returning: try result.get())
                } catch { continuation.resume(throwing: error) }
            }
        }
        try checkCancellation(generation)
        guard Self.ownsZone(saved.zoneID, account: database.account), Self.ownsZone(id, account: database.account),
              saved.capabilities.contains(.atomic) else {
            throw ClipboardSyncServiceError.capabilityUnavailable
        }
    }

    private struct NativeChanges: Sendable {
        let records: [CKRecord]
        let deletedRecordIDs: [CKRecord.ID]
        let token: CKServerChangeToken
        let moreComing: Bool
    }

    private struct ChangeAccumulator: Sendable {
        var records: [CKRecord] = []
        var deleted: [CKRecord.ID] = []
        var error: Error?
        var token: CKServerChangeToken?
        var moreComing = false
    }

    private func fetchChanges(
        _ id: CKRecordZone.ID, token: CKServerChangeToken?, database: Database
    ) async throws -> NativeChanges {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = token
        configuration.desiredKeys = Self.metadataKeys
        configuration.resultsLimit = Self.batchSize
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [id], configurationsByRecordZoneID: [id: configuration]
        )
        operation.fetchAllChanges = false
        let state = OSAllocatedUnfairLock(initialState: ChangeAccumulator())
        operation.recordWasChangedBlock = { _, result in
            state.withLock {
                switch result {
                case .success(let record): $0.records.append(record)
                case .failure(let error): $0.error = error
                }
            }
        }
        operation.recordWithIDWasDeletedBlock = { id, _ in state.withLock { $0.deleted.append(id) } }
        operation.recordZoneFetchResultBlock = { _, result in
            state.withLock {
                switch result {
                case .success(let result):
                    $0.token = result.serverChangeToken
                    $0.moreComing = result.moreComing
                case .failure(let error): $0.error = error
                }
            }
        }
        return try await run(operation, database: database) { continuation in
            operation.fetchRecordZoneChangesResultBlock = { outcome in
                let collected = state.withLock { $0 }
                do {
                    if let error = collected.error { throw error }
                    try outcome.get()
                    guard let token = collected.token else { throw ClipboardSyncServiceError.corruptData }
                    continuation.resume(returning: NativeChanges(
                        records: collected.records, deletedRecordIDs: collected.deleted,
                        token: token, moreComing: collected.moreComing
                    ))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Operations are registered before submission and remain retained until
    /// their final callback. Cancellation does not release asset files early.
    private func run<Value: Sendable>(
        _ operation: CKDatabaseOperation, database: Database,
        configure: (CheckedContinuation<Value, Error>) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        let generation = cancellationGeneration
        let id = UUID()
        operations[id] = operation
        defer { operations.removeValue(forKey: id) }
        let value: Value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                configure(continuation)
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
        try checkCancellation(generation)
        return value
    }

    nonisolated static func atomicModificationFailure(saveErrors: [Error], deleteErrors: [Error], operationError: Error? = nil) -> Error? {
        let allErrors = saveErrors + deleteErrors + (operationError.map { [$0] } ?? [])
        if let permanent = allErrors.compactMap(permanentFailure).first { return permanent }
        let delay = allErrors.compactMap { error -> TimeInterval? in
            if let cloud = error as? CKError { return retryAfter(cloud) }
            if case .network(let delay) = error as? ClipboardSyncServiceError { return delay }
            return nil
        }.filter { $0.isFinite && $0 > 0 }.max()
        func mapped(_ error: Error) -> Error {
            let result = Self.failure(error)
            if let delay {
                switch result as? ClipboardSyncServiceError {
                case .network, .conflict: return ClipboardSyncServiceError.network(retryAfter: delay)
                default: break
                }
            }
            return result
        }
        let saveFailures = saveErrors.filter { !hasCode($0, .batchRequestFailed) }
        let deleteFailures = deleteErrors.filter { !hasCode($0, .batchRequestFailed) }
        // Missing authority and access failures cannot be hidden by an already
        // absent deletion target. Atomic failure has not acknowledged the CAS.
        if let failure = saveFailures.first(where: { !hasCode($0, .serverRecordChanged) }) { return mapped(failure) }
        if let failure = deleteFailures.first(where: { !hasCode($0, .unknownItem) && !hasCode($0, .serverRecordChanged) }) {
            return mapped(failure)
        }
        if (saveFailures + deleteFailures).contains(where: { hasCode($0, .serverRecordChanged) }) {
            return mapped(ClipboardSyncServiceError.conflict)
        }
        if deleteFailures.contains(where: { hasCode($0, .unknownItem) }) {
            return mapped(ClipboardSyncServiceError.conflict)
        }
        return operationError.map(mapped)
    }

    private nonisolated static func hasCode(_ error: Error, _ code: CKError.Code) -> Bool {
        guard let cloud = error as? CKError else { return false }
        if cloud.code == code { return true }
        return cloud.partialErrorsByItemID?.values.contains { hasCode($0, code) } ?? false
    }

    private nonisolated static func permanentFailure(_ error: Error) -> ClipboardSyncServiceError? {
        guard let cloud = error as? CKError else {
            let mapped = failure(error) as? ClipboardSyncServiceError
            switch mapped {
            case .providerRejected, .unsupportedVersion: return mapped
            default: return nil
            }
        }
        if hasCode(error, .incompatibleVersion) { return .unsupportedVersion }
        if [.internalError, .serverRejectedRequest, .invalidArguments, .limitExceeded,
            .constraintViolation, .managedAccountRestricted].contains(where: { hasCode(error, $0) }) {
            return .providerRejected
        }
        return cloud.partialErrorsByItemID?.values.compactMap(permanentFailure).first
    }

    private nonisolated static func retryAfter(_ cloud: CKError) -> TimeInterval? {
        let nested = cloud.partialErrorsByItemID?.values.compactMap { ($0 as? CKError).flatMap(retryAfter) } ?? []
        return (nested + [cloud.retryAfterSeconds].compactMap { $0 }).filter { $0.isFinite && $0 > 0 }.max()
    }

    private nonisolated static func failure(_ error: Error) -> Error {
        if error is CancellationError || error is ClipboardSyncServiceError { return error }
        if ClipboardSyncFileErrors.isAccessDenied(error) { return ClipboardSyncServiceError.localFileAccessDenied }
        if case .fileOperationFailed = error as? ClipboardHistoryStorageError { return ClipboardSyncServiceError.localStorage }
        guard let cloud = error as? CKError else {
            if let url = error as? URLError {
                switch url.code {
                case .cancelled: return CancellationError()
                case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                     .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable,
                     .internationalRoamingOff, .callIsActive, .dataNotAllowed:
                    return ClipboardSyncServiceError.network(retryAfter: nil)
                default: break
                }
            }
            // An unrecognized provider failure is not evidence of a transient
            // network outage. Pause until an explicit retry instead of looping.
            return ClipboardSyncServiceError.providerRejected
        }
        if let permanent = permanentFailure(error) { return permanent }
        if hasCode(error, .serverRecordChanged) { return ClipboardSyncServiceError.conflict }
        if let nested = cloud.partialErrorsByItemID?.values.first(where: {
            !hasCode($0, .batchRequestFailed)
        }) {
            let mapped = failure(nested)
            if case .network = mapped as? ClipboardSyncServiceError {
                return ClipboardSyncServiceError.network(retryAfter: retryAfter(cloud))
            }
            return mapped
        }
        switch cloud.code {
        case .notAuthenticated, .accountTemporarilyUnavailable:
            return ClipboardSyncServiceError.accountUnavailable
        case .missingEntitlement, .badContainer, .badDatabase:
            return ClipboardSyncServiceError.capabilityUnavailable
        case .permissionFailure:
            return ClipboardSyncServiceError.accessDenied
        case .quotaExceeded:
            return ClipboardSyncServiceError.quota
        case .zoneNotFound, .userDeletedZone, .unknownItem:
            return ClipboardSyncServiceError.missingRemoteState
        case .operationCancelled:
            return CancellationError()
        case .assetFileNotFound, .assetFileModified, .assetNotAvailable:
            return ClipboardSyncServiceError.localStorage
        default:
            return ClipboardSyncServiceError.network(retryAfter: retryAfter(cloud))
        }
    }
}
