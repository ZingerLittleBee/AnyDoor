import Foundation
import GRDB

extension ClipboardHistoryModule {
    static let searchIndexVersion = 1
    private static let searchIndexReadyState = "ready"
    private static let searchIndexIndexingState = "indexing"
    private static let searchIndexFailedState = "failed"
    private static let searchIndexRebuildFailedReason = "rebuildFailed"

    enum SearchIndexRebuildOutcome: Sendable {
        case ready
        case failed
        case failureStateUnavailable
    }

    static func validateSearchRuntimeCapabilities(
        of database: DatabasePool
    ) throws {
        do {
            try database.writeWithoutTransaction { database in
                let hasFTS5 =
                    try Bool.fetchOne(
                        database,
                        sql: "SELECT sqlite_compileoption_used('ENABLE_FTS5')"
                    ) ?? false
                try requireSearchRuntimeCapabilities(
                    hasFTS5: hasFTS5,
                    hasTrigramTokenizer: true
                )
                try database.execute(
                    sql: """
                        CREATE VIRTUAL TABLE temp.clipboard_trigram_probe
                        USING fts5(value, tokenize = 'trigram')
                        """
                )
                try database.execute(
                    sql: """
                        CREATE VIRTUAL TABLE temp.clipboard_short_gram_probe
                        USING fts5(
                            value,
                            content = '',
                            contentless_delete = 1,
                            tokenize = 'unicode61 remove_diacritics 0'
                        )
                        """
                )
                defer {
                    try? database.execute(
                        sql: "DROP TABLE temp.clipboard_trigram_probe"
                    )
                    try? database.execute(
                        sql: "DROP TABLE temp.clipboard_short_gram_probe"
                    )
                }
                try database.execute(
                    sql: """
                        INSERT INTO temp.clipboard_trigram_probe(
                            clipboard_trigram_probe,
                            rank
                        ) VALUES ('secure-delete', 1)
                        """
                )
                try database.execute(
                    sql: """
                        INSERT INTO temp.clipboard_short_gram_probe(
                            clipboard_short_gram_probe,
                            rank
                        ) VALUES ('secure-delete', 1)
                        """
                )
                try database.execute(
                    sql: """
                        INSERT INTO temp.clipboard_trigram_probe(value)
                        VALUES ('clipboard')
                        """
                )
                let matched = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*)
                        FROM temp.clipboard_trigram_probe
                        WHERE clipboard_trigram_probe MATCH ?
                        """,
                    arguments: [ftsLiteral("board")]
                )
                guard matched == 1 else {
                    throw StoreOpenError.unsupportedSearchIndex
                }
            }
        } catch is StoreOpenError {
            throw StoreOpenError.unsupportedSearchIndex
        } catch {
            throw StoreOpenError.unsupportedSearchIndex
        }
    }

    static func requireSearchRuntimeCapabilities(
        hasFTS5: Bool,
        hasTrigramTokenizer: Bool
    ) throws {
        guard hasFTS5, hasTrigramTokenizer else {
            throw StoreOpenError.unsupportedSearchIndex
        }
    }

    static func createSearchIndexSchema(in database: Database) throws {
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
        try setSearchMetadata(
            version: searchIndexVersion,
            generation: 1,
            state: searchIndexReadyState,
            in: database
        )
    }

    static func prepareSearchIndexState(in database: DatabasePool) throws {
        let needsRebuild = try database.read { database in
            let version = try maintenanceInteger(
                "searchIndexVersion",
                in: database
            )
            let state = try maintenanceText("searchIndexState", in: database)
            if state == searchIndexFailedState {
                return false
            }
            guard
                version == searchIndexVersion,
                state == searchIndexReadyState
            else {
                return true
            }
            return !(try searchIndexesPassIntegrityCheck(in: database))
        }
        guard needsRebuild else { return }

        try database.write { database in
            try setSearchIndexState(
                searchIndexIndexingState,
                failureReason: nil,
                in: database
            )
        }
    }

    static func makeSearchIndexRebuildTask(
        for database: DatabasePool?,
        faultInjector: ClipboardHistoryFaultInjector
    ) -> Task<SearchIndexRebuildOutcome, Never>? {
        guard let database else {
            return nil
        }
        let shouldRebuild: Bool
        do {
            shouldRebuild = try database.read {
                try searchIndexState(in: $0) == searchIndexIndexingState
            }
        } catch {
            return Task.detached(priority: .utility) {
                do {
                    try persistSearchIndexRebuildFailure(in: database)
                    return .failed
                } catch {
                    return .failureStateUnavailable
                }
            }
        }
        guard shouldRebuild else { return nil }
        return startSearchIndexRebuildTask(
            in: database,
            faultInjector: faultInjector
        )
    }

    private static func startSearchIndexRebuildTask(
        in database: DatabasePool,
        faultInjector: ClipboardHistoryFaultInjector
    ) -> Task<SearchIndexRebuildOutcome, Never> {
        return Task.detached(priority: .utility) {
            do {
                try rebuildSearchIndexes(
                    in: database,
                    faultInjector: faultInjector
                )
                return .ready
            } catch {
                do {
                    try persistSearchIndexRebuildFailure(in: database)
                    return .failed
                } catch {
                    return .failureStateUnavailable
                }
            }
        }
    }

    static func rebuildSearchIndexes(
        in database: DatabasePool,
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector()
    ) throws {
        try database.write { database in
            try database.execute(
                sql: "DROP TABLE IF EXISTS clipboard_search_trigram"
            )
            try database.execute(
                sql: "DROP TABLE IF EXISTS clipboard_search_short_grams"
            )
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
            let generation =
                (try maintenanceInteger(
                    "searchIndexGeneration",
                    in: database
                ) ?? 0) + 1
            try faultInjector.check(.searchRebuildBeforePublish)
            try setSearchMetadata(
                version: searchIndexVersion,
                generation: generation,
                state: searchIndexReadyState,
                in: database
            )
        }
    }

    static func retrySearchIndexes(
        in database: DatabasePool,
        faultInjector: ClipboardHistoryFaultInjector
    ) throws -> Task<SearchIndexRebuildOutcome, Never> {
        try database.write { database in
            try setSearchIndexState(
                searchIndexIndexingState,
                failureReason: nil,
                in: database
            )
        }
        return startSearchIndexRebuildTask(
            in: database,
            faultInjector: faultInjector
        )
    }

    private static func persistSearchIndexRebuildFailure(
        in database: DatabasePool
    ) throws {
        try database.write { database in
            try setSearchIndexState(
                searchIndexFailedState,
                failureReason: searchIndexRebuildFailedReason,
                in: database
            )
        }
    }

    static func createSearchVirtualTables(in database: Database) throws {
        try database.execute(
            sql: """
                CREATE VIRTUAL TABLE clipboard_search_trigram
                USING fts5(
                    normalized_value,
                    content = 'clipboard_search_fields',
                    content_rowid = 'id',
                    tokenize = 'trigram'
                )
                """
        )
        try database.execute(
            sql: """
                CREATE VIRTUAL TABLE clipboard_search_short_grams
                USING fts5(
                    grams,
                    content = '',
                    contentless_delete = 1,
                    tokenize = 'unicode61 remove_diacritics 0'
                )
                """
        )
        for table in [
            "clipboard_search_trigram",
            "clipboard_search_short_grams",
        ] {
            try database.execute(
                sql: """
                    INSERT INTO \(table)(\(table), rank)
                    VALUES ('secure-delete', 1)
                    """
            )
        }
    }

    static func searchIndexesPassIntegrityCheck(
        in database: Database
    ) throws -> Bool {
        do {
            try database.execute(
                sql: """
                    INSERT INTO clipboard_search_trigram(
                        clipboard_search_trigram,
                        rank
                    ) VALUES ('integrity-check', 1)
                    """
            )
            try database.execute(
                sql: """
                    INSERT INTO clipboard_search_short_grams(
                        clipboard_search_short_grams,
                        rank
                    ) VALUES ('integrity-check', 0)
                    """
            )
            return true
        } catch {
            return false
        }
    }

    static func insertSearchField(
        value: String,
        kind: String,
        index: Int,
        rankingGroup: Int,
        entryID: String,
        into database: Database,
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector()
    ) throws {
        let normalizedValue = normalizeSearchText(value)
        try database.execute(
            sql: """
                INSERT INTO clipboard_search_fields(
                    entry_id, field_kind, field_index, value,
                    normalized_value, ranking_group
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                entryID,
                kind,
                index,
                value,
                normalizedValue,
                rankingGroup,
            ]
        )
        try faultInjector.check(.searchInsertAfterField)
        try insertSearchIndexEntries(
            fieldID: database.lastInsertedRowID,
            normalizedValue: normalizedValue,
            into: database,
            faultInjector: faultInjector,
            afterTrigram: .searchInsertAfterTrigram,
            afterShortGrams: .searchInsertAfterShortGrams
        )
    }

    static func replaceSearchField(
        entryID: String,
        kind: String,
        index: Int,
        value: String,
        rankingGroup: Int,
        in database: Database,
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector()
    ) throws {
        guard let oldField = try Row.fetchOne(
            database,
            sql: """
                SELECT id, normalized_value
                FROM clipboard_search_fields
                WHERE entry_id = ? AND field_kind = ? AND field_index = ?
                """,
            arguments: [entryID, kind, index]
        ) else {
            try insertSearchField(
                value: value,
                kind: kind,
                index: index,
                rankingGroup: rankingGroup,
                entryID: entryID,
                into: database,
                faultInjector: faultInjector
            )
            return
        }
        let fieldID: Int64 = oldField["id"]
        let oldNormalizedValue: String = oldField["normalized_value"]
        try deleteSearchIndexEntries(
            fieldID: fieldID,
            normalizedValue: oldNormalizedValue,
            from: database,
            faultInjector: faultInjector,
            afterTrigram: .searchUpdateAfterOldTrigram,
            afterShortGrams: .searchUpdateAfterOldShortGrams
        )
        let newNormalizedValue = normalizeSearchText(value)
        try database.execute(
            sql: """
                UPDATE clipboard_search_fields
                SET value = ?, normalized_value = ?, ranking_group = ?
                WHERE id = ?
                """,
            arguments: [value, newNormalizedValue, rankingGroup, fieldID]
        )
        try faultInjector.check(.searchUpdateAfterField)
        try insertSearchIndexEntries(
            fieldID: fieldID,
            normalizedValue: newNormalizedValue,
            into: database,
            faultInjector: faultInjector,
            afterTrigram: .searchUpdateAfterNewTrigram,
            afterShortGrams: .searchUpdateAfterNewShortGrams
        )
    }

    static func deleteSearchFields(
        forEntryID entryID: String,
        from database: Database,
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector()
    ) throws {
        let fields = try Row.fetchAll(
            database,
            sql: """
                SELECT id, normalized_value
                FROM clipboard_search_fields
                WHERE entry_id = ?
                ORDER BY id
                """,
            arguments: [entryID]
        )
        for field in fields {
            let fieldID: Int64 = field["id"]
            let normalizedValue: String = field["normalized_value"]
            try deleteSearchIndexEntries(
                fieldID: fieldID,
                normalizedValue: normalizedValue,
                from: database,
                faultInjector: faultInjector,
                afterTrigram: .searchDeleteAfterTrigram,
                afterShortGrams: .searchDeleteAfterShortGrams
            )
            try database.execute(
                sql: "DELETE FROM clipboard_search_fields WHERE id = ?",
                arguments: [fieldID]
            )
        }
    }

    static func insertSearchIndexEntries(
        fieldID: Int64,
        normalizedValue: String,
        into database: Database,
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector(),
        afterTrigram: ClipboardHistoryFaultPoint? = nil,
        afterShortGrams: ClipboardHistoryFaultPoint? = nil
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO clipboard_search_trigram(
                    rowid,
                    normalized_value
                ) VALUES (?, ?)
                """,
            arguments: [fieldID, normalizedValue]
        )
        if let afterTrigram {
            try faultInjector.check(afterTrigram)
        }
        try database.execute(
            sql: """
                INSERT INTO clipboard_search_short_grams(rowid, grams)
                VALUES (?, ?)
                """,
            arguments: [fieldID, encodedShortGrams(for: normalizedValue)]
        )
        if let afterShortGrams {
            try faultInjector.check(afterShortGrams)
        }
    }

    static func deleteSearchIndexEntries(
        fieldID: Int64,
        normalizedValue: String,
        from database: Database,
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector(),
        afterTrigram: ClipboardHistoryFaultPoint? = nil,
        afterShortGrams: ClipboardHistoryFaultPoint? = nil
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO clipboard_search_trigram(
                    clipboard_search_trigram,
                    rowid,
                    normalized_value
                ) VALUES ('delete', ?, ?)
                """,
            arguments: [fieldID, normalizedValue]
        )
        if let afterTrigram {
            try faultInjector.check(afterTrigram)
        }
        try database.execute(
            sql: """
                DELETE FROM clipboard_search_short_grams
                WHERE rowid = ?
                """,
            arguments: [fieldID]
        )
        if let afterShortGrams {
            try faultInjector.check(afterShortGrams)
        }
    }

    static func bumpSearchIndexGeneration(in database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO clipboard_maintenance_metadata(key, integer_value)
                VALUES ('searchIndexGeneration', 1)
                ON CONFLICT(key) DO UPDATE SET
                    integer_value = COALESCE(integer_value, 0) + 1,
                    real_value = NULL,
                    text_value = NULL,
                    data_value = NULL
                """
        )
    }

    static func searchIndexGeneration(in database: Database) throws -> Int64 {
        Int64(
            try maintenanceInteger(
                "searchIndexGeneration",
                in: database
            ) ?? 0
        )
    }

    static func searchIndexState(in database: Database) throws -> String {
        try maintenanceText("searchIndexState", in: database)
            ?? searchIndexIndexingState
    }

    static func searchIndexStatus(
        in database: Database
    ) throws -> ClipboardHistorySearchIndexStatus {
        switch try searchIndexState(in: database) {
        case searchIndexReadyState:
            return .ready
        case searchIndexIndexingState:
            return .indexing
        case searchIndexFailedState:
            let reason = try maintenanceText(
                "searchIndexFailure",
                in: database
            )
            guard reason == searchIndexRebuildFailedReason else {
                return .failed(.stateUnavailable)
            }
            return .failed(.rebuildFailed)
        default:
            return .failed(.stateUnavailable)
        }
    }

    static func normalizeSearchText(_ value: String) -> String {
        value.decomposedStringWithCompatibilityMapping.folding(
            options: [
                .caseInsensitive,
                .diacriticInsensitive,
                .widthInsensitive,
            ],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func searchRankingGroup(for kind: String) -> Int {
        switch kind {
        case "ocr":
            1
        case "capturedPath", "currentPath":
            2
        default:
            0
        }
    }

    static func encodedShortGrams(for value: String) -> String {
        let codePoints = normalizeSearchText(value).unicodeScalars.map(\.value)
        var tokens = Set<String>()
        for index in codePoints.indices {
            tokens.insert(encodedUnigram(codePoints[index]))
            if index + 1 < codePoints.count {
                tokens.insert(
                    encodedBigram(codePoints[index], codePoints[index + 1])
                )
            }
        }
        return tokens.sorted().joined(separator: " ")
    }

    static func encodedShortTerm(_ term: String) -> String? {
        let codePoints = term.unicodeScalars.map(\.value)
        switch codePoints.count {
        case 1:
            return encodedUnigram(codePoints[0])
        case 2:
            return encodedBigram(codePoints[0], codePoints[1])
        default:
            return nil
        }
    }

    static func ftsLiteral(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func encodedUnigram(_ value: UInt32) -> String {
        "u\(String(value, radix: 16, uppercase: false))z"
    }

    private static func encodedBigram(_ lhs: UInt32, _ rhs: UInt32) -> String {
        "b\(String(lhs, radix: 16, uppercase: false))x"
            + "\(String(rhs, radix: 16, uppercase: false))z"
    }

    private static func setSearchMetadata(
        version: Int,
        generation: Int,
        state: String,
        in database: Database
    ) throws {
        for (key, value) in [
            ("searchIndexVersion", version),
            ("searchIndexGeneration", generation),
        ] {
            try database.execute(
                sql: """
                    INSERT INTO clipboard_maintenance_metadata(
                        key,
                        integer_value
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
        try setSearchIndexState(state, failureReason: nil, in: database)
    }

    private static func setSearchIndexState(
        _ state: String,
        failureReason: String?,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO clipboard_maintenance_metadata(key, text_value)
                VALUES ('searchIndexState', ?)
                ON CONFLICT(key) DO UPDATE SET
                    integer_value = NULL,
                    real_value = NULL,
                    text_value = excluded.text_value,
                    data_value = NULL
                """,
            arguments: [state]
        )
        if let failureReason {
            try database.execute(
                sql: """
                    INSERT INTO clipboard_maintenance_metadata(
                        key,
                        text_value
                    ) VALUES ('searchIndexFailure', ?)
                    ON CONFLICT(key) DO UPDATE SET
                        integer_value = NULL,
                        real_value = NULL,
                        text_value = excluded.text_value,
                        data_value = NULL
                    """,
                arguments: [failureReason]
            )
        } else {
            try database.execute(
                sql: """
                    DELETE FROM clipboard_maintenance_metadata
                    WHERE key = 'searchIndexFailure'
                    """
            )
        }
    }

    private static func maintenanceInteger(
        _ key: String,
        in database: Database
    ) throws -> Int? {
        try Int.fetchOne(
            database,
            sql: """
                SELECT integer_value
                FROM clipboard_maintenance_metadata
                WHERE key = ?
                """,
            arguments: [key]
        )
    }

    private static func maintenanceText(
        _ key: String,
        in database: Database
    ) throws -> String? {
        try String.fetchOne(
            database,
            sql: """
                SELECT text_value
                FROM clipboard_maintenance_metadata
                WHERE key = ?
                """,
            arguments: [key]
        )
    }
}
