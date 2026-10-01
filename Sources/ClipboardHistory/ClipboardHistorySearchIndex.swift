import Foundation
import GRDB

extension ClipboardHistoryModule {
    /// Version 2 bounds every search field to `searchFieldByteLimit`.
    /// Version 1 stored and indexed fields whole.
    static let searchIndexVersion = 2
    /// Every search field keeps at most this many UTF-8 bytes of its value,
    /// and of its normalized value, which is what both search indexes see.
    /// Search cost and index size grow with the bytes indexed, and a copied
    /// text is otherwise unbounded, so a long text is searchable by its
    /// first 64 KB only. Its representations, and so its preview and paste,
    /// stay whole.
    static let searchFieldByteLimit = 65_536
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
        // FTS integrity-check is an INSERT. A DatabasePool reader is opened
        // SQLITE_OPEN_READONLY, so a healthy index would look corrupt.
        let needsRebuild = try database.write { database in
            let version = try maintenanceInteger(
                "searchIndexVersion",
                in: database
            )
            let state = try maintenanceText("searchIndexState", in: database)
            if state == searchIndexFailedState {
                return false
            }
            guard state == searchIndexReadyState else {
                return true
            }
            if version != searchIndexVersion {
                // Version 2 only bounds search fields, so a version 1 index
                // none of whose fields exceed the bound already is a version
                // 2 index: it is stamped in place, and keeps its generation
                // because its content is unchanged. Any other version still
                // rebuilds.
                guard
                    version == 1,
                    searchIndexVersion == 2,
                    try !hasOversizedSearchFields(in: database)
                else {
                    return true
                }
                try setSearchMetadataInteger(
                    "searchIndexVersion",
                    searchIndexVersion,
                    in: database
                )
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
            let boundedFieldCount: Int
            do {
                boundedFieldCount = try rebuildSearchIndexes(
                    in: database,
                    faultInjector: faultInjector
                )
            } catch {
                do {
                    try persistSearchIndexRebuildFailure(in: database)
                    return .failed
                } catch {
                    return .failureStateUnavailable
                }
            }
            if boundedFieldCount > 0 {
                // Bounding shrank rows the history kept whole until now, so
                // their pages go back at once rather than at the next
                // maintenance pass. The index is published already, so a
                // failure here only leaves the space for that pass.
                try? reclaimFreePages(in: database)
            }
            return .ready
        }
    }

    /// Rebuilds both search indexes from the stored fields in one
    /// transaction, and returns how many fields it had to bound first.
    @discardableResult
    static func rebuildSearchIndexes(
        in database: DatabasePool,
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector()
    ) throws -> Int {
        try database.write { database in
            try database.execute(
                sql: "DROP TABLE IF EXISTS clipboard_search_trigram"
            )
            try database.execute(
                sql: "DROP TABLE IF EXISTS clipboard_search_short_grams"
            )
            // Fields stored by version 1 can exceed the bound. With both
            // indexes gone, rewriting those rows leaves nothing describing
            // their old values; the indexes are rebuilt from the new ones.
            let boundedFieldCount = try boundOversizedSearchFields(
                in: database
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
            return boundedFieldCount
        }
    }

    /// Whether any stored search field exceeds `searchFieldByteLimit`, as
    /// fields written before version 2 can.
    static func hasOversizedSearchFields(in database: Database) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM clipboard_search_fields
                    WHERE octet_length(value) > ?
                       OR octet_length(normalized_value) > ?
                )
                """,
            arguments: [searchFieldByteLimit, searchFieldByteLimit]
        ) ?? false
    }

    /// Rewrites every stored search field that exceeds `searchFieldByteLimit`
    /// to what `insertSearchField` stores for its value now, and returns how
    /// many it rewrote.
    ///
    /// This writes field rows outside the single write path ADR-0021 allows,
    /// so it may only run inside the transaction of a rebuild, after both
    /// search indexes were dropped and before they are created again. The
    /// external-content trigram index would otherwise still describe the old
    /// values, and deleting its entries later would no longer match them.
    @discardableResult
    static func boundOversizedSearchFields(in database: Database) throws -> Int {
        let fieldIDs = try Int64.fetchAll(
            database,
            sql: """
                SELECT id
                FROM clipboard_search_fields
                WHERE octet_length(value) > ?
                   OR octet_length(normalized_value) > ?
                ORDER BY id
                """,
            arguments: [searchFieldByteLimit, searchFieldByteLimit]
        )
        for fieldID in fieldIDs {
            // As many code points as the limit has bytes always cover the
            // bounded value, so a huge text never reaches Swift whole.
            guard let prefix = try String.fetchOne(
                database,
                sql: """
                    SELECT substr(value, 1, ?)
                    FROM clipboard_search_fields
                    WHERE id = ?
                    """,
                arguments: [searchFieldByteLimit, fieldID]
            ) else {
                continue
            }
            let bounded = boundedSearchField(prefix)
            try database.execute(
                sql: """
                    UPDATE clipboard_search_fields
                    SET value = ?, normalized_value = ?
                    WHERE id = ?
                    """,
                arguments: [bounded.value, bounded.normalizedValue, fieldID]
            )
        }
        return fieldIDs.count
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
        let field = boundedSearchField(value)
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
                field.value,
                field.normalizedValue,
                rankingGroup,
            ]
        )
        try faultInjector.check(.searchInsertAfterField)
        try insertSearchIndexEntries(
            fieldID: database.lastInsertedRowID,
            normalizedValue: field.normalizedValue,
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
        let newField = boundedSearchField(value)
        try database.execute(
            sql: """
                UPDATE clipboard_search_fields
                SET value = ?, normalized_value = ?, ranking_group = ?
                WHERE id = ?
                """,
            arguments: [
                newField.value,
                newField.normalizedValue,
                rankingGroup,
                fieldID,
            ]
        )
        try faultInjector.check(.searchUpdateAfterField)
        try insertSearchIndexEntries(
            fieldID: fieldID,
            normalizedValue: newField.normalizedValue,
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

    static func deleteSearchFields(
        forEntryID entryID: String,
        kind: String,
        from database: Database,
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector()
    ) throws {
        let fields = try Row.fetchAll(
            database,
            sql: """
                SELECT id, normalized_value
                FROM clipboard_search_fields
                WHERE entry_id = ? AND field_kind = ?
                ORDER BY id
                """,
            arguments: [entryID, kind]
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

    /// The value and normalized value a search field stores for `value`,
    /// each at most `searchFieldByteLimit` UTF-8 bytes.
    ///
    /// The value is bounded before it is normalized, so a huge text is never
    /// normalized whole. Normalization can expand it again (a Hangul syllable
    /// decomposes into three jamo), so the normalized value is bounded too,
    /// and need not equal `normalizeSearchText(value)` afterwards. Nothing
    /// recomputes it from the stored value: search reads only the stored
    /// normalized value.
    static func boundedSearchField(
        _ value: String
    ) -> (value: String, normalizedValue: String) {
        let boundedValue = utf8Prefix(
            of: value,
            byteLimit: searchFieldByteLimit
        )
        return (
            boundedValue,
            utf8Prefix(
                of: normalizeSearchText(boundedValue),
                byteLimit: searchFieldByteLimit
            )
        )
    }

    /// The longest prefix of `value` that ends on a Unicode scalar boundary
    /// and fits in `byteLimit` UTF-8 bytes; `value` itself when it fits.
    ///
    /// It cuts on scalars rather than characters: one grapheme cluster can
    /// carry any number of combining marks, so a character boundary may not
    /// exist anywhere near the limit.
    static func utf8Prefix(of value: String, byteLimit: Int) -> String {
        let utf8 = value.utf8
        guard
            let limit = utf8.index(
                utf8.startIndex,
                offsetBy: byteLimit,
                limitedBy: utf8.endIndex
            ),
            limit != utf8.endIndex
        else {
            return value
        }
        var end = limit
        while end > utf8.startIndex, UTF8.isContinuation(utf8[end]) {
            utf8.formIndex(before: &end)
        }
        return String(value.unicodeScalars[..<end])
    }

    /// Search ranking packs `matchClass * radix + rankingGroup` into one
    /// integer so SQL's `MIN` picks a single winning field. Every value
    /// `searchRankingGroup` can return must stay below this, or the packing
    /// bleeds into the match class — `ClipboardHistorySearchTests` pins it.
    static let rankingGroupRadix = 8

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
        try setSearchMetadataInteger(
            "searchIndexVersion",
            version,
            in: database
        )
        try setSearchMetadataInteger(
            "searchIndexGeneration",
            generation,
            in: database
        )
        try setSearchIndexState(state, failureReason: nil, in: database)
    }

    private static func setSearchMetadataInteger(
        _ key: String,
        _ value: Int,
        in database: Database
    ) throws {
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
