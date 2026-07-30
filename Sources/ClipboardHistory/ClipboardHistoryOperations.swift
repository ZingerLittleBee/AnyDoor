import Foundation
import GRDB

extension ClipboardHistoryModule {
    public func capture(
        _ request: ClipboardHistoryCaptureRequest
    ) throws -> ClipboardHistoryCaptureOutcome {
        try captureExplicit(request)
    }

    public func page(
        _ query: ClipboardHistoryQuery,
        after cursor: ClipboardHistoryCursor? = nil
    ) throws -> ClipboardHistoryPage {
        _ = cursor
        guard query.text.isEmpty else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let database = try requiredDatabase()
        return try database.read { database in
            var conditions: [String] = []
            var arguments: StatementArguments = []
            if query.favoritesOnly {
                conditions.append("is_favorite = 1")
            }
            if let sourceID = query.sourceID {
                conditions.append("source_bundle_id = ?")
                arguments += [sourceID]
            }
            if let tagID = query.tagID {
                conditions.append(
                    """
                    EXISTS (
                        SELECT 1 FROM clipboard_entry_tags
                        WHERE entry_id = clipboard_entries.id AND tag_id = ?
                    )
                    """
                )
                arguments += [tagID]
            }
            if let facet = query.facet {
                conditions.append(
                    """
                    EXISTS (
                        SELECT 1 FROM clipboard_entry_facets
                        WHERE entry_id = clipboard_entries.id AND facet = ?
                    )
                    """
                )
                arguments += [facet.rawValue]
            }
            let predicate =
                conditions.isEmpty
                ? ""
                : "WHERE \(conditions.joined(separator: " AND "))"
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, captured_at, preview_text, is_favorite
                    FROM clipboard_entries
                    \(predicate)
                    ORDER BY last_captured_at DESC, id DESC
                    LIMIT 100
                    """,
                arguments: arguments
            )
            let entries = try rows.map { row -> ClipboardHistoryEntry in
                let identifier = try Self.entryID(from: row)
                let facets = try String.fetchAll(
                    database,
                    sql: """
                        SELECT facet
                        FROM clipboard_entry_facets
                        WHERE entry_id = ?
                        """,
                    arguments: [identifier.value.uuidString.lowercased()]
                )
                return ClipboardHistoryEntry(
                    id: identifier,
                    capturedAt: Date(
                        timeIntervalSince1970: row["captured_at"]
                    ),
                    previewText: row["preview_text"],
                    facets: Set(facets.compactMap(ClipboardHistoryFacet.init)),
                    isFavorite: row["is_favorite"]
                )
            }
            return ClipboardHistoryPage(entries: entries, nextCursor: nil)
        }
    }

    public func apply(
        _ mutation: ClipboardHistoryMutation
    ) async throws -> ClipboardHistoryMutationOutcome {
        let database = try requiredDatabase()
        switch mutation {
        case .delete(let entryID):
            return try await delete(entryID, from: database)
        case .setFavorite, .setTags, .editText:
            throw ClipboardHistoryModuleError.operationUnavailable
        }
    }

    public func materialize(
        _ request: ClipboardHistoryMaterializationRequest
    ) throws -> ClipboardHistoryMaterialization {
        let database = try requiredDatabase()
        let id = request.entryID.value.uuidString.lowercased()
        if request.purpose == .preview,
            let row = try database.read({ database in
                try Row.fetchOne(
                    database,
                    sql: """
                        SELECT payload.relative_path
                        FROM clipboard_entries AS entry
                        JOIN clipboard_payloads AS payload
                          ON payload.id = entry.thumbnail_payload_id
                        WHERE entry.id = ?
                        """,
                    arguments: [id]
                )
            })
        {
            let data = try materializePayload(
                path: row["relative_path"],
                kind: .thumbnail,
                entryID: request.entryID
            )
            return ClipboardHistoryMaterialization(
                items: [
                    ClipboardHistoryMaterializedItem(
                        representations: [
                            .data(typeIdentifier: "public.png", data)
                        ]
                    )
                ]
            )
        }

        let rows = try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT representation.item_index,
                           representation.representation_index,
                           representation.kind,
                           representation.type_identifier,
                           representation.text_value,
                           representation.data_value,
                           payload.relative_path AS payload_path,
                           payload.kind AS payload_kind
                    FROM clipboard_representations AS representation
                    LEFT JOIN clipboard_payloads AS payload
                      ON payload.id = representation.payload_id
                    WHERE representation.entry_id = ?
                    ORDER BY representation.item_index,
                             representation.representation_index
                    """,
                arguments: [id]
            )
        }
        guard !rows.isEmpty else {
            throw ClipboardHistoryModuleError.entryNotFound
        }
        if request.purpose == .plainTextPaste {
            let groupedRows = Dictionary(
                grouping: rows,
                by: { $0["item_index"] as Int }
            )
            var items: [ClipboardHistoryMaterializedItem] = []
            for itemIndex in groupedRows.keys.sorted() {
                guard let exactTextRow = groupedRows[itemIndex]?.first(where: {
                    ($0["type_identifier"] as String)
                        == "public.utf8-plain-text"
                        && ($0["text_value"] as String?) != nil
                }), let value: String = exactTextRow["text_value"]
                else {
                    throw ClipboardHistoryModuleError.operationUnavailable
                }
                items.append(
                    ClipboardHistoryMaterializedItem(
                        representations: [
                            .text(
                                typeIdentifier: "public.utf8-plain-text",
                                value: value
                            )
                        ]
                    )
                )
            }
            return ClipboardHistoryMaterialization(items: items)
        }
        let fileReferences = try materializeFileReferences(
            for: request.entryID,
            from: database
        )

        var materializedItems: [ClipboardHistoryMaterializedItem] = []
        let groupedRows = Dictionary(
            grouping: rows,
            by: { $0["item_index"] as Int }
        )
        for itemIndex in groupedRows.keys.sorted() {
            guard let itemRows = groupedRows[itemIndex] else { continue }
            let representations = try itemRows.map { row in
                if (row["kind"] as String) == "fileReference" {
                    guard let reference = fileReferences[itemIndex] else {
                        throw ClipboardHistoryModuleError.fileReferencesUnavailable(
                            request.entryID,
                            count: 1
                        )
                    }
                    return ClipboardHistoryMaterializedRepresentation.file(
                        reference
                    )
                }
                if let text: String = row["text_value"] {
                    return ClipboardHistoryMaterializedRepresentation.text(
                        typeIdentifier: row["type_identifier"],
                        value: text
                    )
                }
                if let data: Data = row["data_value"] {
                    return .data(
                        typeIdentifier: row["type_identifier"],
                        data
                    )
                }
                guard let path: String = row["payload_path"],
                    let kindValue: String = row["payload_kind"],
                    let kind = ClipboardHistoryPayloadKind(
                        databaseValue: kindValue
                    )
                else {
                    throw ClipboardHistoryModuleError.payloadUnavailable(
                        request.entryID
                    )
                }
                let data = try materializePayload(
                    path: path,
                    kind: kind,
                    entryID: request.entryID
                )
                return .data(typeIdentifier: row["type_identifier"], data)
            }
            materializedItems.append(
                ClipboardHistoryMaterializedItem(
                    representations: representations
                )
            )
        }
        return ClipboardHistoryMaterialization(items: materializedItems)
    }

    private func materializeFileReferences(
        for entryID: ClipboardHistoryEntryID,
        from database: DatabasePool
    ) throws -> [Int: ClipboardHistoryMaterializedFileReference] {
        let storedID = entryID.value.uuidString.lowercased()
        let rows = try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT item_index, captured_path, display_name,
                           bookmark_data, identity_data
                    FROM clipboard_file_members
                    WHERE entry_id = ?
                    ORDER BY item_index, member_index
                    """,
                arguments: [storedID]
            )
        }
        guard !rows.isEmpty else { return [:] }

        struct ResolvedFile {
            let itemIndex: Int
            let capturedPath: String
            let displayName: String
            let url: URL
            let bookmark: Data
        }
        var resolved: [ResolvedFile] = []
        var unavailableCount = 0
        for row in rows {
            guard let bookmark: Data = row["bookmark_data"],
                let identityData: Data = row["identity_data"]
            else {
                unavailableCount += 1
                continue
            }
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withoutUI, .withoutMounting],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                let resourceValues = try url.resourceValues(
                    forKeys: [.fileResourceIdentifierKey, .nameKey]
                )
                guard let currentIdentity =
                    resourceValues.fileResourceIdentifier as? NSObject,
                    let capturedIdentity = try NSKeyedUnarchiver
                        .unarchivedObject(
                            ofClasses: [
                                NSObject.self,
                                NSData.self,
                                NSString.self,
                                NSNumber.self,
                            ],
                            from: identityData
                        ) as? NSObject,
                    capturedIdentity.isEqual(currentIdentity)
                else {
                    unavailableCount += 1
                    continue
                }
                let refreshedBookmark: Data
                if isStale {
                    refreshedBookmark = try url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: [
                            .contentTypeKey,
                            .fileResourceIdentifierKey,
                            .nameKey,
                        ],
                        relativeTo: nil
                    )
                } else {
                    refreshedBookmark = bookmark
                }
                resolved.append(
                    ResolvedFile(
                        itemIndex: row["item_index"],
                        capturedPath: row["captured_path"],
                        displayName: resourceValues.name
                            ?? (row["display_name"] as String),
                        url: url,
                        bookmark: refreshedBookmark
                    )
                )
            } catch {
                unavailableCount += 1
            }
        }
        guard unavailableCount == 0 else {
            throw ClipboardHistoryModuleError.fileReferencesUnavailable(
                entryID,
                count: unavailableCount
            )
        }

        try database.write { database in
            for file in resolved {
                try database.execute(
                    sql: """
                        UPDATE clipboard_file_members
                        SET current_path = ?, display_name = ?,
                            bookmark_data = ?, availability = 'available'
                        WHERE entry_id = ? AND item_index = ?
                    """,
                    arguments: [
                        file.url.path,
                        file.displayName,
                        file.bookmark,
                        storedID,
                        file.itemIndex,
                    ]
                )
                for (kind, value) in [
                    ("fileName", file.displayName),
                    ("currentPath", file.url.path),
                ] {
                    try database.execute(
                        sql: """
                            UPDATE clipboard_search_fields
                            SET value = ?, normalized_value = ?
                            WHERE entry_id = ? AND field_kind = ?
                              AND field_index = ?
                            """,
                        arguments: [
                            value,
                            value.folding(
                                options: [
                                    .caseInsensitive,
                                    .diacriticInsensitive,
                                    .widthInsensitive,
                                ],
                                locale: Locale(identifier: "en_US_POSIX")
                            ),
                            storedID,
                            kind,
                            file.itemIndex,
                        ]
                    )
                }
            }
        }
        return Dictionary(
            uniqueKeysWithValues: resolved.map { file in
                (
                    file.itemIndex,
                    ClipboardHistoryMaterializedFileReference(
                        capturedPath: file.capturedPath,
                        displayName: file.displayName,
                        currentURL: file.url
                    )
                )
            }
        )
    }

    public func performMaintenance(
        orphanGracePeriod: TimeInterval = 3_600
    ) throws -> ClipboardHistoryMaintenanceReport {
        let database = try requiredDatabase()
        let referencedPaths = try database.write { database in
            let paths = Set(
                try String.fetchAll(
                    database,
                    sql: """
                        SELECT DISTINCT payload.relative_path
                        FROM clipboard_payloads AS payload
                        WHERE EXISTS (
                            SELECT 1
                            FROM clipboard_representations AS representation
                            WHERE representation.payload_id = payload.id
                        )
                        OR EXISTS (
                            SELECT 1
                            FROM clipboard_entries AS entry
                            WHERE entry.thumbnail_payload_id = payload.id
                        )
                        OR EXISTS (
                            SELECT 1
                            FROM clipboard_file_members AS member
                            WHERE member.payload_id = payload.id
                        )
                        """
                )
            )
            try database.execute(
                sql: """
                    DELETE FROM clipboard_payloads
                    WHERE NOT EXISTS (
                        SELECT 1 FROM clipboard_representations
                        WHERE clipboard_representations.payload_id =
                              clipboard_payloads.id
                    )
                    AND NOT EXISTS (
                        SELECT 1 FROM clipboard_entries
                        WHERE clipboard_entries.thumbnail_payload_id =
                              clipboard_payloads.id
                    )
                    AND NOT EXISTS (
                        SELECT 1 FROM clipboard_file_members
                        WHERE clipboard_file_members.payload_id =
                              clipboard_payloads.id
                    )
                    """
            )
            return paths
        }
        let reclaimed: Int
        do {
            reclaimed = try requiredPayloadStore().reconcile(
                referencedPaths: referencedPaths,
                olderThan: now().addingTimeInterval(-orphanGracePeriod)
            )
        } catch {
            throw ClipboardHistoryModuleError.storageFailure
        }
        try database.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA incremental_vacuum")
            try database.execute(
                sql: """
                    INSERT INTO clipboard_maintenance_metadata(key, real_value)
                    VALUES ('lastMaintenanceAt', ?)
                    ON CONFLICT(key) DO UPDATE SET real_value = excluded.real_value
                    """,
                arguments: [now().timeIntervalSince1970]
            )
            try database.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        return ClipboardHistoryMaintenanceReport(
            reclaimedPayloadCount: reclaimed,
            storageBytes: try storageUsage()
        )
    }

    public func storageUsage() throws -> UInt64 {
        guard FileManager.default.fileExists(atPath: storeRoot.path) else {
            return 0
        }
        return try allocatedSize(of: storeRoot)
    }

    func awaitPendingReclamation() async
        -> ClipboardHistoryReclamationReport
    {
        await payloadReclaimer.drain()
    }

    public func reset(
        confirmation: ClipboardHistoryResetConfirmation
    ) throws {
        switch confirmation {
        case .confirmed:
            break
        }
        guard let keyStore else {
            throw ClipboardHistoryModuleError.resetFailed
        }
        monitoringEnabled = false
        try database?.close()
        database = nil
        derivedKeys = nil
        do {
            if FileManager.default.fileExists(atPath: storeRoot.path) {
                try FileManager.default.removeItem(at: storeRoot)
            }
        } catch {
            availability = .unavailable
            availabilityReason = .storeIOFailure
            throw ClipboardHistoryModuleError.resetFailed
        }

        guard keyStore.delete() == .missing else {
            availability = .unavailable
            availabilityReason = .keychainFailure
            throw ClipboardHistoryModuleError.resetFailed
        }
        let resolution = Self.resolveStore(at: storeRoot, keyStore: keyStore)
        database = resolution.database
        derivedKeys = resolution.keys
        availability = resolution.availability
        availabilityReason = resolution.reason
        guard availability == .ready else {
            throw ClipboardHistoryModuleError.resetFailed
        }
    }
}

extension ClipboardHistoryModule {
    func requiredPayloadStore() throws -> ClipboardHistoryPayloadStore {
        guard let payloadKey = derivedKeys?.payloadKey else {
            throw ClipboardHistoryModuleError.storeUnavailable
        }
        return ClipboardHistoryPayloadStore(
            root: storeRoot,
            key: payloadKey,
            faultInjector: faultInjector
        )
    }

    func insertPayload(
        _ payload: ClipboardHistoryPublishedPayload,
        into database: Database,
        at date: Date
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO clipboard_payloads(
                    id, relative_path, kind, crypto_version,
                    plaintext_byte_count, created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                payload.id.uuidString.lowercased(),
                payload.relativePath,
                payload.kind.databaseValue,
                payload.cryptoVersion,
                payload.plaintextByteCount,
                date.timeIntervalSince1970,
            ]
        )
    }

    fileprivate func delete(
        _ entryID: ClipboardHistoryEntryID,
        from database: DatabasePool
    ) async throws -> ClipboardHistoryMutationOutcome {
        let storedID = entryID.value.uuidString.lowercased()
        let payloads: [(id: String, path: String)] = try await database.read {
            database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT DISTINCT payload.id, payload.relative_path
                    FROM clipboard_payloads AS payload
                    WHERE payload.id IN (
                        SELECT payload_id
                        FROM clipboard_representations
                        WHERE entry_id = ? AND payload_id IS NOT NULL
                        UNION
                        SELECT thumbnail_payload_id
                        FROM clipboard_entries
                        WHERE id = ? AND thumbnail_payload_id IS NOT NULL
                        UNION
                        SELECT payload_id
                        FROM clipboard_file_members
                        WHERE entry_id = ? AND payload_id IS NOT NULL
                    )
                    """,
                arguments: [storedID, storedID, storedID]
            ).map { ($0["id"], $0["relative_path"]) }
        }
        let deleted = try await database.write { database in
            try database.execute(
                sql: "DELETE FROM clipboard_entries WHERE id = ?",
                arguments: [storedID]
            )
            guard database.changesCount > 0 else { return false }
            for payload in payloads {
                try database.execute(
                    sql: "DELETE FROM clipboard_payloads WHERE id = ?",
                    arguments: [payload.id]
                )
            }
            return true
        }
        guard deleted else { return .notFound }

        if let payloadStore = try? requiredPayloadStore() {
            await payloadReclaimer.enqueue(
                paths: payloads.map(\.path),
                in: payloadStore
            )
        }
        return .deleted
    }

    fileprivate func materializePayload(
        path: String,
        kind: ClipboardHistoryPayloadKind,
        entryID: ClipboardHistoryEntryID
    ) throws -> Data {
        do {
            return try requiredPayloadStore().materialize(
                relativePath: path,
                expectedKind: kind
            )
        } catch ClipboardHistoryStorageError.payloadAuthenticationFailed,
            ClipboardHistoryStorageError.invalidPayloadEnvelope,
            ClipboardHistoryStorageError.injected(.payloadAuthentication)
        {
            throw ClipboardHistoryModuleError.payloadAuthenticationFailed(
                entryID
            )
        } catch {
            throw ClipboardHistoryModuleError.payloadUnavailable(entryID)
        }
    }

    func mapStorageError(
        _ error: Error,
        entryID: ClipboardHistoryEntryID
    ) -> ClipboardHistoryModuleError {
        switch error {
        case ClipboardHistoryStorageError.payloadAuthenticationFailed,
            ClipboardHistoryStorageError.invalidPayloadEnvelope,
            ClipboardHistoryStorageError.injected(.payloadAuthentication):
            .payloadAuthenticationFailed(entryID)
        case is ClipboardHistoryStorageError:
            .storageFailure
        default:
            .storageFailure
        }
    }

    fileprivate static func entryID(from row: Row) throws -> ClipboardHistoryEntryID {
        guard let value = UUID(uuidString: row["id"]) else {
            throw ClipboardHistoryModuleError.storeUnavailable
        }
        return ClipboardHistoryEntryID(value)
    }

    fileprivate func allocatedSize(of directory: URL) throws -> UInt64 {
        let keys: Set<URLResourceKey> = [
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        var total: UInt64 = 0
        for child in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) {
            let values = try child.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                continue
            }
            if values.isDirectory == true {
                total += try allocatedSize(of: child)
            } else if values.isRegularFile == true {
                let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
                total += UInt64(max(size, 0))
            }
        }
        return total
    }
}

extension ClipboardHistoryPayloadKind {
    fileprivate init?(databaseValue: String) {
        switch databaseValue {
        case "bitmap":
            self = .bitmap
        case "thumbnail":
            self = .thumbnail
        case "legacyOwnedFile":
            self = .legacyOwnedFile
        default:
            return nil
        }
    }
}
