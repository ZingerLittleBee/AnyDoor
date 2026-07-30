import Darwin
import CryptoKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

extension ClipboardHistoryModule {
    struct LegacyMigrationDiagnostics: Equatable, Sendable {
        let retentionStartByEntryID: [UUID: Date]
    }

    enum LegacyFileState: String, Equatable, Sendable {
        case ordinary
        case legacyUnverified
        case unavailable
        case legacyOwned
    }

    struct LegacyFileMemberDiagnostics: Equatable, Sendable {
        let capturedPath: String
        let state: LegacyFileState
    }

    struct LegacyFileDiagnostics: Equatable, Sendable {
        let members: [LegacyFileMemberDiagnostics]
        let digestReadCount: Int
        let maximumDigestReadSize: Int
        let ownedPayloadCount: Int
        let duplicateFingerprint: Data?
    }

    public func migrateLegacy(
        _ request: ClipboardHistoryLegacyMigrationRequest
    ) async throws -> ClipboardHistoryLegacyMigrationOutcome {
        guard
            request.transfer.version
                == ClipboardHistoryLegacyTransfer.currentVersion
        else {
            throw ClipboardHistoryModuleError.unsupportedLegacyTransferVersion(
                request.transfer.version
            )
        }
        if let report = try currentLegacyMigrationReport() {
            return .alreadyPublished(report)
        }
        guard let liveDatabase = database, let keys = derivedKeys else {
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }
        let existingEntryCount = try await liveDatabase.read {
            try Int.fetchOne(
                $0,
                sql: "SELECT COUNT(*) FROM clipboard_entries"
            ) ?? 0
        }
        guard existingEntryCount == 0 else {
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }

        monitoringEnabled = false
        await captureMonitor?.setEnabled(false)
        await stopMaintenanceTask()
        await stopDerivedJobScheduler()
        _ = await searchIndexRebuildTask?.value
        searchIndexRebuildTask = nil
        try liveDatabase.close()
        self.database = nil

        let stagingRoot = legacyMigrationStagingRoot
        var stagingDatabase: DatabasePool?
        do {
            try removeEmptyInitialStore()
            if FileManager.default.fileExists(atPath: stagingRoot.path) {
                try FileManager.default.removeItem(at: stagingRoot)
            }
            try Self.prepareStoreDirectories(at: stagingRoot)
            let staged = try Self.openDatabase(
                at: Self.databaseURL(in: stagingRoot),
                databaseKey: keys.databaseKey
            )
            stagingDatabase = staged
            let stagingResult = try buildLegacyStagingStore(
                request,
                database: staged,
                root: stagingRoot,
                payloadKey: keys.payloadKey
            )
            try verifyLegacyStagingStore(
                request,
                expectedReport: stagingResult.report,
                expectedEntryIDs: stagingResult.entryIDs,
                database: staged,
                root: stagingRoot,
                payloadKey: keys.payloadKey
            )
            try staged.close()
            stagingDatabase = nil
            try faultInjector.check(.legacyMigrationBeforePublication)
            try publishLegacyStagingStore(from: stagingRoot)
            try faultInjector.check(.legacyMigrationAfterPublication)

            let published = try Self.openDatabase(
                at: Self.databaseURL(in: storeRoot),
                databaseKey: keys.databaseKey
            )
            database = published
            searchIndexRebuildTask = Self.makeSearchIndexRebuildTask(
                for: published,
                faultInjector: faultInjector
            )
            availability = .ready
            availabilityReason = nil
            automaticImageTextIndexingEnabled =
                Self
                .storedAutomaticImageTextIndexingSetting(in: published)
            startMaintenanceTaskIfNeeded()
            startDerivedJobSchedulerIfNeeded()
            return .published(stagingResult.report)
        } catch let error as ClipboardHistoryModuleError {
            try? stagingDatabase?.close()
            if FileManager.default.fileExists(atPath: stagingRoot.path) {
                try? FileManager.default.removeItem(at: stagingRoot)
            }
            try? reopenPublishedStoreIfPresent(keys: keys)
            if case .unsupportedLegacyTransferVersion = error {
                throw error
            }
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        } catch {
            try? stagingDatabase?.close()
            if FileManager.default.fileExists(atPath: stagingRoot.path) {
                try? FileManager.default.removeItem(at: stagingRoot)
            }
            try? reopenPublishedStoreIfPresent(keys: keys)
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }
    }

    public func tagDefinitions() throws -> [ClipboardHistoryTagDefinition] {
        let database = try requiredDatabase()
        return try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, display_name
                    FROM clipboard_tag_definitions
                    ORDER BY display_order, id
                    """
            ).map {
                ClipboardHistoryTagDefinition(
                    id: $0["id"],
                    displayName: $0["display_name"]
                )
            }
        }
    }

    func legacyMigrationDiagnostics() throws -> LegacyMigrationDiagnostics {
        let database = try requiredDatabase()
        return try database.read { database in
            let pairs = try Row.fetchAll(
                database,
                sql: """
                    SELECT entry_id, retention_started_at
                    FROM clipboard_retention_state
                    ORDER BY entry_id
                    """
            ).compactMap { row -> (UUID, Date)? in
                guard let id = UUID(uuidString: row["entry_id"]) else {
                    return nil
                }
                let timestamp: Double = row["retention_started_at"]
                return (
                    id,
                    Date(timeIntervalSince1970: timestamp)
                )
            }
            return LegacyMigrationDiagnostics(
                retentionStartByEntryID: Dictionary(
                    uniqueKeysWithValues: pairs
                )
            )
        }
    }

    func legacyFileDiagnostics(
        for entryID: ClipboardHistoryEntryID
    ) throws -> LegacyFileDiagnostics {
        let database = try requiredDatabase()
        let storedID = entryID.value.uuidString.lowercased()
        return try database.read { database in
            let members = try Row.fetchAll(
                database,
                sql: """
                    SELECT captured_path, reference_provenance
                    FROM clipboard_file_members
                    WHERE entry_id = ?
                    ORDER BY item_index, member_index
                    """,
                arguments: [storedID]
            ).compactMap { row -> LegacyFileMemberDiagnostics? in
                guard let state = LegacyFileState(
                    rawValue: row["reference_provenance"]
                ) else {
                    return nil
                }
                return LegacyFileMemberDiagnostics(
                    capturedPath: row["captured_path"],
                    state: state
                )
            }
            let ownedPayloadCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM clipboard_file_members
                    WHERE entry_id = ? AND payload_id IS NOT NULL
                    """,
                arguments: [storedID]
            ) ?? 0
            let fingerprint = try Data.fetchOne(
                database,
                sql: """
                    SELECT fingerprint
                    FROM clipboard_duplicate_candidates
                    WHERE entry_id = ?
                    """,
                arguments: [storedID]
            )
            return LegacyFileDiagnostics(
                members: members,
                digestReadCount: legacyDigestReadCount,
                maximumDigestReadSize: legacyMaximumDigestReadSize,
                ownedPayloadCount: ownedPayloadCount,
                duplicateFingerprint: fingerprint
            )
        }
    }

    private var legacyMigrationStagingRoot: URL {
        storeRoot.deletingLastPathComponent().appendingPathComponent(
            "\(storeRoot.lastPathComponent).legacy-staging-v1"
        )
    }

    private func removeEmptyInitialStore() throws {
        guard FileManager.default.fileExists(atPath: storeRoot.path) else {
            return
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: storeRoot,
            includingPropertiesForKeys: nil
        )
        let allowedNames: Set<String> = [
            "history.sqlite",
            "history.sqlite-wal",
            "history.sqlite-shm",
            "payloads",
            "staging",
        ]
        guard
            children.allSatisfy({
                allowedNames.contains($0.lastPathComponent)
            })
        else {
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }
        for directoryName in ["payloads", "staging"] {
            let directory = storeRoot.appendingPathComponent(directoryName)
            if FileManager.default.fileExists(atPath: directory.path),
                !(try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )).isEmpty
            {
                throw ClipboardHistoryModuleError.legacyMigrationFailed
            }
        }
        try FileManager.default.removeItem(at: storeRoot)
    }

    private func publishLegacyStagingStore(from stagingRoot: URL) throws {
        try FileManager.default.moveItem(at: stagingRoot, to: storeRoot)
        let parent = storeRoot.deletingLastPathComponent()
        let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0
            || Darwin.fsync(descriptor) == 0
        else {
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }
    }

    private func reopenPublishedStoreIfPresent(
        keys: ClipboardHistoryDerivedKeys
    ) throws {
        guard
            FileManager.default.fileExists(
                atPath: Self.databaseURL(in: storeRoot).path
            )
        else {
            database = nil
            availability = .unavailable
            availabilityReason = .storeIOFailure
            return
        }
        let reopened = try Self.openDatabase(
            at: Self.databaseURL(in: storeRoot),
            databaseKey: keys.databaseKey
        )
        database = reopened
        searchIndexRebuildTask = Self.makeSearchIndexRebuildTask(
            for: reopened,
            faultInjector: faultInjector
        )
        availability = .ready
        availabilityReason = nil
    }

    private func buildLegacyStagingStore(
        _ request: ClipboardHistoryLegacyMigrationRequest,
        database: DatabasePool,
        root: URL,
        payloadKey: Data
    ) throws -> LegacyStagingBuildResult {
        let tagOrder = try legacyTagOrder(for: request.transfer)
        let validTagIDs = Set(tagOrder.map(\.id))
        let payloadStore = ClipboardHistoryPayloadStore(
            root: root,
            key: payloadKey,
            faultInjector: faultInjector
        )
        var retainedCount = 0
        var omittedCount = 0
        var ownedPayloadCount = 0
        var redundantPayloadCount = 0
        var retainedEntryIDs: Set<String> = []

        try database.write { database in
            try database.execute(
                sql: """
                    DELETE FROM clipboard_tag_definitions
                    """
            )
            for (order, tag) in tagOrder.enumerated() {
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_tag_definitions(
                            id, display_name, display_order
                        ) VALUES (?, ?, ?)
                        """,
                    arguments: [tag.id, tag.name, order]
                )
            }
            try database.execute(
                sql: """
                    UPDATE clipboard_maintenance_metadata
                    SET integer_value = NULL, real_value = NULL,
                        text_value = ?, data_value = NULL
                    WHERE key = 'retentionPeriod'
                    """,
                arguments: [request.transfer.retentionPeriod.rawValue]
            )

            for (inputOrder, entry) in request.transfer.entries.enumerated() {
                let tagIDs = Set(entry.tagIDs).intersection(validTagIDs)
                let lostOnlyTagProtection =
                    !entry.tagIDs.isEmpty
                    && tagIDs.isEmpty
                    && !entry.isFavorite
                let retentionStart =
                    lostOnlyTagProtection
                    ? now()
                    : entry.capturedAt
                let isProtected = entry.isFavorite || !tagIDs.isEmpty
                if isExpiredLegacyEntry(
                    retentionStart: retentionStart,
                    isProtected: isProtected,
                    period: request.transfer.retentionPeriod
                ) {
                    omittedCount += 1
                    continue
                }
                try insertLegacyEntry(
                    entry,
                    inputOrder: inputOrder,
                    validTagIDs: tagIDs,
                    retentionStart: retentionStart,
                    isProtected: isProtected,
                    payloadDirectory: request.payloadDirectory,
                    payloadStore: payloadStore,
                    into: database,
                    ownedPayloadCount: &ownedPayloadCount,
                    redundantPayloadCount: &redundantPayloadCount
                )
                retainedCount += 1
                retainedEntryIDs.insert(
                    entry.id.uuidString.lowercased()
                )
            }
            try setLegacyMigrationReport(
                ClipboardHistoryLegacyMigrationReport(
                    retainedEntryCount: retainedCount,
                    omittedExpiredEntryCount: omittedCount,
                    ownedPayloadCount: ownedPayloadCount,
                    redundantLegacyPayloadCount: redundantPayloadCount
                ),
                in: database
            )
            try Self.bumpSearchIndexGeneration(in: database)
            try Self.bumpHistoryRevision(in: database)
        }
        return LegacyStagingBuildResult(
            report: ClipboardHistoryLegacyMigrationReport(
                retainedEntryCount: retainedCount,
                omittedExpiredEntryCount: omittedCount,
                ownedPayloadCount: ownedPayloadCount,
                redundantLegacyPayloadCount: redundantPayloadCount
            ),
            entryIDs: retainedEntryIDs
        )
    }

    private func legacyTagOrder(
        for transfer: ClipboardHistoryLegacyTransfer
    ) throws -> [ClipboardHistoryLegacyTag] {
        guard transfer.tags.allSatisfy({ !$0.id.isEmpty }),
            Set(transfer.tags.map(\.id)).count == transfer.tags.count
        else {
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }
        let byID = Dictionary(
            uniqueKeysWithValues: transfer.tags.map { ($0.id, $0) }
        )
        var seen = Set<String>()
        var result: [ClipboardHistoryLegacyTag] = []
        for persistentID in transfer.categoryOrder {
            guard persistentID.hasPrefix("tag:") else { continue }
            let id = String(persistentID.dropFirst(4))
            guard let tag = byID[id], seen.insert(id).inserted else {
                continue
            }
            result.append(tag)
        }
        result.append(
            contentsOf: transfer.tags.filter {
                seen.insert($0.id).inserted
            }
        )
        return result
    }

    private func isExpiredLegacyEntry(
        retentionStart: Date,
        isProtected: Bool,
        period: ClipboardHistoryRetentionPeriod
    ) -> Bool {
        guard !isProtected, let duration = period.duration else {
            return false
        }
        return retentionStart <= now().addingTimeInterval(-duration)
    }

    private func insertLegacyEntry(
        _ entry: ClipboardHistoryLegacyEntry,
        inputOrder: Int,
        validTagIDs: Set<String>,
        retentionStart: Date,
        isProtected: Bool,
        payloadDirectory: URL,
        payloadStore: ClipboardHistoryPayloadStore,
        into database: Database,
        ownedPayloadCount: inout Int,
        redundantPayloadCount: inout Int
    ) throws {
        if entry.kind == .file {
            try insertLegacyFileEntry(
                entry,
                inputOrder: inputOrder,
                validTagIDs: validTagIDs,
                retentionStart: retentionStart,
                isProtected: isProtected,
                payloadDirectory: payloadDirectory,
                payloadStore: payloadStore,
                into: database,
                ownedPayloadCount: &ownedPayloadCount,
                redundantPayloadCount: &redundantPayloadCount
            )
            return
        }
        let storedID = entry.id.uuidString.lowercased()
        let source = ClipboardHistoryCaptureSource(
            bundleIdentifier: entry.source.bundleIdentifier,
            displayName: entry.source.displayName,
            provenance: .legacy
        )
        let prepared = try prepareLegacyRepresentations(
            entry,
            payloadDirectory: payloadDirectory,
            payloadStore: payloadStore,
            into: database,
            ownedPayloadCount: &ownedPayloadCount,
            redundantPayloadCount: &redundantPayloadCount
        )
        if let thumbnail = prepared.thumbnail {
            try insertPayload(thumbnail, into: database, at: now())
        }
        try database.execute(
            sql: """
                INSERT INTO clipboard_entries(
                    id, captured_at, last_captured_at, recency_order,
                    source_bundle_id, source_display_name,
                    source_provenance, preview_text, is_favorite,
                    thumbnail_payload_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                storedID,
                entry.capturedAt.timeIntervalSince1970,
                entry.capturedAt.timeIntervalSince1970,
                -inputOrder,
                source.bundleIdentifier,
                source.displayName,
                source.provenance.rawValue,
                entry.previewText,
                entry.isFavorite,
                prepared.thumbnail?.id.uuidString.lowercased(),
            ]
        )
        try database.execute(
            sql: """
                INSERT INTO clipboard_items(entry_id, item_index)
                VALUES (?, 0)
                """,
            arguments: [storedID]
        )
        for (index, representation) in prepared.representations.enumerated() {
            switch representation {
            case .text(let type, let value, let searchKind):
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_representations(
                            entry_id, item_index, representation_index,
                            kind, type_identifier, text_value
                        ) VALUES (?, 0, ?, 'text', ?, ?)
                        """,
                    arguments: [storedID, index, type, value]
                )
                try Self.insertSearchField(
                    value: value,
                    kind: searchKind,
                    index: index,
                    rankingGroup: Self.searchRankingGroup(for: searchKind),
                    entryID: storedID,
                    into: database,
                    faultInjector: faultInjector
                )
            case .data(let type, let value):
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_representations(
                            entry_id, item_index, representation_index,
                            kind, type_identifier, data_value
                        ) VALUES (?, 0, ?, 'richText', ?, ?)
                        """,
                    arguments: [storedID, index, type, value]
                )
                if let derived = Self.derivedRichText(
                    from: value,
                    typeIdentifier: type
                ), !derived.isEmpty {
                    try Self.insertSearchField(
                        value: derived,
                        kind: "richText",
                        index: index,
                        rankingGroup: Self.searchRankingGroup(for: "richText"),
                        entryID: storedID,
                        into: database,
                        faultInjector: faultInjector
                    )
                }
            case .bitmap(let payload, let cleanup):
                try insertPayload(payload, into: database, at: now())
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_representations(
                            entry_id, item_index, representation_index,
                            kind, type_identifier, payload_id
                        ) VALUES (?, 0, ?, 'bitmap', ?, ?)
                        """,
                    arguments: [
                        storedID,
                        index,
                        UTType.png.identifier,
                        payload.id.uuidString.lowercased(),
                    ]
                )
                try insertLegacyCleanupProof(
                    cleanup,
                    payload: payload,
                    into: database
                )
            }
        }
        for facet in prepared.facets {
            try database.execute(
                sql: """
                    INSERT INTO clipboard_entry_facets(entry_id, facet)
                    VALUES (?, ?)
                    """,
                arguments: [storedID, facet.rawValue]
            )
        }
        for tagID in validTagIDs.sorted() {
            try database.execute(
                sql: """
                    INSERT INTO clipboard_entry_tags(entry_id, tag_id)
                    VALUES (?, ?)
                    """,
                arguments: [storedID, tagID]
            )
        }
        try database.execute(
            sql: """
                INSERT INTO clipboard_retention_state(
                    entry_id, retention_started_at, is_protected
                ) VALUES (?, ?, ?)
                """,
            arguments: [
                storedID,
                retentionStart.timeIntervalSince1970,
                isProtected,
            ]
        )
        let identity = try CanonicalIdentity(
            snapshot: prepared.canonicalSnapshot,
            fingerprintDigest: fingerprintDigest
        )
        try database.execute(
            sql: """
                INSERT INTO clipboard_duplicate_candidates(
                    fingerprint, entry_id, canonical_byte_count, created_at
                ) VALUES (?, ?, ?, ?)
                """,
            arguments: [
                identity.fingerprint,
                storedID,
                identity.canonicalByteCount,
                entry.capturedAt.timeIntervalSince1970,
            ]
        )
    }

    private func insertLegacyFileEntry(
        _ entry: ClipboardHistoryLegacyEntry,
        inputOrder: Int,
        validTagIDs: Set<String>,
        retentionStart: Date,
        isProtected: Bool,
        payloadDirectory: URL,
        payloadStore: ClipboardHistoryPayloadStore,
        into database: Database,
        ownedPayloadCount: inout Int,
        redundantPayloadCount: inout Int
    ) throws {
        guard !entry.files.isEmpty else {
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }
        let storedID = entry.id.uuidString.lowercased()
        let source = ClipboardHistoryCaptureSource(
            bundleIdentifier: entry.source.bundleIdentifier,
            displayName: entry.source.displayName,
            provenance: .legacy
        )
        var preparedMembers: [PreparedLegacyFileMember] = []
        for member in entry.files {
            let prepared = try prepareLegacyFileMember(
                member,
                payloadDirectory: payloadDirectory,
                payloadStore: payloadStore
            )
            if prepared.state == .legacyOwned {
                ownedPayloadCount += 1
            } else if prepared.state == .ordinary,
                member.storedName != nil
            {
                redundantPayloadCount += 1
            }
            preparedMembers.append(prepared)
        }

        try database.execute(
            sql: """
                INSERT INTO clipboard_entries(
                    id, captured_at, last_captured_at, recency_order,
                    source_bundle_id, source_display_name,
                    source_provenance, preview_text, is_favorite
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                storedID,
                entry.capturedAt.timeIntervalSince1970,
                entry.capturedAt.timeIntervalSince1970,
                -inputOrder,
                source.bundleIdentifier,
                source.displayName,
                source.provenance.rawValue,
                entry.previewText
                    ?? preparedMembers.first?.displayName,
                entry.isFavorite,
            ]
        )
        var facets: Set<ClipboardHistoryFacet> = [.file]
        var snapshotItems: [PasteboardSnapshot.Item] = []
        for (itemIndex, member) in preparedMembers.enumerated() {
            try database.execute(
                sql: """
                    INSERT INTO clipboard_items(entry_id, item_index)
                    VALUES (?, ?)
                    """,
                arguments: [storedID, itemIndex]
            )
            if let payload = member.payload {
                try insertPayload(payload, into: database, at: now())
                guard let cleanupProof = member.cleanupProof else {
                    throw ClipboardHistoryModuleError.legacyMigrationFailed
                }
                try insertLegacyCleanupProof(
                    cleanupProof,
                    payload: payload,
                    into: database
                )
            } else if let cleanupProof = member.cleanupProof {
                try insertLegacyRedundancyProof(
                    cleanupProof,
                    currentPath: member.currentPath,
                    into: database
                )
            }
            try database.execute(
                sql: """
                    INSERT INTO clipboard_representations(
                        entry_id, item_index, representation_index,
                        kind, type_identifier, data_value
                    ) VALUES (?, ?, 0, 'fileReference', ?, ?)
                    """,
                arguments: [
                    storedID,
                    itemIndex,
                    "public.file-url",
                    Data(),
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO clipboard_file_members(
                        entry_id, item_index, member_index,
                        captured_path, current_path, display_name,
                        bookmark_data, resource_type, availability,
                        payload_id, identity_data, reference_provenance
                    ) VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    storedID,
                    itemIndex,
                    member.capturedPath,
                    member.currentPath,
                    member.displayName,
                    member.bookmark,
                    member.resourceType,
                    member.availability,
                    member.payload?.id.uuidString.lowercased(),
                    member.identity,
                    member.state.rawValue,
                ]
            )
            for (kind, value) in [
                ("fileName", member.displayName),
                ("capturedPath", member.capturedPath),
                ("currentPath", member.currentPath),
            ] {
                guard let value else { continue }
                try Self.insertSearchField(
                    value: value,
                    kind: kind,
                    index: itemIndex,
                    rankingGroup: Self.searchRankingGroup(for: kind),
                    entryID: storedID,
                    into: database,
                    faultInjector: faultInjector
                )
            }
            if let resourceType = member.resourceType,
                UTType(resourceType)?.conforms(to: .image) == true
            {
                facets.insert(.image)
            }
            snapshotItems.append(
                PasteboardSnapshot.Item(
                    representations: [
                        .file(
                            PasteboardSnapshot.FileReference(
                                capturedPath: member.capturedPath,
                                displayName: member.displayName,
                                bookmark: member.bookmark ?? Data(),
                                identity: member.identity ?? Data(),
                                resourceType: member.resourceType
                            )
                        )
                    ]
                )
            )
        }
        for facet in facets {
            try database.execute(
                sql: """
                    INSERT INTO clipboard_entry_facets(entry_id, facet)
                    VALUES (?, ?)
                    """,
                arguments: [storedID, facet.rawValue]
            )
        }
        for tagID in validTagIDs.sorted() {
            try database.execute(
                sql: """
                    INSERT INTO clipboard_entry_tags(entry_id, tag_id)
                    VALUES (?, ?)
                    """,
                arguments: [storedID, tagID]
            )
        }
        try database.execute(
            sql: """
                INSERT INTO clipboard_retention_state(
                    entry_id, retention_started_at, is_protected
                ) VALUES (?, ?, ?)
                """,
            arguments: [
                storedID,
                retentionStart.timeIntervalSince1970,
                isProtected,
            ]
        )
        let identity = try CanonicalIdentity(
            snapshot: PasteboardSnapshot(
                items: snapshotItems,
                extraFacets: facets,
                allowsTextInference: false
            ),
            fingerprintDigest: fingerprintDigest
        )
        try database.execute(
            sql: """
                INSERT INTO clipboard_duplicate_candidates(
                    fingerprint, entry_id, canonical_byte_count, created_at
                ) VALUES (?, ?, ?, ?)
                """,
            arguments: [
                identity.fingerprint,
                storedID,
                identity.canonicalByteCount,
                entry.capturedAt.timeIntervalSince1970,
            ]
        )
    }

    private func prepareLegacyFileMember(
        _ member: ClipboardHistoryLegacyFileMember,
        payloadDirectory: URL,
        payloadStore: ClipboardHistoryPayloadStore
    ) throws -> PreparedLegacyFileMember {
        let originalURL = URL(fileURLWithPath: member.originalPath)
        let capturedCopyURL: URL?
        if let storedName = member.storedName {
            try validateLegacyPayloadName(storedName)
            let candidate = payloadDirectory.appendingPathComponent(storedName)
            capturedCopyURL =
                FileManager.default.fileExists(atPath: candidate.path)
                ? try safeLegacyPayloadURL(
                    named: storedName,
                    in: payloadDirectory
                )
                : nil
        } else {
            capturedCopyURL = nil
        }
        let capturedProof = capturedCopyURL.flatMap {
            try? streamedFileProof($0)
        }
        let currentReference = try? legacyFileReference(at: originalURL)

        if let capturedCopyURL, let capturedProof {
            if let currentReference,
                currentReference.isRegularFile,
                (try? streamedFileProof(currentReference.url))
                    == capturedProof
            {
                return PreparedLegacyFileMember(
                    capturedPath: member.originalPath,
                    currentPath: currentReference.url.path,
                    displayName: member.originalName,
                    bookmark: currentReference.bookmark,
                    identity: currentReference.identity,
                    resourceType: currentReference.resourceType,
                    availability: "available",
                    state: .ordinary,
                    payload: nil,
                    cleanupProof: LegacyCleanupProof(
                        relativePath: member.storedName
                            ?? capturedCopyURL.lastPathComponent,
                        plaintextByteCount: capturedProof.byteCount,
                        sha256: capturedProof.sha256
                    )
                )
            }
            let data = try Data(contentsOf: capturedCopyURL)
            let payload = try payloadStore.publish(
                data,
                kind: .legacyOwnedFile
            )
            return PreparedLegacyFileMember(
                capturedPath: member.originalPath,
                currentPath: nil,
                displayName: member.originalName,
                bookmark: nil,
                identity: nil,
                resourceType: currentReference?.resourceType
                    ?? UTType(
                        filenameExtension: originalURL.pathExtension
                    )?.identifier,
                availability: "owned",
                state: .legacyOwned,
                payload: payload,
                cleanupProof: LegacyCleanupProof(
                    relativePath: member.storedName
                        ?? capturedCopyURL.lastPathComponent,
                    plaintextByteCount: capturedProof.byteCount,
                    sha256: capturedProof.sha256
                )
            )
        }

        if let currentReference {
            return PreparedLegacyFileMember(
                capturedPath: member.originalPath,
                currentPath: currentReference.url.path,
                displayName: member.originalName,
                bookmark: currentReference.bookmark,
                identity: currentReference.identity,
                resourceType: currentReference.resourceType,
                availability: "available",
                state: .legacyUnverified,
                payload: nil,
                cleanupProof: nil
            )
        }
        return PreparedLegacyFileMember(
            capturedPath: member.originalPath,
            currentPath: nil,
            displayName: member.originalName,
            bookmark: nil,
            identity: nil,
            resourceType: UTType(
                filenameExtension: originalURL.pathExtension
            )?.identifier,
            availability: "unavailable",
            state: .unavailable,
            payload: nil,
            cleanupProof: nil
        )
    }

    func legacyFileReference(
        at url: URL
    ) throws -> LegacyResolvedFileReference {
        let values = try url.resourceValues(
            forKeys: [
                .contentTypeKey,
                .fileResourceIdentifierKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
        )
        guard values.isSymbolicLink != true,
            let identifier = values.fileResourceIdentifier as? NSObject
        else {
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }
        let identity = try NSKeyedArchiver.archivedData(
            withRootObject: identifier,
            requiringSecureCoding: true
        )
        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [
                .contentTypeKey,
                .fileResourceIdentifierKey,
                .nameKey,
            ],
            relativeTo: nil
        )
        return LegacyResolvedFileReference(
            url: url,
            bookmark: bookmark,
            identity: identity,
            resourceType: values.contentType?.identifier
                ?? UTType(
                    filenameExtension: url.pathExtension
                )?.identifier,
            isRegularFile: values.isRegularFile == true
        )
    }

    func streamedFileProof(_ url: URL) throws -> StreamedFileProof {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount = 0
        while let chunk = try handle.read(upToCount: 64 * 1_024),
            !chunk.isEmpty
        {
            legacyDigestReadCount += 1
            legacyMaximumDigestReadSize = max(
                legacyMaximumDigestReadSize,
                chunk.count
            )
            byteCount += chunk.count
            hasher.update(data: chunk)
        }
        return StreamedFileProof(
            byteCount: byteCount,
            sha256: Data(hasher.finalize())
        )
    }

    private func insertLegacyRedundancyProof(
        _ proof: LegacyCleanupProof,
        currentPath: String?,
        into database: Database
    ) throws {
        guard let currentPath else {
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }
        try database.execute(
            sql: """
                INSERT INTO clipboard_legacy_cleanup(
                    relative_path, proof_kind, current_path,
                    plaintext_byte_count, sha256, is_cleaned
                ) VALUES (?, 'equalCurrent', ?, ?, ?, 0)
                ON CONFLICT(relative_path) DO NOTHING
                """,
            arguments: [
                proof.relativePath,
                currentPath,
                proof.plaintextByteCount,
                proof.sha256,
            ]
        )
    }

    private func prepareLegacyRepresentations(
        _ entry: ClipboardHistoryLegacyEntry,
        payloadDirectory: URL,
        payloadStore: ClipboardHistoryPayloadStore,
        into database: Database,
        ownedPayloadCount: inout Int,
        redundantPayloadCount: inout Int
    ) throws -> PreparedLegacyEntry {
        let plainTextType = "public.utf8-plain-text"
        var representations: [PreparedLegacyRepresentation] = []
        var snapshotRepresentations: [PasteboardSnapshot.Representation] = []
        let facets: Set<ClipboardHistoryFacet>
        var thumbnail: ClipboardHistoryPublishedPayload?

        switch entry.kind {
        case .text:
            guard let text = entry.text, !text.isEmpty else {
                throw ClipboardHistoryModuleError.legacyMigrationFailed
            }
            representations.append(.text(plainTextType, text, "exactText"))
            snapshotRepresentations.append(
                .text(typeIdentifier: plainTextType, value: text)
            )
            if let richData = entry.richData, let richType = entry.richType {
                representations.append(.data(richType, richData))
                snapshotRepresentations.append(
                    .data(typeIdentifier: richType, value: richData)
                )
            }
            facets = Set([ClipboardHistoryFacet.text]).union(
                Self.inferredFacets(forExactText: text)
            )
        case .color:
            guard let color = entry.colorHex, !color.isEmpty else {
                throw ClipboardHistoryModuleError.legacyMigrationFailed
            }
            representations.append(
                .text(plainTextType, color, "normalizedColor")
            )
            snapshotRepresentations.append(
                .text(typeIdentifier: plainTextType, value: color)
            )
            facets = [.text, .color]
        case .qrCode:
            guard let text = entry.text, !text.isEmpty else {
                throw ClipboardHistoryModuleError.legacyMigrationFailed
            }
            representations.append(.text(plainTextType, text, "qr"))
            snapshotRepresentations.append(
                .text(typeIdentifier: plainTextType, value: text)
            )
            facets = [.text, .qrCode]
        case .ocr:
            guard let text = entry.text, !text.isEmpty else {
                throw ClipboardHistoryModuleError.legacyMigrationFailed
            }
            representations.append(.text(plainTextType, text, "exactText"))
            snapshotRepresentations.append(
                .text(typeIdentifier: plainTextType, value: text)
            )
            facets = [.text]
        case .image, .screenshot:
            guard let fileName = entry.fileName else {
                throw ClipboardHistoryModuleError.legacyMigrationFailed
            }
            let payloadURL = try safeLegacyPayloadURL(
                named: fileName,
                in: payloadDirectory
            )
            let data = try Data(contentsOf: payloadURL)
            guard CGImageSourceCreateWithData(data as CFData, nil) != nil else {
                throw ClipboardHistoryModuleError.legacyMigrationFailed
            }
            let canonical = try Self.canonicalBitmap(from: data)
            let bitmap = try payloadStore.publish(data, kind: .bitmap)
            thumbnail = try payloadStore.publish(
                canonical.thumbnail,
                kind: .thumbnail
            )
            representations.append(
                .bitmap(
                    bitmap,
                    LegacyCleanupProof(
                        relativePath: fileName,
                        plaintextByteCount: data.count,
                        sha256: Data(SHA256.hash(data: data))
                    )
                )
            )
            snapshotRepresentations.append(
                .bitmap(
                    png: data,
                    thumbnail: canonical.thumbnail,
                    isScreenshot: entry.kind == .screenshot
                )
            )
            facets =
                entry.kind == .screenshot
                ? [.image, .screenshot]
                : [.image]
            ownedPayloadCount += 1
        case .file:
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }
        return PreparedLegacyEntry(
            representations: representations,
            facets: facets,
            thumbnail: thumbnail,
            canonicalSnapshot: PasteboardSnapshot(
                items: [
                    PasteboardSnapshot.Item(
                        representations: snapshotRepresentations
                    )
                ],
                extraFacets: facets,
                allowsTextInference: false
            )
        )
    }

    func safeLegacyPayloadURL(
        named name: String,
        in directory: URL
    ) throws -> URL {
        try validateLegacyPayloadName(name)
        let url = directory.appendingPathComponent(name)
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
            values.isSymbolicLink != true
        else {
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }
        return url
    }

    func validateLegacyPayloadName(_ name: String) throws {
        guard !name.isEmpty,
            name == URL(fileURLWithPath: name).lastPathComponent
        else {
            throw ClipboardHistoryModuleError.legacyMigrationFailed
        }
    }

    private func insertLegacyCleanupProof(
        _ proof: LegacyCleanupProof,
        payload: ClipboardHistoryPublishedPayload,
        into database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO clipboard_legacy_cleanup(
                    relative_path, proof_kind, payload_id,
                    plaintext_byte_count, sha256, is_cleaned
                ) VALUES (?, 'encryptedPayload', ?, ?, ?, 0)
                ON CONFLICT(relative_path) DO NOTHING
                """,
            arguments: [
                proof.relativePath,
                payload.id.uuidString.lowercased(),
                proof.plaintextByteCount,
                proof.sha256,
            ]
        )
    }

    private func verifyLegacyStagingStore(
        _ request: ClipboardHistoryLegacyMigrationRequest,
        expectedReport: ClipboardHistoryLegacyMigrationReport,
        expectedEntryIDs: Set<String>,
        database: DatabasePool,
        root: URL,
        payloadKey: Data
    ) throws {
        try Self.validateIntegrity(of: database)
        let payloadStore = ClipboardHistoryPayloadStore(
            root: root,
            key: payloadKey,
            faultInjector: faultInjector
        )
        try database.write { database in
            let storedReport = try Self.legacyMigrationReport(in: database)
            guard storedReport == expectedReport else {
                throw ClipboardHistoryModuleError.legacyMigrationFailed
            }
            let storedIDs = Set(
                try String.fetchAll(
                    database,
                    sql: "SELECT id FROM clipboard_entries"
                )
            )
            let searchOK = try Self.searchIndexesPassIntegrityCheck(
                in: database
            )
            guard storedIDs == expectedEntryIDs,
                storedIDs.count == expectedReport.retainedEntryCount,
                searchOK
            else {
                throw ClipboardHistoryModuleError.legacyMigrationFailed
            }
            let payloads = try Row.fetchAll(
                database,
                sql: """
                    SELECT relative_path, kind
                    FROM clipboard_payloads
                    ORDER BY id
                    """
            )
            for row in payloads {
                guard
                    let kind = ClipboardHistoryPayloadKind(
                        databaseValue: row["kind"]
                    )
                else {
                    throw ClipboardHistoryModuleError.legacyMigrationFailed
                }
                _ = try payloadStore.materialize(
                    relativePath: row["relative_path"],
                    expectedKind: kind
                )
            }
            let cleanupProofs = try Row.fetchAll(
                database,
                sql: """
                    SELECT
                        cleanup.relative_path AS legacy_relative_path,
                        cleanup.proof_kind,
                        cleanup.current_path,
                        cleanup.plaintext_byte_count,
                        cleanup.sha256,
                        payload.relative_path AS payload_relative_path,
                        payload.kind AS payload_kind
                    FROM clipboard_legacy_cleanup cleanup
                    LEFT JOIN clipboard_payloads payload
                        ON payload.id = cleanup.payload_id
                    WHERE cleanup.is_cleaned = 0
                    ORDER BY cleanup.relative_path
                    """
            )
            for row in cleanupProofs {
                let legacyURL = try safeLegacyPayloadURL(
                    named: row["legacy_relative_path"],
                    in: request.payloadDirectory
                )
                let expectedProof = StreamedFileProof(
                    byteCount: row["plaintext_byte_count"],
                    sha256: row["sha256"]
                )
                guard try streamedFileProof(legacyURL) == expectedProof else {
                    throw ClipboardHistoryModuleError.legacyMigrationFailed
                }
                let proofKind: String = row["proof_kind"]
                switch proofKind {
                case "equalCurrent":
                    guard
                        let currentPath: String = row["current_path"],
                        try streamedFileProof(
                            URL(fileURLWithPath: currentPath)
                        ) == expectedProof
                    else {
                        throw ClipboardHistoryModuleError
                            .legacyMigrationFailed
                    }
                case "encryptedPayload":
                    guard
                        let relativePath: String =
                            row["payload_relative_path"],
                        let kind = ClipboardHistoryPayloadKind(
                            databaseValue: row["payload_kind"]
                        )
                    else {
                        throw ClipboardHistoryModuleError
                            .legacyMigrationFailed
                    }
                    let data = try payloadStore.materialize(
                        relativePath: relativePath,
                        expectedKind: kind
                    )
                    guard
                        data.count == expectedProof.byteCount,
                        Data(SHA256.hash(data: data))
                            == expectedProof.sha256
                    else {
                        throw ClipboardHistoryModuleError
                            .legacyMigrationFailed
                    }
                    try database.execute(
                        sql: """
                            UPDATE clipboard_legacy_cleanup
                            SET proof_kind = 'publishedEncrypted'
                            WHERE relative_path = ?
                            """,
                        arguments: [
                            row["legacy_relative_path"] as String
                        ]
                    )
                default:
                    throw ClipboardHistoryModuleError.legacyMigrationFailed
                }
            }
        }
    }

    public func legacyMigrationPublicationState() throws
        -> ClipboardHistoryLegacyMigrationPublicationState
    {
        if let report = try currentLegacyMigrationReport() {
            return .published(report)
        }
        return .notPublished
    }

    func currentLegacyMigrationReport() throws
        -> ClipboardHistoryLegacyMigrationReport?
    {
        guard let database else { return nil }
        return try database.read {
            try Self.legacyMigrationReport(in: $0)
        }
    }

    private static func legacyMigrationReport(
        in database: Database
    ) throws -> ClipboardHistoryLegacyMigrationReport? {
        guard
            try Int.fetchOne(
                database,
                sql: """
                    SELECT integer_value
                    FROM clipboard_maintenance_metadata
                    WHERE key = 'legacyMigrationVersion'
                    """
            ) == ClipboardHistoryLegacyTransfer.currentVersion
        else {
            return nil
        }
        func value(_ key: String) throws -> Int {
            try Int.fetchOne(
                database,
                sql: """
                    SELECT integer_value
                    FROM clipboard_maintenance_metadata
                    WHERE key = ?
                    """,
                arguments: [key]
            ) ?? 0
        }
        return try ClipboardHistoryLegacyMigrationReport(
            retainedEntryCount: value("legacyRetainedEntryCount"),
            omittedExpiredEntryCount: value("legacyOmittedExpiredEntryCount"),
            ownedPayloadCount: value("legacyOwnedPayloadCount"),
            redundantLegacyPayloadCount: value(
                "legacyRedundantPayloadCount"
            )
        )
    }

    private func setLegacyMigrationReport(
        _ report: ClipboardHistoryLegacyMigrationReport,
        in database: Database
    ) throws {
        for (key, value) in [
            (
                "legacyMigrationVersion",
                ClipboardHistoryLegacyTransfer.currentVersion
            ),
            ("legacyRetainedEntryCount", report.retainedEntryCount),
            (
                "legacyOmittedExpiredEntryCount",
                report.omittedExpiredEntryCount
            ),
            ("legacyOwnedPayloadCount", report.ownedPayloadCount),
            (
                "legacyRedundantPayloadCount",
                report.redundantLegacyPayloadCount
            ),
        ] {
            try database.execute(
                sql: """
                    INSERT INTO clipboard_maintenance_metadata(
                        key, integer_value
                    ) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        integer_value = excluded.integer_value,
                        real_value = NULL,
                        text_value = NULL,
                        data_value = NULL
                    """,
                arguments: [key, value]
            )
        }
    }
}

private enum PreparedLegacyRepresentation {
    case text(String, String, String)
    case data(String, Data)
    case bitmap(
        ClipboardHistoryPublishedPayload,
        LegacyCleanupProof
    )
}

private struct LegacyCleanupProof {
    let relativePath: String
    let plaintextByteCount: Int
    let sha256: Data
}

private struct PreparedLegacyFileMember {
    let capturedPath: String
    let currentPath: String?
    let displayName: String
    let bookmark: Data?
    let identity: Data?
    let resourceType: String?
    let availability: String
    let state: ClipboardHistoryModule.LegacyFileState
    let payload: ClipboardHistoryPublishedPayload?
    let cleanupProof: LegacyCleanupProof?
}

struct LegacyResolvedFileReference: Sendable {
    let url: URL
    let bookmark: Data
    let identity: Data
    let resourceType: String?
    let isRegularFile: Bool
}

struct StreamedFileProof: Equatable, Sendable {
    let byteCount: Int
    let sha256: Data
}

private struct PreparedLegacyEntry {
    let representations: [PreparedLegacyRepresentation]
    let facets: Set<ClipboardHistoryFacet>
    let thumbnail: ClipboardHistoryPublishedPayload?
    let canonicalSnapshot: ClipboardHistoryModule.PasteboardSnapshot
}

private struct LegacyStagingBuildResult {
    let report: ClipboardHistoryLegacyMigrationReport
    let entryIDs: Set<String>
}
