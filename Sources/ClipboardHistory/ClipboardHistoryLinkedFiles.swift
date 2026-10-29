import Foundation
import GRDB

/// Display plans capture SQL values only. Native facts are resolved by the
/// caller after releasing the page's read transaction. Actions keep live checks.
struct ClipboardHistoryFileDisplayPlan<Value: Sendable>: Sendable {
    let resolve: @Sendable (inout ClipboardHistoryFileDisplayFacts) -> Value
}

struct ClipboardHistoryFileDisplayFacts: Sendable {
    private struct Identity: Hashable {
        let path: String
        let identity: Data
        let nativeIdentity: Data?
        var requiresReadable: Bool = true
    }
    private var availability: [Identity: Bool] = [:]
    private var applications: [String: Bool] = [:]

    mutating func isAvailable(path: String, identity: Data, nativeIdentity: Data?) -> Bool {
        let key = Identity(path: path, identity: identity, nativeIdentity: nativeIdentity)
        if let cached = availability[key] { return cached }
        let available = ClipboardLinkedIdentityResolution.isAvailable(path: path, identity: identity, nativeIdentity: nativeIdentity)
        availability[key] = available
        return available
    }

    mutating func isApplication(path: String) -> Bool {
        if let cached = applications[path] { return cached }
        let application = ClipboardApplicationPackage.isApplication(URL(fileURLWithPath: path))
        applications[path] = application
        return application
    }

    mutating func isStoredFileAvailable(path: String?, identity: Data?) -> Bool {
        guard let path, let identity else { return false }
        let key = Identity(path: path, identity: identity, nativeIdentity: nil, requiresReadable: false)
        if let cached = availability[key] { return cached }
        let available = ClipboardSyncFileIO.isAvailable(path: path, identity: identity)
        availability[key] = available
        return available
    }
}

extension ClipboardHistoryModule {
    public func associateFileLocation(_ request: ClipboardHistoryFileLocationAssociation) async throws -> ClipboardHistoryLinkedFileLocation {
        let generation = syncGeneration
        let base = try linkedRead { try Self.linkedObjectBase(request, in: $0) }
        let inspection = Task.detached(priority: .userInitiated) {
            try ClipboardLinkedFileIO.inspect(request.url)
        }
        let proof = try await withTaskCancellationHandler {
            try await inspection.value
        } onCancel: { inspection.cancel() }
        try Task.checkCancellation()
        try await waitForWriteTurn()
        guard generation == syncGeneration,
              ClipboardSyncFileIO.isAvailable(path: proof.url.path, identity: proof.identity) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let result = try syncWrite { database in
            let current = try Self.linkedObjectBase(request, in: database)
            guard current.accountID == base.accountID, current.epoch == base.epoch,
                  current.descriptor.versionID == base.descriptor.versionID else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            if let existing = try Row.fetchOne(database, sql: """
                SELECT * FROM clipboard_sync_linked_locations
                WHERE account_id = ? AND epoch = ? AND (path = ? OR identity = ?)
                """, arguments: [base.accountID, base.epoch, proof.url.path, proof.identity]) {
                guard (existing["object_id"] as String) == request.objectID.uuidString,
                      (existing["identity"] as Data) == proof.identity else {
                    throw ClipboardHistoryModuleError.fileLocationAlreadyAssociated
                }
                return try Self.linkedFileLocation(existing)
            }
            let id = UUID()
            let state: ClipboardHistoryLinkedFileLocationState = proof.digest == base.descriptor.contentDigest ? .current : .localChanges
            try database.execute(sql: """
                INSERT INTO clipboard_sync_linked_locations
                    (id, account_id, epoch, object_id, path, bookmark, identity, kind,
                     base_version_id, base_digest, state, observed_digest, native_identity)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'associated', ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, base.accountID, base.epoch, request.objectID.uuidString,
                    proof.url.path, proof.bookmark, proof.identity, base.descriptor.versionID.uuidString,
                    base.descriptor.contentDigest, state.rawValue, proof.digest, try proof.nativeIdentity?.encoded()])
            try Self.bumpHistoryRevision(in: database)
            return ClipboardHistoryLinkedFileLocation(id: id, objectID: request.objectID,
                baseVersionID: base.descriptor.versionID, url: proof.url, kind: .associated, state: state)
        }
        publishMutation()
        if !syncSuspended { await retrySync() }
        return result
    }

    public func linkedFileLocations(for entryID: ClipboardHistoryEntryID) throws -> [ClipboardHistoryLinkedFileLocation] {
        try requiredDatabase().read { database in
            let storedID = entryID.value.uuidString.lowercased()
            guard try isLiveEntry(storedID, at: now(), in: database) else { throw ClipboardHistoryModuleError.entryNotFound }
            return try Self.linkedFileLocations(entryID: storedID, in: database)
        }
    }

    static func linkedFileLocations(entryID: String, in database: Database) throws -> [ClipboardHistoryLinkedFileLocation] {
        var facts = ClipboardHistoryFileDisplayFacts()
        return try linkedFileLocationPlans(entryIDs: [entryID], in: database)[entryID]?.map { $0.resolve(&facts) } ?? []
    }

    static func linkedFileLocationPlans(entryIDs: [String],
        in database: Database) throws -> [String: [ClipboardHistoryFileDisplayPlan<ClipboardHistoryLinkedFileLocation>]] {
        guard !entryIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: entryIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(database, sql: """
                SELECT DISTINCT member.entry_id, location.*, choice.current_version_id AS application_update_version
                FROM clipboard_sync_linked_locations AS location
                JOIN clipboard_sync_file_members AS member
                  ON member.account_id = location.account_id AND member.epoch = location.epoch
                    AND member.object_id = location.object_id
                LEFT JOIN clipboard_sync_file_selections AS choice ON choice.account_id = location.account_id
                  AND choice.epoch = location.epoch AND choice.object_id = location.object_id
                WHERE member.entry_id IN (\(placeholders)) AND \(Self.liveSyncFileMember)
                  AND location.account_id = (SELECT account_id FROM clipboard_sync_settings WHERE id = 1)
                ORDER BY member.entry_id, location.kind, location.path, location.id
                """, arguments: StatementArguments(entryIDs))
        var result: [String: [ClipboardHistoryFileDisplayPlan<ClipboardHistoryLinkedFileLocation>]] = [:]
        var locations: [String: ClipboardHistoryFileDisplayPlan<ClipboardHistoryLinkedFileLocation>] = [:]
        for row in rows {
            let id: String = row["id"]
            let location: ClipboardHistoryFileDisplayPlan<ClipboardHistoryLinkedFileLocation>
            if let cached = locations[id] { location = cached }
            else {
                location = try linkedFileLocationPlan(row)
                locations[id] = location
            }
            result[row["entry_id"], default: []].append(location)
        }
        return result
    }

    static func createLinkedFileSchema(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE clipboard_sync_linked_locations (
                id TEXT PRIMARY KEY NOT NULL,
                account_id TEXT NOT NULL, epoch TEXT NOT NULL, object_id TEXT NOT NULL,
                path TEXT NOT NULL, bookmark BLOB NOT NULL, identity BLOB NOT NULL,
                kind TEXT NOT NULL, base_version_id TEXT NOT NULL, base_digest BLOB NOT NULL,
                state TEXT NOT NULL, pending_version_id TEXT, observed_digest BLOB,
                applying_version_id TEXT, applying_digest BLOB, replacement_path TEXT, replacement_identity BLOB,
                UNIQUE(account_id, epoch, object_id, path)
            ) WITHOUT ROWID;
            CREATE INDEX clipboard_sync_linked_locations_object
                ON clipboard_sync_linked_locations(account_id, epoch, object_id);
            """)
        try seedInitialLinkedFileLocations(in: database)
    }

    /// Initial consent already authorized these two locations: the captured
    /// original and the received working copy. Other copies are never scanned.
    static func seedInitialLinkedFileLocations(in database: Database) throws {
        let rows = try Row.fetchAll(database, sql: """
            SELECT member.account_id, member.epoch, member.object_id, member.origin,
                   version.descriptor, version.local_path, version.local_bookmark, version.local_identity
            FROM clipboard_sync_file_members AS member
            JOIN clipboard_sync_file_selections AS choice USING(account_id, epoch, object_id)
            JOIN clipboard_sync_file_versions AS version ON version.account_id = member.account_id
              AND version.epoch = member.epoch AND version.object_id = member.object_id
              AND version.version_id = choice.complete_version_id
            WHERE version.transfer_state = 'complete' AND \(liveSyncFileMember)
              AND version.local_path IS NOT NULL AND version.local_bookmark IS NOT NULL
              AND version.local_identity IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM clipboard_sync_linked_locations AS location
                WHERE location.account_id = member.account_id AND location.epoch = member.epoch
                  AND location.object_id = member.object_id AND location.kind IN ('original', 'workingCopy'))
            """)
        for row in rows {
            let descriptor = try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: row["descriptor"])
            guard let digest = descriptor.contentDigest else { continue }
            let origin: String = row["origin"]
            try database.execute(sql: """
                INSERT OR IGNORE INTO clipboard_sync_linked_locations
                    (id, account_id, epoch, object_id, path, bookmark, identity, kind,
                     base_version_id, base_digest, state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'current')
                """, arguments: [UUID().uuidString, row["account_id"] as String, row["epoch"] as String,
                    row["object_id"] as String, row["local_path"] as String, row["local_bookmark"] as Data,
                    row["local_identity"] as Data,
                    origin == "local" ? ClipboardHistoryLinkedFileLocationKind.original.rawValue
                        : ClipboardHistoryLinkedFileLocationKind.workingCopy.rawValue,
                    descriptor.versionID.uuidString, digest])
        }
    }

    static func linkedFileLocation(_ row: Row) throws -> ClipboardHistoryLinkedFileLocation {
        var facts = ClipboardHistoryFileDisplayFacts()
        return try linkedFileLocationPlan(row).resolve(&facts)
    }

    private static func linkedFileLocationPlan(_ row: Row) throws -> ClipboardHistoryFileDisplayPlan<ClipboardHistoryLinkedFileLocation> {
        guard let id = UUID(uuidString: row["id"]), let objectID = UUID(uuidString: row["object_id"]),
              let base = UUID(uuidString: row["base_version_id"]),
              let kind = ClipboardHistoryLinkedFileLocationKind(rawValue: row["kind"]),
              let storedState = ClipboardHistoryLinkedFileLocationState(rawValue: row["state"]) else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        let path: String = row["path"]
        let identity: Data = row["identity"]
        let nativeIdentity: Data? = row["native_identity"]
        let storedApplication = row["is_application"] as Bool? ?? false
        let revision: UInt64 = row["revision"]
        let applicationVersion = row.hasColumn("application_update_version")
            ? (row["application_update_version"] as String?).flatMap(UUID.init(uuidString:)) : nil
        return .init { facts in
            let available = facts.isAvailable(path: path, identity: identity, nativeIdentity: nativeIdentity)
            let isApplication = storedApplication || facts.isApplication(path: path)
            return ClipboardHistoryLinkedFileLocation(id: id, objectID: objectID, baseVersionID: base,
                url: URL(fileURLWithPath: path), kind: kind,
                state: [.detached, .identityUncertain, .paused].contains(storedState) || available ? storedState : .unavailable,
                revision: revision, applicationUpdateVersionID: isApplication && applicationVersion != base ? applicationVersion : nil)
        }
    }

    private static func linkedObjectBase(
        _ request: ClipboardHistoryFileLocationAssociation, in database: Database
    ) throws -> (accountID: String, epoch: String, descriptor: ClipboardSyncFileDescriptor) {
        guard let accountID = try String.fetchOne(database, sql: "SELECT account_id FROM clipboard_sync_settings WHERE id = 1"),
              let row = try Row.fetchOne(database, SQLRequest<Row>(literal: """
                SELECT member.epoch, version.descriptor FROM clipboard_sync_file_members AS member
                JOIN clipboard_entries AS entry ON entry.id = member.entry_id
                JOIN clipboard_sync_file_selections AS choice USING(account_id, epoch, object_id)
                JOIN clipboard_sync_file_versions AS version ON version.account_id = member.account_id
                  AND version.epoch = member.epoch AND version.object_id = member.object_id
                  AND version.version_id = choice.complete_version_id
                WHERE member.entry_id = \(request.entryID.value.uuidString.lowercased())
                  AND member.object_id = \(request.objectID.uuidString) AND member.account_id = \(accountID)
                  AND version.transfer_state = 'complete' AND \(SQL(sql: liveSyncFileMember))
                  AND (\(syncEntryPublicationAuthority(accountID: accountID)))
                """)) else { throw ClipboardHistoryModuleError.operationUnavailable }
        let descriptor = try JSONDecoder().decode(ClipboardSyncFileDescriptor.self, from: row["descriptor"])
        guard descriptor.contentDigest != nil else { throw ClipboardHistoryModuleError.operationUnavailable }
        return (accountID, row["epoch"], descriptor)
    }

    func linkedRead<Value>(_ body: (Database) throws -> Value) throws -> Value {
        try requiredDatabase().read(body)
    }
}
