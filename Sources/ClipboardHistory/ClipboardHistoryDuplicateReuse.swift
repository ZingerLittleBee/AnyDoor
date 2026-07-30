import Foundation
import GRDB

extension ClipboardHistoryModule {
    func reusableEntry(
        matching identity: CanonicalIdentity,
        source: ClipboardHistoryCaptureSource,
        capturedAt: Date,
        facets: Set<ClipboardHistoryFacet>,
        containsBitmap: Bool,
        refreshOCRBudget: Bool,
        explicitSearchKind: String?,
        database: DatabasePool,
        payloadStore: ClipboardHistoryPayloadStore
    ) throws -> ClipboardHistoryEntryID? {
        let candidates = try database.read { database in
            let expiryCutoff = try Self.expiryCutoff(
                at: capturedAt,
                in: database
            )
            var arguments: StatementArguments = [
                identity.fingerprint,
                identity.canonicalByteCount,
            ]
            let liveCondition: String
            if let expiryCutoff {
                liveCondition = """
                    AND (
                        retention.is_protected = 1
                        OR retention.retention_started_at > ?
                    )
                    """
                arguments += [expiryCutoff]
            } else {
                liveCondition = ""
            }
            return try Row.fetchAll(
                database,
                sql: """
                    SELECT candidate.entry_id
                    FROM clipboard_duplicate_candidates AS candidate
                    JOIN clipboard_entries AS entry
                      ON entry.id = candidate.entry_id
                    JOIN clipboard_retention_state AS retention
                      ON retention.entry_id = entry.id
                    WHERE candidate.fingerprint = ?
                      AND candidate.canonical_byte_count = ?
                      \(liveCondition)
                    ORDER BY entry.last_captured_at DESC, entry.id DESC
                    """,
                arguments: arguments
            ).compactMap { row -> String? in row["entry_id"] }
        }

        for storedID in candidates {
            guard
                let candidateIdentity = try canonicalIdentity(
                    for: storedID,
                    database: database,
                    payloadStore: payloadStore
                ), candidateIdentity.structure == identity.structure,
                candidateIdentity.payloadDigests == identity.payloadDigests,
                let value = UUID(uuidString: storedID)
            else {
                continue
            }

            do {
                try database.write { database in
                    try database.execute(
                        sql: """
                            UPDATE clipboard_entries
                            SET captured_at = ?, last_captured_at = ?,
                                source_bundle_id = ?, source_display_name = ?,
                                source_provenance = ?
                            WHERE id = ?
                            """,
                        arguments: [
                            capturedAt.timeIntervalSince1970,
                            capturedAt.timeIntervalSince1970,
                            source.bundleIdentifier,
                            source.displayName,
                            source.provenance.rawValue,
                            storedID,
                        ]
                    )
                    try database.execute(
                        sql: """
                            UPDATE clipboard_retention_state
                            SET retention_started_at = ?
                            WHERE entry_id = ?
                            """,
                        arguments: [
                            capturedAt.timeIntervalSince1970,
                            storedID,
                        ]
                    )
                    try database.execute(
                        sql: """
                            DELETE FROM clipboard_entry_facets
                            WHERE entry_id = ?
                            """,
                        arguments: [storedID]
                    )
                    for facet in facets {
                        try database.execute(
                            sql: """
                                INSERT INTO clipboard_entry_facets(entry_id, facet)
                                VALUES (?, ?)
                                """,
                            arguments: [storedID, facet.rawValue]
                        )
                    }
                    if containsBitmap {
                        try database.execute(
                            sql: """
                                UPDATE clipboard_derived_jobs
                                SET state = 'pending', attempt_count = 0,
                                    eligible_generation =
                                        eligible_generation + 1,
                                    next_attempt_at = NULL
                                WHERE entry_id = ?
                                  AND kind = 'qr'
                                """,
                            arguments: [storedID]
                        )
                        if refreshOCRBudget {
                            try database.execute(
                                sql: """
                                    UPDATE clipboard_derived_jobs
                                    SET state = 'pending', attempt_count = 0,
                                        eligible_generation =
                                            eligible_generation + 1,
                                        next_attempt_at = NULL
                                    WHERE entry_id = ? AND kind = 'ocr'
                                    """,
                                arguments: [storedID]
                            )
                        }
                    }
                    if let explicitSearchKind {
                        try database.execute(
                            sql: """
                                UPDATE clipboard_search_fields
                                SET field_kind = ?, ranking_group = ?
                                WHERE entry_id = ?
                                """,
                            arguments: [
                                explicitSearchKind,
                                Self.searchRankingGroup(
                                    for: explicitSearchKind
                                ),
                                storedID,
                            ]
                        )
                    }
                    try Self.bumpSearchIndexGeneration(in: database)
                    try Self.bumpHistoryRevision(in: database)
                    try faultInjector.check(.databaseTransaction)
                }
            } catch {
                throw mapStorageError(
                    error,
                    entryID: ClipboardHistoryEntryID(value)
                )
            }
            return ClipboardHistoryEntryID(value)
        }
        return nil
    }

    private func canonicalIdentity(
        for storedID: String,
        database: DatabasePool,
        payloadStore: ClipboardHistoryPayloadStore
    ) throws -> CanonicalIdentity? {
        struct StoredRepresentation {
            let itemIndex: Int
            let kind: String
            let typeIdentifier: String
            let text: String?
            let data: Data?
            let payloadPath: String?
            let payloadKind: String?
        }

        let stored = try database.read {
            database -> (
                itemIndexes: [Int],
                representations: [StoredRepresentation],
                thumbnailPath: String?
            ) in
            let itemIndexes = try Int.fetchAll(
                database,
                sql: """
                    SELECT item_index
                    FROM clipboard_items
                    WHERE entry_id = ?
                    ORDER BY item_index
                    """,
                arguments: [storedID]
            )
            let representations = try Row.fetchAll(
                database,
                sql: """
                    SELECT representation.item_index, representation.kind,
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
                arguments: [storedID]
            ).map { row in
                StoredRepresentation(
                    itemIndex: row["item_index"],
                    kind: row["kind"],
                    typeIdentifier: row["type_identifier"],
                    text: row["text_value"],
                    data: row["data_value"],
                    payloadPath: row["payload_path"],
                    payloadKind: row["payload_kind"]
                )
            }
            let thumbnailPath = try String.fetchOne(
                database,
                sql: """
                    SELECT payload.relative_path
                    FROM clipboard_entries AS entry
                    JOIN clipboard_payloads AS payload
                      ON payload.id = entry.thumbnail_payload_id
                    WHERE entry.id = ?
                    """,
                arguments: [storedID]
            )
            return (
                itemIndexes,
                representations,
                thumbnailPath
            )
        }
        guard !stored.itemIndexes.isEmpty,
            stored.itemIndexes == Array(stored.itemIndexes.indices)
        else {
            return nil
        }

        if let thumbnailPath = stored.thumbnailPath {
            guard
                (try? payloadStore.materialize(
                    relativePath: thumbnailPath,
                    expectedKind: .thumbnail
                )) != nil
            else {
                return nil
            }
        }

        let grouped = Dictionary(
            grouping: stored.representations,
            by: \.itemIndex
        )
        var items: [PasteboardSnapshot.Item] = []
        for itemIndex in stored.itemIndexes {
            guard let storedRepresentations = grouped[itemIndex],
                !storedRepresentations.isEmpty
            else {
                return nil
            }
            var representations: [PasteboardSnapshot.Representation] = []
            for representation in storedRepresentations {
                switch representation.kind {
                case "text":
                    guard let value = representation.text else { return nil }
                    representations.append(
                        .text(
                            typeIdentifier: representation.typeIdentifier,
                            value: value
                        )
                    )
                case "richText":
                    guard let value = representation.data else { return nil }
                    representations.append(
                        .data(
                            typeIdentifier: representation.typeIdentifier,
                            value: value
                        )
                    )
                case "bitmap":
                    guard let path = representation.payloadPath,
                        representation.payloadKind == "bitmap",
                        let png = try? payloadStore.materialize(
                            relativePath: path,
                            expectedKind: .bitmap
                        )
                    else {
                        return nil
                    }
                    representations.append(
                        .bitmap(
                            png: png,
                            thumbnail: Data(),
                            isScreenshot: false
                        )
                    )
                case "fileReference":
                    guard
                        let reference = try storedFileReference(
                            entryID: storedID,
                            itemIndex: itemIndex,
                            database: database
                        )
                    else {
                        return nil
                    }
                    representations.append(.file(reference))
                case "color":
                    guard let value = representation.data,
                        let normalized = Self.normalizedColor(from: value)
                    else {
                        return nil
                    }
                    representations.append(
                        .color(
                            data: value,
                            normalizedValue: normalized
                        )
                    )
                default:
                    return nil
                }
            }
            items.append(
                PasteboardSnapshot.Item(representations: representations)
            )
        }
        return try CanonicalIdentity(
            snapshot: PasteboardSnapshot(
                items: items,
                extraFacets: [],
                allowsTextInference: false
            ),
            fingerprintDigest: fingerprintDigest
        )
    }

    private func storedFileReference(
        entryID: String,
        itemIndex: Int,
        database: DatabasePool
    ) throws -> PasteboardSnapshot.FileReference? {
        try database.read { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT captured_path, display_name, bookmark_data,
                               identity_data, resource_type
                        FROM clipboard_file_members
                        WHERE entry_id = ? AND item_index = ?
                        ORDER BY member_index
                        LIMIT 1
                        """,
                    arguments: [entryID, itemIndex]
                ), let bookmark: Data = row["bookmark_data"],
                let identity: Data = row["identity_data"]
            else {
                return nil
            }
            return PasteboardSnapshot.FileReference(
                capturedPath: row["captured_path"],
                displayName: row["display_name"],
                bookmark: bookmark,
                identity: identity,
                resourceType: row["resource_type"]
            )
        }
    }
}
