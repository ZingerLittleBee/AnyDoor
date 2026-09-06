import Foundation
import GRDB

extension ClipboardHistoryModule {
    public func retentionStatus() throws -> ClipboardHistoryRetentionStatus {
        let database = try requiredDatabase()
        return try database.read { database in
            ClipboardHistoryRetentionStatus(
                period: try Self.retentionPeriod(in: database)
            )
        }
    }

    static func retentionPeriod(
        in database: Database
    ) throws -> ClipboardHistoryRetentionPeriod {
        let rawValue = try String.fetchOne(
            database,
            sql: """
                SELECT text_value
                FROM clipboard_maintenance_metadata
                WHERE key = 'retentionPeriod'
                """
        )
        guard let rawValue,
            let period = ClipboardHistoryRetentionPeriod(rawValue: rawValue)
        else {
            throw ClipboardHistoryModuleError.storeUnavailable
        }
        return period
    }

    public func count(
        _ query: ClipboardHistoryQuery
    ) throws -> Int {
        try indexedCount(query)
    }

    public func createTagDefinition(
        named name: String,
        assigningTo entryID: ClipboardHistoryEntryID
    ) throws -> ClipboardHistoryTagAssignment {
        let displayName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !displayName.isEmpty else {
            throw ClipboardHistoryModuleError.invalidTagName
        }
        let database = try requiredDatabase()
        let storedEntryID = entryID.value.uuidString.lowercased()
        let timestamp = now()
        let result: TagAssignmentMutationResult = try mapMutationStorageFailure {
            try database.write { database in
                guard try isLiveEntry(
                    storedEntryID,
                    at: timestamp,
                    in: database
                ) else {
                    throw ClipboardHistoryModuleError.entryNotFound
                }
                let existing = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, display_name
                        FROM clipboard_tag_definitions
                        WHERE display_name = ?
                        ORDER BY display_order, id
                        LIMIT 1
                        """,
                    arguments: [displayName]
                )
                let definition: ClipboardHistoryTagDefinition
                let insertedDefinition: Bool
                if let existing {
                    definition = ClipboardHistoryTagDefinition(
                        id: existing["id"],
                        displayName: existing["display_name"]
                    )
                    insertedDefinition = false
                } else {
                    let id = UUID().uuidString.lowercased()
                    let displayOrder =
                        (try Int.fetchOne(
                            database,
                            sql: """
                                SELECT MAX(display_order)
                                FROM clipboard_tag_definitions
                                """
                        ) ?? -1) + 1
                    try database.execute(
                        sql: """
                            INSERT INTO clipboard_tag_definitions(
                                id, display_name, display_order
                            ) VALUES (?, ?, ?)
                            """,
                        arguments: [id, displayName, displayOrder]
                    )
                    definition = ClipboardHistoryTagDefinition(
                        id: id,
                        displayName: displayName
                    )
                    insertedDefinition = true
                }
                let hadMembership =
                    (try Bool.fetchOne(
                        database,
                        sql: """
                            SELECT EXISTS(
                                SELECT 1
                                FROM clipboard_entry_tags
                                WHERE entry_id = ? AND tag_id = ?
                            )
                            """,
                        arguments: [storedEntryID, definition.id]
                    )) ?? false
                if !hadMembership {
                    try database.execute(
                        sql: """
                            INSERT INTO clipboard_entry_tags(entry_id, tag_id)
                            VALUES (?, ?)
                            """,
                        arguments: [storedEntryID, definition.id]
                    )
                    _ = try recomputeProtection(
                        for: storedEntryID,
                        in: database
                    )
                }
                if insertedDefinition || !hadMembership {
                    try Self.bumpHistoryRevision(in: database)
                    try Self.bumpSearchIndexGeneration(in: database)
                }
                return TagAssignmentMutationResult(
                    assignment: ClipboardHistoryTagAssignment(
                        definition: definition,
                        entry: try Self.entry(
                            from: try requiredEntryRow(
                                storedEntryID,
                                in: database
                            ),
                            in: database
                        )
                    ),
                    didMutate: insertedDefinition || !hadMembership
                )
            }
        }
        if result.didMutate {
            publishMutation()
        }
        return result.assignment
    }

    public func renameTagDefinition(
        id: String,
        to name: String
    ) throws -> ClipboardHistoryTagDefinition {
        let displayName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !displayName.isEmpty else {
            throw ClipboardHistoryModuleError.invalidTagName
        }
        let database = try requiredDatabase()
        let result: TagDefinitionMutationResult = try mapMutationStorageFailure {
            try database.write { database in
                guard
                    let currentName = try String.fetchOne(
                        database,
                        sql: """
                            SELECT display_name
                            FROM clipboard_tag_definitions
                            WHERE id = ?
                            """,
                        arguments: [id]
                    )
                else {
                    throw ClipboardHistoryModuleError
                        .tagDefinitionNotFound
                }
                let duplicateExists =
                    (try Bool.fetchOne(
                        database,
                        sql: """
                            SELECT EXISTS(
                                SELECT 1
                                FROM clipboard_tag_definitions
                                WHERE id != ? AND display_name = ?
                            )
                            """,
                        arguments: [id, displayName]
                    )) ?? false
                guard !duplicateExists else {
                    throw ClipboardHistoryModuleError.duplicateTagName
                }
                let didMutate = currentName != displayName
                if didMutate {
                    try database.execute(
                        sql: """
                            UPDATE clipboard_tag_definitions
                            SET display_name = ?
                            WHERE id = ?
                            """,
                        arguments: [displayName, id]
                    )
                    try Self.bumpHistoryRevision(in: database)
                }
                return TagDefinitionMutationResult(
                    definition: ClipboardHistoryTagDefinition(
                        id: id,
                        displayName: displayName
                    ),
                    didMutate: didMutate
                )
            }
        }
        if result.didMutate {
            publishMutation()
        }
        return result.definition
    }

    public func deleteTagDefinition(
        id: String
    ) throws -> ClipboardHistoryTagDefinitionUpdate {
        let database = try requiredDatabase()
        let timestamp = now().timeIntervalSince1970
        let result: TagDefinitionUpdateMutationResult = try mapMutationStorageFailure {
            try database.write { database in
                let definitionExists =
                    (try Bool.fetchOne(
                        database,
                        sql: """
                            SELECT EXISTS(
                                SELECT 1
                                FROM clipboard_tag_definitions
                                WHERE id = ?
                            )
                            """,
                        arguments: [id]
                    )) ?? false
                let removedMembershipCount =
                    try Int.fetchOne(
                        database,
                        sql: """
                            SELECT COUNT(*)
                            FROM clipboard_entry_tags
                            WHERE tag_id = ?
                            """,
                        arguments: [id]
                    ) ?? 0
                let previouslyProtected = Set(
                    try String.fetchAll(
                        database,
                        sql: """
                            SELECT entry_id
                            FROM clipboard_retention_state
                            WHERE is_protected = 1
                            """
                    )
                )
                try database.execute(
                    sql: """
                        DELETE FROM clipboard_entry_tags
                        WHERE tag_id = ?
                        """,
                    arguments: [id]
                )
                try database.execute(
                    sql: """
                        DELETE FROM clipboard_tag_definitions
                        WHERE id = ?
                        """,
                    arguments: [id]
                )
                try database.execute(
                    sql: """
                        UPDATE clipboard_retention_state
                        SET is_protected = (
                            SELECT CASE
                                WHEN entry.is_favorite = 1
                                  OR EXISTS (
                                      SELECT 1
                                      FROM clipboard_entry_tags AS assignment
                                      JOIN clipboard_tag_definitions AS definition
                                        ON definition.id = assignment.tag_id
                                      WHERE assignment.entry_id =
                                            clipboard_retention_state.entry_id
                                  )
                                THEN 1
                                ELSE 0
                            END
                            FROM clipboard_entries AS entry
                            WHERE entry.id =
                                  clipboard_retention_state.entry_id
                        )
                        """
                )
                let currentlyProtected = Set(
                    try String.fetchAll(
                        database,
                        sql: """
                            SELECT entry_id
                            FROM clipboard_retention_state
                            WHERE is_protected = 1
                            """
                    )
                )
                let newlyUnprotected = previouslyProtected.subtracting(
                    currentlyProtected
                )
                for entryID in newlyUnprotected {
                    try database.execute(
                        sql: """
                            UPDATE clipboard_retention_state
                            SET retention_started_at = ?
                            WHERE entry_id = ?
                            """,
                        arguments: [timestamp, entryID]
                    )
                }
                if definitionExists || removedMembershipCount > 0 {
                    try Self.bumpHistoryRevision(in: database)
                    try Self.bumpSearchIndexGeneration(in: database)
                }
                return TagDefinitionUpdateMutationResult(
                    update: ClipboardHistoryTagDefinitionUpdate(
                        removedMembershipCount: removedMembershipCount,
                        unprotectedEntryCount: newlyUnprotected.count
                    ),
                    didMutate: definitionExists || removedMembershipCount > 0
                )
            }
        }
        if result.didMutate {
            publishMutation()
        }
        return result.update
    }

    public func replaceTagDefinitions(
        with tagIDs: Set<String>
    ) throws -> ClipboardHistoryTagDefinitionUpdate {
        try replaceTagDefinitions(
            with: tagIDs.sorted().map {
                ClipboardHistoryTagDefinition(
                    id: $0,
                    displayName: $0
                )
            }
        )
    }

    public func replaceTagDefinitions(
        with definitions: [ClipboardHistoryTagDefinition]
    ) throws -> ClipboardHistoryTagDefinitionUpdate {
        let invalidTagIDs = Set(
            definitions.map(\.id).filter(\.isEmpty)
        )
        guard invalidTagIDs.isEmpty else {
            throw ClipboardHistoryModuleError.invalidTagIDs(
                invalidTagIDs
            )
        }
        let tagIDs = Set(definitions.map(\.id))
        guard tagIDs.count == definitions.count else {
            throw ClipboardHistoryModuleError.invalidTagIDs(tagIDs)
        }
        let names = definitions.map {
            $0.displayName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }
        guard !names.contains(where: \.isEmpty),
            Set(names).count == names.count
        else {
            throw ClipboardHistoryModuleError.invalidTagName
        }
        let database = try requiredDatabase()
        let timestamp = now().timeIntervalSince1970
        let normalizedDefinitions = zip(definitions, names).map {
            ClipboardHistoryTagDefinition(
                id: $0.0.id,
                displayName: $0.1
            )
        }
        let result: TagDefinitionUpdateMutationResult = try mapMutationStorageFailure {
            try database.write { database in
                let currentDefinitions = try Row.fetchAll(
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
                guard currentDefinitions != normalizedDefinitions else {
                    return TagDefinitionUpdateMutationResult(
                        update: ClipboardHistoryTagDefinitionUpdate(
                            removedMembershipCount: 0,
                            unprotectedEntryCount: 0
                        ),
                        didMutate: false
                    )
                }
                let oldDefinitionIDs = Set(
                    currentDefinitions.map(\.id)
                )
                let removedDefinitions = oldDefinitionIDs.subtracting(
                    tagIDs
                )
                let removedMembershipCount: Int
                if removedDefinitions.isEmpty {
                    removedMembershipCount = 0
                } else {
                    removedMembershipCount =
                        try Int.fetchOne(
                            database,
                            sql: """
                                SELECT COUNT(*)
                                FROM clipboard_entry_tags
                                WHERE tag_id IN (
                                    SELECT id
                                    FROM clipboard_tag_definitions
                                    WHERE id NOT IN (
                                        SELECT value FROM json_each(?)
                                    )
                                )
                                """,
                            arguments: [Self.jsonArray(tagIDs)]
                        ) ?? 0
                }

                let previouslyProtected = Set(
                    try String.fetchAll(
                        database,
                        sql: """
                            SELECT entry_id
                            FROM clipboard_retention_state
                            WHERE is_protected = 1
                            """
                    )
                )
                try database.execute(
                    sql: """
                        DELETE FROM clipboard_entry_tags
                        WHERE tag_id NOT IN (
                            SELECT value FROM json_each(?)
                        )
                        """,
                    arguments: [Self.jsonArray(tagIDs)]
                )
                try database.execute(sql: "DELETE FROM clipboard_tag_definitions")
                for (displayOrder, definition) in
                    normalizedDefinitions.enumerated()
                {
                    try database.execute(
                        sql: """
                            INSERT INTO clipboard_tag_definitions(
                                id, display_name, display_order
                            ) VALUES (?, ?, ?)
                            """,
                        arguments: [
                            definition.id,
                            definition.displayName,
                            displayOrder,
                        ]
                    )
                }
                try database.execute(
                    sql: """
                        UPDATE clipboard_retention_state
                        SET is_protected = (
                            SELECT CASE
                                WHEN entry.is_favorite = 1
                                  OR EXISTS (
                                      SELECT 1
                                      FROM clipboard_entry_tags AS assignment
                                      JOIN clipboard_tag_definitions AS definition
                                        ON definition.id = assignment.tag_id
                                      WHERE assignment.entry_id =
                                            clipboard_retention_state.entry_id
                                  )
                                THEN 1
                                ELSE 0
                            END
                            FROM clipboard_entries AS entry
                            WHERE entry.id =
                                  clipboard_retention_state.entry_id
                        )
                        """
                )
                let currentlyProtected = Set(
                    try String.fetchAll(
                        database,
                        sql: """
                            SELECT entry_id
                            FROM clipboard_retention_state
                            WHERE is_protected = 1
                            """
                    )
                )
                let newlyUnprotected = previouslyProtected.subtracting(
                    currentlyProtected
                )
                for entryID in newlyUnprotected {
                    try database.execute(
                        sql: """
                            UPDATE clipboard_retention_state
                            SET retention_started_at = ?
                            WHERE entry_id = ?
                            """,
                        arguments: [timestamp, entryID]
                    )
                }
                try Self.bumpHistoryRevision(in: database)
                try Self.bumpSearchIndexGeneration(in: database)
                return TagDefinitionUpdateMutationResult(
                    update: ClipboardHistoryTagDefinitionUpdate(
                        removedMembershipCount: removedMembershipCount,
                        unprotectedEntryCount: newlyUnprotected.count
                    ),
                    didMutate: true
                )
            }
        }
        if result.didMutate {
            publishMutation()
        }
        return result.update
    }

    public func prepareRetentionChange(
        to period: ClipboardHistoryRetentionPeriod
    ) async throws -> ClipboardHistoryRetentionChangePreparation {
        let database = try requiredDatabase()
        let date = now()
        let preparation: RetentionPreparationResult
        do {
            preparation = try await database.write {
                database -> RetentionPreparationResult in
                let current = try Self.retentionPeriod(in: database)
                guard current != period else {
                    return RetentionPreparationResult(
                        preparation: .applied(period),
                        payloadPaths: [],
                        deletedEntryIDs: [],
                        didMutate: false
                    )
                }
                let affectedIDs = try retentionReductionEntryIDs(
                    from: current,
                    to: period,
                    at: date,
                    in: database
                )
                if !affectedIDs.isEmpty {
                    let preview = try makePreview(
                        operation: .retention(period),
                        entryIDs: affectedIDs,
                        in: database
                    )
                    return RetentionPreparationResult(
                        preparation: .confirmationRequired(preview),
                        payloadPaths: [],
                        deletedEntryIDs: [],
                        didMutate: false
                    )
                }

                let expiredIDs = try expiredEntryIDs(at: date, in: database)
                let payloadPaths = try logicallyDelete(
                    entryIDs: expiredIDs,
                    in: database
                )
                try setRetentionPeriod(period, in: database)
                try Self.bumpHistoryRevision(in: database)
                try Self.bumpSearchIndexGeneration(in: database)
                return RetentionPreparationResult(
                    preparation: .applied(period),
                    payloadPaths: payloadPaths,
                    deletedEntryIDs: Set(expiredIDs),
                    didMutate: true
                )
            }
        } catch let error as ClipboardHistoryModuleError {
            throw error
        } catch {
            throw ClipboardHistoryModuleError.storageFailure
        }
        cancelDerivedJobs(for: preparation.deletedEntryIDs)
        await enqueueReclamation(for: preparation.payloadPaths)
        if preparation.didMutate {
            publishMutation()
        }
        return preparation.preparation
    }

    public func previewClearHistory(
        scope: ClipboardHistoryClearScope
    ) throws -> ClipboardHistoryDestructivePreview {
        let database = try requiredDatabase()
        let date = now()
        return try database.read { database in
            try makePreview(
                operation: .clear(scope),
                entryIDs: try clearEntryIDs(
                    scope: scope,
                    at: date,
                    in: database
                ),
                in: database
            )
        }
    }

    public func confirm(
        _ token: ClipboardHistoryConfirmationToken
    ) async throws -> ClipboardHistoryDestructiveApplyOutcome {
        let payload: ConfirmationPayload
        do {
            payload = try JSONDecoder().decode(
                ConfirmationPayload.self,
                from: token.data
            )
        } catch {
            throw ClipboardHistoryModuleError.invalidConfirmation
        }
        let database = try requiredDatabase()
        let date = now()
        let finalizesClear: Bool
        if case .clear = payload.operation {
            finalizesClear = true
        } else {
            finalizesClear = false
        }
        if finalizesClear {
            isFinalizingClear = true
        }
        defer {
            if finalizesClear {
                isFinalizingClear = false
            }
        }
        let result: ConfirmationApplyResult
        do {
            result = try await database.write {
                database -> ConfirmationApplyResult in
                let currentRevision = try Self.historyRevision(in: database)
                let currentIDs: [String]
                switch payload.operation {
                case .retention(let period):
                    currentIDs = try retentionReductionEntryIDs(
                        from: try Self.retentionPeriod(in: database),
                        to: period,
                        at: date,
                        in: database
                    )
                case .clear(let scope):
                    currentIDs = try clearEntryIDs(
                        scope: scope,
                        at: date,
                        in: database
                    )
                }
                let sortedCurrentIDs = currentIDs.sorted()
                guard currentRevision == payload.revision,
                    sortedCurrentIDs == payload.entryIDs
                else {
                    return ConfirmationApplyResult(
                        outcome: .stale(
                            try makePreview(
                                operation: payload.operation,
                                entryIDs: sortedCurrentIDs,
                                in: database
                            )
                        ),
                        payloadPaths: [],
                        deletedEntryIDs: [],
                        didMutate: false
                    )
                }

                let expiredIDs = try expiredEntryIDs(at: date, in: database)
                let allDeletedIDs = Set(currentIDs).union(expiredIDs)
                let payloadPaths = try logicallyDelete(
                    entryIDs: Array(allDeletedIDs),
                    in: database
                )
                if case .retention(let period) = payload.operation {
                    try setRetentionPeriod(period, in: database)
                }
                let didMutate = switch payload.operation {
                case .retention:
                    true
                case .clear:
                    !allDeletedIDs.isEmpty
                }
                try faultInjector.check(.databaseTransaction)
                return ConfirmationApplyResult(
                    outcome: .applied(deletedCount: currentIDs.count),
                    payloadPaths: payloadPaths,
                    deletedEntryIDs: allDeletedIDs,
                    didMutate: didMutate
                )
            }
        } catch let error as ClipboardHistoryModuleError {
            throw error
        } catch {
            throw ClipboardHistoryModuleError.storageFailure
        }
        if case .clear = payload.operation,
            case .applied = result.outcome
        {
            await captureMonitor?.establishBaseline()
            isFinalizingClear = false
        }
        cancelDerivedJobs(for: result.deletedEntryIDs)
        await enqueueReclamation(for: result.payloadPaths)
        if result.didMutate {
            publishMutation()
        }
        return result.outcome
    }

    func setFavorite(
        _ isFavorite: Bool,
        for entryID: ClipboardHistoryEntryID,
        in database: DatabasePool
    ) throws -> MutationApplyResult {
        let storedID = entryID.value.uuidString.lowercased()
        let timestamp = now()
        return try mapMutationStorageFailure {
            try database.write { database in
                guard try isLiveEntry(storedID, at: timestamp, in: database) else {
                    return MutationApplyResult(
                        outcome: .notFound,
                        didMutate: false
                    )
                }
                let currentFavorite = try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT is_favorite
                        FROM clipboard_entries
                        WHERE id = ?
                        """,
                    arguments: [storedID]
                ) ?? false
                if currentFavorite == isFavorite {
                    return MutationApplyResult(
                        outcome: .updated(
                            try Self.entry(
                                from: try requiredEntryRow(
                                    storedID,
                                    in: database
                                ),
                                in: database
                            )
                        ),
                        didMutate: false
                    )
                }
                let wasProtected = try protectionState(
                    for: storedID,
                    in: database
                )
                try database.execute(
                    sql: """
                        UPDATE clipboard_entries
                        SET is_favorite = ?
                        WHERE id = ?
                        """,
                    arguments: [isFavorite, storedID]
                )
                let isProtected = try recomputeProtection(
                    for: storedID,
                    in: database
                )
                if wasProtected, !isProtected {
                    try resetRetentionStart(
                        for: storedID,
                        to: timestamp,
                        in: database
                    )
                }
                try Self.bumpHistoryRevision(in: database)
                try Self.bumpSearchIndexGeneration(in: database)
                return MutationApplyResult(
                    outcome: .updated(
                        try Self.entry(
                            from: try requiredEntryRow(
                                storedID,
                                in: database
                            ),
                            in: database
                        )
                    ),
                    didMutate: true
                )
            }
        }
    }

    func setTags(
        _ tagIDs: Set<String>,
        for entryID: ClipboardHistoryEntryID,
        in database: DatabasePool
    ) throws -> MutationApplyResult {
        let storedID = entryID.value.uuidString.lowercased()
        let timestamp = now()
        return try mapMutationStorageFailure {
            try database.write { database in
                guard try isLiveEntry(storedID, at: timestamp, in: database) else {
                    return MutationApplyResult(
                        outcome: .notFound,
                        didMutate: false
                    )
                }
                let validTagIDs = Set(
                    try String.fetchAll(
                        database,
                        sql: "SELECT id FROM clipboard_tag_definitions"
                    )
                )
                let invalidTagIDs = tagIDs.subtracting(validTagIDs)
                guard invalidTagIDs.isEmpty else {
                    throw ClipboardHistoryModuleError.invalidTagIDs(invalidTagIDs)
                }
                let currentTagIDs = Set(
                    try String.fetchAll(
                        database,
                        sql: """
                            SELECT tag_id
                            FROM clipboard_entry_tags
                            WHERE entry_id = ?
                            """,
                        arguments: [storedID]
                    )
                )
                if currentTagIDs == tagIDs {
                    return MutationApplyResult(
                        outcome: .updated(
                            try Self.entry(
                                from: try requiredEntryRow(
                                    storedID,
                                    in: database
                                ),
                                in: database
                            )
                        ),
                        didMutate: false
                    )
                }
                let wasProtected = try protectionState(
                    for: storedID,
                    in: database
                )
                try database.execute(
                    sql: """
                        DELETE FROM clipboard_entry_tags
                        WHERE entry_id = ?
                        """,
                    arguments: [storedID]
                )
                for tagID in tagIDs.sorted() {
                    try database.execute(
                        sql: """
                            INSERT INTO clipboard_entry_tags(entry_id, tag_id)
                            VALUES (?, ?)
                            """,
                        arguments: [storedID, tagID]
                    )
                }
                let isProtected = try recomputeProtection(
                    for: storedID,
                    in: database
                )
                if wasProtected, !isProtected {
                    try resetRetentionStart(
                        for: storedID,
                        to: timestamp,
                        in: database
                    )
                }
                try Self.bumpHistoryRevision(in: database)
                try Self.bumpSearchIndexGeneration(in: database)
                return MutationApplyResult(
                    outcome: .updated(
                        try Self.entry(
                            from: try requiredEntryRow(
                                storedID,
                                in: database
                            ),
                            in: database
                        )
                    ),
                    didMutate: true
                )
            }
        }
    }

    func editText(
        _ text: String,
        for entryID: ClipboardHistoryEntryID,
        in database: DatabasePool
    ) async throws -> MutationApplyResult {
        guard !text.isEmpty else {
            throw ClipboardHistoryModuleError.invalidTextEdit
        }
        let storedID = entryID.value.uuidString.lowercased()
        let date = now()
        let snapshot = PasteboardSnapshot(
            items: [
                PasteboardSnapshot.Item(
                    representations: [
                        .text(
                            typeIdentifier: "public.utf8-plain-text",
                            value: text
                        )
                    ]
                )
            ],
            extraFacets: [],
            allowsTextInference: true
        )
        let identity = try CanonicalIdentity(
            snapshot: snapshot,
            fingerprintDigest: fingerprintDigest
        )
        let facets = Set([ClipboardHistoryFacet.text]).union(
            Self.inferredFacets(forExactText: text)
        )
        let result: TextEditResult
        do {
            result = try await database.write { database in
                guard try isLiveEntry(storedID, at: date, in: database) else {
                    return TextEditResult(
                        outcome: MutationApplyResult(
                            outcome: .notFound,
                            didMutate: false
                        ),
                        payloadPaths: []
                    )
                }
                let itemCount =
                    try Int.fetchOne(
                        database,
                        sql: """
                            SELECT COUNT(*)
                            FROM clipboard_items
                            WHERE entry_id = ?
                            """,
                        arguments: [storedID]
                    ) ?? 0
                let exactTextCount =
                    try Int.fetchOne(
                        database,
                        sql: """
                            SELECT COUNT(*)
                            FROM clipboard_representations
                            WHERE entry_id = ?
                              AND type_identifier = 'public.utf8-plain-text'
                              AND text_value IS NOT NULL
                            """,
                        arguments: [storedID]
                    ) ?? 0
                guard itemCount == 1, exactTextCount >= 1 else {
                    throw ClipboardHistoryModuleError.invalidTextEdit
                }

                let payloads = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT DISTINCT payload.id, payload.relative_path
                        FROM clipboard_payloads AS payload
                        WHERE payload.id IN (
                            SELECT payload_id
                            FROM clipboard_representations
                            WHERE entry_id = ?
                              AND payload_id IS NOT NULL
                            UNION
                            SELECT thumbnail_payload_id
                            FROM clipboard_entries
                            WHERE id = ?
                              AND thumbnail_payload_id IS NOT NULL
                            UNION
                            SELECT payload_id
                            FROM clipboard_file_members
                            WHERE entry_id = ?
                              AND payload_id IS NOT NULL
                        )
                        ORDER BY payload.id
                        """,
                    arguments: [storedID, storedID, storedID]
                )

                try Self.deleteSearchFields(
                    forEntryID: storedID,
                    from: database,
                    faultInjector: faultInjector
                )
                try faultInjector.check(.logicalDeletionAfterSearchIndexes)
                try database.execute(
                    sql: """
                        UPDATE clipboard_entries
                        SET preview_text = ?, edited_at = ?,
                            thumbnail_payload_id = NULL
                        WHERE id = ?
                        """,
                    arguments: [
                        Self.boundedPreviewText(text),
                        date.timeIntervalSince1970,
                        storedID,
                    ]
                )
                try database.execute(
                    sql: """
                        DELETE FROM clipboard_representations
                        WHERE entry_id = ?
                        """,
                    arguments: [storedID]
                )
                try database.execute(
                    sql: """
                        DELETE FROM clipboard_file_members
                        WHERE entry_id = ?
                        """,
                    arguments: [storedID]
                )
                try database.execute(
                    sql: """
                        DELETE FROM clipboard_entry_facets
                        WHERE entry_id = ?
                        """,
                    arguments: [storedID]
                )
                try database.execute(
                    sql: """
                        DELETE FROM clipboard_duplicate_candidates
                        WHERE entry_id = ?
                        """,
                    arguments: [storedID]
                )
                try database.execute(
                    sql: """
                        DELETE FROM clipboard_derived_jobs
                        WHERE entry_id = ?
                        """,
                    arguments: [storedID]
                )
                try faultInjector.check(.logicalDeletionAfterEntries)
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_representations(
                            entry_id, item_index, representation_index,
                            kind, type_identifier, text_value
                        ) VALUES (?, 0, 0, 'text',
                                  'public.utf8-plain-text', ?)
                        """,
                    arguments: [storedID, text]
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
                try Self.insertSearchField(
                    value: text,
                    kind: "exactText",
                    index: 0,
                    rankingGroup: Self.searchRankingGroup(for: "exactText"),
                    entryID: storedID,
                    into: database,
                    faultInjector: faultInjector
                )
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_duplicate_candidates(
                            fingerprint, entry_id, canonical_byte_count,
                            created_at
                        ) VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        identity.fingerprint,
                        storedID,
                        identity.canonicalByteCount,
                        date.timeIntervalSince1970,
                    ]
                )
                try database.execute(
                    sql: """
                        UPDATE clipboard_retention_state
                        SET retention_started_at = ?
                        WHERE entry_id = ?
                        """,
                    arguments: [date.timeIntervalSince1970, storedID]
                )

                var payloadPaths: [String] = []
                for payload in payloads {
                    let payloadID: String = payload["id"]
                    try database.execute(
                        sql: """
                            DELETE FROM clipboard_payloads
                            WHERE id = ?
                              AND NOT EXISTS (
                                  SELECT 1 FROM clipboard_representations
                                  WHERE payload_id = ?
                              )
                              AND NOT EXISTS (
                                  SELECT 1 FROM clipboard_entries
                                  WHERE thumbnail_payload_id = ?
                              )
                              AND NOT EXISTS (
                                  SELECT 1 FROM clipboard_file_members
                                  WHERE payload_id = ?
                              )
                            """,
                        arguments: [
                            payloadID,
                            payloadID,
                            payloadID,
                            payloadID,
                        ]
                    )
                    if database.changesCount == 1 {
                        payloadPaths.append(payload["relative_path"])
                    }
                }
                try faultInjector.check(.logicalDeletionAfterPayloadRows)
                try Self.bumpHistoryRevision(in: database)
                try Self.bumpSearchIndexGeneration(in: database)
                try faultInjector.check(.databaseTransaction)
                return TextEditResult(
                    outcome: MutationApplyResult(
                        outcome: .updated(
                            try Self.entry(
                                from: try requiredEntryRow(
                                    storedID,
                                    in: database
                                ),
                                in: database
                            )
                        ),
                        didMutate: true
                    ),
                    payloadPaths: payloadPaths
                )
            }
        } catch let error as ClipboardHistoryModuleError {
            throw error
        } catch {
            throw ClipboardHistoryModuleError.storageFailure
        }
        cancelDerivedJobs(for: [storedID])
        await enqueueReclamation(for: result.payloadPaths)
        return result.outcome
    }

    nonisolated func isLiveEntry(
        _ entryID: String,
        at date: Date,
        in database: Database
    ) throws -> Bool {
        let cutoff = try Self.expiryCutoff(at: date, in: database)
        if let cutoff {
            return try Int.fetchOne(
                database,
                sql: """
                    SELECT 1
                    FROM clipboard_entries AS entry
                    JOIN clipboard_retention_state AS retention
                      ON retention.entry_id = entry.id
                    WHERE entry.id = ?
                      AND (
                          retention.is_protected = 1
                          OR retention.retention_started_at > ?
                      )
                    """,
                arguments: [entryID, cutoff]
            ) == 1
        }
        return try Int.fetchOne(
            database,
            sql: "SELECT 1 FROM clipboard_entries WHERE id = ?",
            arguments: [entryID]
        ) == 1
    }

    static func expiryCutoff(
        at date: Date,
        in database: Database
    ) throws -> Double? {
        guard let duration = try retentionPeriod(in: database).duration else {
            return nil
        }
        return date.addingTimeInterval(-duration).timeIntervalSince1970
    }

    static func bumpHistoryRevision(in database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO clipboard_maintenance_metadata(key, integer_value)
                VALUES ('historyRevision', 1)
                ON CONFLICT(key) DO UPDATE SET
                    integer_value = COALESCE(integer_value, 0) + 1,
                    real_value = NULL,
                    text_value = NULL,
                    data_value = NULL
                """
        )
    }

    static func historyRevision(in database: Database) throws -> Int64 {
        Int64(
            try Int.fetchOne(
                database,
                sql: """
                    SELECT integer_value
                    FROM clipboard_maintenance_metadata
                    WHERE key = 'historyRevision'
                    """
            ) ?? 0
        )
    }

    private func protectionState(
        for entryID: String,
        in database: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT is_protected
                FROM clipboard_retention_state
                WHERE entry_id = ?
                """,
            arguments: [entryID]
        ) ?? false
    }

    @discardableResult
    private func recomputeProtection(
        for entryID: String,
        in database: Database
    ) throws -> Bool {
        let isProtected =
            try Bool.fetchOne(
                database,
                sql: """
                    SELECT entry.is_favorite = 1
                        OR EXISTS (
                            SELECT 1
                            FROM clipboard_entry_tags AS assignment
                            JOIN clipboard_tag_definitions AS definition
                              ON definition.id = assignment.tag_id
                            WHERE assignment.entry_id = entry.id
                        )
                    FROM clipboard_entries AS entry
                    WHERE entry.id = ?
                    """,
                arguments: [entryID]
            ) ?? false
        try database.execute(
            sql: """
                UPDATE clipboard_retention_state
                SET is_protected = ?
                WHERE entry_id = ?
                """,
            arguments: [isProtected, entryID]
        )
        return isProtected
    }

    private func resetRetentionStart(
        for entryID: String,
        to date: Date,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                UPDATE clipboard_retention_state
                SET retention_started_at = ?
                WHERE entry_id = ?
                """,
            arguments: [date.timeIntervalSince1970, entryID]
        )
    }

    private nonisolated func requiredEntryRow(
        _ entryID: String,
        in database: Database
    ) throws -> Row {
        guard
            let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, captured_at, last_captured_at, preview_text,
                           is_favorite, source_bundle_id, source_display_name,
                           source_provenance
                    FROM clipboard_entries
                    WHERE id = ?
                    """,
                arguments: [entryID]
            )
        else {
            throw ClipboardHistoryModuleError.entryNotFound
        }
        return row
    }

    private func mapMutationStorageFailure<Value>(
        _ operation: () throws -> Value
    ) throws -> Value {
        do {
            return try operation()
        } catch let error as ClipboardHistoryModuleError {
            throw error
        } catch {
            throw ClipboardHistoryModuleError.storageFailure
        }
    }

    private static func jsonArray(_ values: Set<String>) -> String {
        let data = try? JSONEncoder().encode(values.sorted())
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private nonisolated func makePreview(
        operation: ConfirmationOperation,
        entryIDs: [String],
        in database: Database
    ) throws -> ClipboardHistoryDestructivePreview {
        let payload = ConfirmationPayload(
            operation: operation,
            revision: try Self.historyRevision(in: database),
            entryIDs: entryIDs.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ClipboardHistoryDestructivePreview(
            affectedCount: payload.entryIDs.count,
            token: ClipboardHistoryConfirmationToken(
                data: try encoder.encode(payload)
            )
        )
    }

    private nonisolated func retentionReductionEntryIDs(
        from current: ClipboardHistoryRetentionPeriod,
        to proposed: ClipboardHistoryRetentionPeriod,
        at date: Date,
        in database: Database
    ) throws -> [String] {
        guard let proposedDuration = proposed.duration else {
            return []
        }
        if let currentDuration = current.duration,
            proposedDuration >= currentDuration
        {
            return []
        }
        let proposedCutoff = date.addingTimeInterval(
            -proposedDuration
        ).timeIntervalSince1970
        var arguments: StatementArguments = [proposedCutoff]
        let currentLiveCondition: String
        if let currentDuration = current.duration {
            currentLiveCondition = "AND retention.retention_started_at > ?"
            arguments += [
                date.addingTimeInterval(-currentDuration)
                    .timeIntervalSince1970
            ]
        } else {
            currentLiveCondition = ""
        }
        return try String.fetchAll(
            database,
            sql: """
                SELECT retention.entry_id
                FROM clipboard_retention_state AS retention
                WHERE retention.is_protected = 0
                  AND retention.retention_started_at <= ?
                  \(currentLiveCondition)
                ORDER BY retention.entry_id
                """,
            arguments: arguments
        )
    }

    private nonisolated func clearEntryIDs(
        scope: ClipboardHistoryClearScope,
        at date: Date,
        in database: Database
    ) throws -> [String] {
        let cutoff = try Self.expiryCutoff(at: date, in: database)
        var conditions: [String] = []
        var arguments: StatementArguments = []
        if scope == .unprotectedOnly {
            conditions.append("retention.is_protected = 0")
        }
        if let cutoff {
            conditions.append(
                """
                (
                    retention.is_protected = 1
                    OR retention.retention_started_at > ?
                )
                """
            )
            arguments += [cutoff]
        }
        let predicate =
            conditions.isEmpty
            ? ""
            : "WHERE \(conditions.joined(separator: " AND "))"
        return try String.fetchAll(
            database,
            sql: """
                SELECT entry.id
                FROM clipboard_entries AS entry
                JOIN clipboard_retention_state AS retention
                  ON retention.entry_id = entry.id
                \(predicate)
                ORDER BY entry.id
                """,
            arguments: arguments
        )
    }

    nonisolated func expiredEntryIDs(
        at date: Date,
        in database: Database
    ) throws -> [String] {
        guard let cutoff = try Self.expiryCutoff(at: date, in: database) else {
            return []
        }
        return try String.fetchAll(
            database,
            sql: """
                SELECT entry_id
                FROM clipboard_retention_state
                WHERE is_protected = 0
                  AND retention_started_at <= ?
                ORDER BY entry_id
                """,
            arguments: [cutoff]
        )
    }

    nonisolated func logicallyDelete(
        entryIDs: [String],
        in database: Database
    ) throws -> [String] {
        let entryIDs = Array(Set(entryIDs)).sorted()
        guard !entryIDs.isEmpty else { return [] }
        let rebuildsSearchIndexes = entryIDs.count >= 512
        let encodedIDs = Self.jsonArray(Set(entryIDs))
        let payloads = try Row.fetchAll(
            database,
            sql: """
                SELECT DISTINCT payload.id, payload.relative_path
                FROM clipboard_payloads AS payload
                WHERE payload.id IN (
                    SELECT representation.payload_id
                    FROM clipboard_representations AS representation
                    WHERE representation.entry_id IN (
                        SELECT value FROM json_each(?)
                    )
                      AND representation.payload_id IS NOT NULL
                    UNION
                    SELECT entry.thumbnail_payload_id
                    FROM clipboard_entries AS entry
                    WHERE entry.id IN (
                        SELECT value FROM json_each(?)
                    )
                      AND entry.thumbnail_payload_id IS NOT NULL
                    UNION
                    SELECT member.payload_id
                    FROM clipboard_file_members AS member
                    WHERE member.entry_id IN (
                        SELECT value FROM json_each(?)
                    )
                      AND member.payload_id IS NOT NULL
                )
                ORDER BY payload.id
                """,
            arguments: [encodedIDs, encodedIDs, encodedIDs]
        )
        if rebuildsSearchIndexes {
            try database.execute(
                sql: "DROP TABLE clipboard_search_trigram"
            )
            try database.execute(
                sql: "DROP TABLE clipboard_search_short_grams"
            )
        } else {
            for entryID in entryIDs {
                try Self.deleteSearchFields(
                    forEntryID: entryID,
                    from: database,
                    faultInjector: faultInjector
                )
            }
        }
        try faultInjector.check(.logicalDeletionAfterSearchIndexes)
        try database.execute(
            sql: """
                DELETE FROM clipboard_entries
                WHERE id IN (
                    SELECT value FROM json_each(?)
                )
                """,
            arguments: [encodedIDs]
        )
        try faultInjector.check(.logicalDeletionAfterEntries)
        if rebuildsSearchIndexes {
            try Self.createSearchIndexSchemaAfterBulkDeletion(
                in: database
            )
        }

        var reclaimedPaths: [String] = []
        for payload in payloads {
            let payloadID: String = payload["id"]
            try database.execute(
                sql: """
                    DELETE FROM clipboard_payloads
                    WHERE id = ?
                      AND NOT EXISTS (
                          SELECT 1 FROM clipboard_representations
                          WHERE payload_id = ?
                      )
                      AND NOT EXISTS (
                          SELECT 1 FROM clipboard_entries
                          WHERE thumbnail_payload_id = ?
                      )
                      AND NOT EXISTS (
                          SELECT 1 FROM clipboard_file_members
                          WHERE payload_id = ?
                      )
                    """,
                arguments: [
                    payloadID,
                    payloadID,
                    payloadID,
                    payloadID,
                ]
            )
            if database.changesCount == 1 {
                reclaimedPaths.append(payload["relative_path"])
            }
        }
        try faultInjector.check(.logicalDeletionAfterPayloadRows)
        try Self.bumpHistoryRevision(in: database)
        try Self.bumpSearchIndexGeneration(in: database)
        return reclaimedPaths
    }

    private nonisolated static func createSearchIndexSchemaAfterBulkDeletion(
        in database: Database
    ) throws {
        try createSearchVirtualTables(in: database)
        let fields = try Row.fetchAll(
            database,
            sql: """
                SELECT id, normalized_value
                FROM clipboard_search_fields
                ORDER BY id
                """
        )
        for field in fields {
            try insertSearchIndexEntries(
                fieldID: field["id"],
                normalizedValue: field["normalized_value"],
                into: database
            )
        }
    }

    func enqueueReclamation(for paths: [String]) async {
        guard let payloadStore = try? requiredPayloadStore() else { return }
        await payloadReclaimer.enqueue(paths: paths, in: payloadStore)
    }

    private nonisolated func setRetentionPeriod(
        _ period: ClipboardHistoryRetentionPeriod,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO clipboard_maintenance_metadata(key, text_value)
                VALUES ('retentionPeriod', ?)
                ON CONFLICT(key) DO UPDATE SET
                    integer_value = NULL,
                    real_value = NULL,
                    text_value = excluded.text_value,
                    data_value = NULL
                """,
            arguments: [period.rawValue]
        )
    }
}

private struct RetentionPreparationResult {
    let preparation: ClipboardHistoryRetentionChangePreparation
    let payloadPaths: [String]
    let deletedEntryIDs: Set<String>
    let didMutate: Bool
}

private struct ConfirmationApplyResult {
    let outcome: ClipboardHistoryDestructiveApplyOutcome
    let payloadPaths: [String]
    let deletedEntryIDs: Set<String>
    let didMutate: Bool
}

private struct TextEditResult {
    let outcome: ClipboardHistoryModule.MutationApplyResult
    let payloadPaths: [String]
}

private struct TagAssignmentMutationResult: Sendable {
    let assignment: ClipboardHistoryTagAssignment
    let didMutate: Bool
}

private struct TagDefinitionMutationResult: Sendable {
    let definition: ClipboardHistoryTagDefinition
    let didMutate: Bool
}

private struct TagDefinitionUpdateMutationResult: Sendable {
    let update: ClipboardHistoryTagDefinitionUpdate
    let didMutate: Bool
}

private enum ConfirmationOperation: Codable {
    case retention(ClipboardHistoryRetentionPeriod)
    case clear(ClipboardHistoryClearScope)
}

private struct ConfirmationPayload: Codable {
    let operation: ConfirmationOperation
    let revision: Int64
    let entryIDs: [String]
}
