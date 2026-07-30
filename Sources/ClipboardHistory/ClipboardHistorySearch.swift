import CryptoKit
import Foundation
import GRDB

extension ClipboardHistoryModule {
    func indexedSourceSummaries() throws
        -> [ClipboardHistorySourceSummary]
    {
        let database = try requiredDatabase()
        return try database.read { database in
            let expiryCutoff = try Self.expiryCutoff(
                at: now(),
                in: database
            )
            var conditions = ["entry.source_bundle_id IS NOT NULL"]
            var arguments: StatementArguments = []
            Self.appendTypedFilters(
                ClipboardHistoryQuery(),
                entryAlias: "entry",
                to: &conditions,
                arguments: &arguments,
                expiryCutoff: expiryCutoff
            )
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT entry.source_bundle_id,
                           COALESCE(
                               MAX(entry.source_display_name),
                               entry.source_bundle_id
                           ) AS source_display_name,
                           COUNT(*) AS entry_count
                    FROM clipboard_entries AS entry
                    WHERE \(conditions.joined(separator: " AND "))
                    GROUP BY entry.source_bundle_id
                    ORDER BY source_display_name COLLATE NOCASE,
                             entry.source_bundle_id
                    """,
                arguments: arguments
            )
            return rows.map { row in
                ClipboardHistorySourceSummary(
                    bundleIdentifier: row["source_bundle_id"],
                    displayName: row["source_display_name"],
                    count: row["entry_count"]
                )
            }
        }
    }

    func indexedCount(_ query: ClipboardHistoryQuery) throws -> Int {
        let database = try requiredDatabase()
        let normalizedQuery = Self.normalizedQuery(query.text)
        return try database.read { database in
            let expiryCutoff = try Self.expiryCutoff(
                at: now(),
                in: database
            )
            if normalizedQuery.isEmpty {
                var conditions: [String] = []
                var arguments: StatementArguments = []
                Self.appendTypedFilters(
                    query,
                    entryAlias: "entry",
                    to: &conditions,
                    arguments: &arguments,
                    expiryCutoff: expiryCutoff
                )
                let predicate = conditions.isEmpty
                    ? ""
                    : "WHERE \(conditions.joined(separator: " AND "))"
                return try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*)
                        FROM clipboard_entries AS entry
                        \(predicate)
                        """,
                    arguments: arguments
                ) ?? 0
            }
            guard try Self.searchIndexStatus(in: database) == .ready else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            let terms = normalizedQuery.split(separator: " ").map(String.init)
            guard let plan = Self.makeTermPlan(terms: terms) else {
                return 0
            }
            var conditions: [String] = []
            var arguments = plan.arguments
            Self.appendTypedFilters(
                query,
                entryAlias: "entry",
                to: &conditions,
                arguments: &arguments,
                expiryCutoff: expiryCutoff
            )
            let predicate = conditions.isEmpty
                ? ""
                : "WHERE \(conditions.joined(separator: " AND "))"
            return try Int.fetchOne(
                database,
                sql: """
                    WITH \(plan.ctes)
                    SELECT COUNT(*)
                    FROM clipboard_entries AS entry
                    \(plan.joins)
                    \(predicate)
                    """,
                arguments: arguments
            ) ?? 0
        }
    }

    func indexedPage(
        _ query: ClipboardHistoryQuery,
        after cursor: ClipboardHistoryCursor?
    ) throws -> ClipboardHistoryPage {
        let database = try requiredDatabase()
        let normalizedQuery = Self.normalizedQuery(query.text)
        return try database.read { database in
            let expiryCutoff = try Self.expiryCutoff(
                at: now(),
                in: database
            )
            let generation = try Self.searchIndexGeneration(in: database)
            let binding = try SearchCursorBinding(
                normalizedQuery: normalizedQuery,
                facet: query.facet?.rawValue,
                sourceID: query.sourceID,
                tagID: query.tagID,
                favoritesOnly: query.favoritesOnly,
                capturedAfter: query.capturedAfter?.timeIntervalSince1970,
                capturedBefore: query.capturedBefore?.timeIntervalSince1970,
                indexGeneration: generation
            )
            let validCursor = cursor
                .flatMap { try? JSONDecoder().decode(
                    SearchCursorPayload.self,
                    from: $0.token
                ) }
                .flatMap { $0.binding == binding ? $0 : nil }

            if normalizedQuery.isEmpty {
                return try Self.browsePage(
                    query,
                    binding: binding,
                    cursor: validCursor,
                    expiryCutoff: expiryCutoff,
                    in: database
                )
            }
            switch try Self.searchIndexStatus(in: database) {
            case .ready:
                break
            case .indexing:
                return ClipboardHistoryPage(
                    entries: [],
                    nextCursor: nil,
                    state: .indexing
                )
            case .failed(let reason):
                return ClipboardHistoryPage(
                    entries: [],
                    nextCursor: nil,
                    state: .failed(reason)
                )
            }
            return try Self.searchPage(
                query,
                normalizedQuery: normalizedQuery,
                binding: binding,
                cursor: validCursor,
                expiryCutoff: expiryCutoff,
                in: database
            )
        }
    }

    private static func browsePage(
        _ query: ClipboardHistoryQuery,
        binding: SearchCursorBinding,
        cursor: SearchCursorPayload?,
        expiryCutoff: Double?,
        in database: Database
    ) throws -> ClipboardHistoryPage {
        var conditions: [String] = []
        var arguments: StatementArguments = []
        appendTypedFilters(
            query,
            entryAlias: "entry",
            to: &conditions,
            arguments: &arguments,
            expiryCutoff: expiryCutoff
        )
        if let cursor {
            conditions.append(
                """
                (
                    entry.last_captured_at < ?
                    OR (
                        entry.last_captured_at = ?
                        AND (
                            entry.recency_order < ?
                            OR (
                                entry.recency_order = ?
                                AND entry.id < ?
                            )
                        )
                    )
                )
                """
            )
            arguments += [
                cursor.lastCapturedAt,
                cursor.lastCapturedAt,
                cursor.recencyOrder,
                cursor.recencyOrder,
                cursor.entryID,
            ]
        }
        let predicate = conditions.isEmpty
            ? ""
            : "WHERE \(conditions.joined(separator: " AND "))"
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT entry.id, entry.captured_at, entry.last_captured_at,
                       entry.recency_order,
                       entry.preview_text, entry.is_favorite,
                       entry.source_bundle_id, entry.source_display_name,
                       entry.source_provenance
                FROM clipboard_entries AS entry
                \(predicate)
                ORDER BY entry.last_captured_at DESC,
                         entry.recency_order DESC,
                         entry.id DESC
                LIMIT 101
                """,
            arguments: arguments
        )
        let hasMore = rows.count > 100
        let pageRows = Array(rows.prefix(100))
        let entries = try pageRows.map {
            try entry(from: $0, in: database)
        }
        let nextCursor = hasMore
            ? try pageRows.last.map {
                try makeCursor(
                    binding: binding,
                    rank: nil,
                    lastCapturedAt: $0["last_captured_at"],
                    recencyOrder: $0["recency_order"],
                    entryID: $0["id"]
                )
            }
            : nil
        return ClipboardHistoryPage(
            entries: entries,
            nextCursor: nextCursor
        )
    }

    private static func searchPage(
        _ query: ClipboardHistoryQuery,
        normalizedQuery: String,
        binding: SearchCursorBinding,
        cursor: SearchCursorPayload?,
        expiryCutoff: Double?,
        in database: Database
    ) throws -> ClipboardHistoryPage {
        let terms = normalizedQuery.split(separator: " ").map(String.init)
        guard !terms.isEmpty else {
            return try browsePage(
                query,
                binding: binding,
                cursor: cursor,
                expiryCutoff: expiryCutoff,
                in: database
            )
        }
        guard let plan = makeRankedPlan(
            terms: terms,
            normalizedQuery: normalizedQuery
        ) else {
            return ClipboardHistoryPage(entries: [], nextCursor: nil)
        }

        var conditions: [String] = []
        var arguments = plan.arguments
        appendTypedFilters(
            query,
            entryAlias: "entry",
            to: &conditions,
            arguments: &arguments,
            expiryCutoff: expiryCutoff
        )
        let predicate = conditions.isEmpty
            ? ""
            : "WHERE \(conditions.joined(separator: " AND "))"

        // The cursor is a WHERE clause over the same key the ORDER BY uses,
        // which is what lets SQLite stop at 101 rows instead of handing every
        // match back for Swift to sort and then discard.
        var cursorPredicate = ""
        if let cursor, let rank = cursor.rank {
            let (sql, cursorArguments) = strictlyAfterPredicate(
                keys: [
                    ("rank_tier", true, rank.completeQueryTier),
                    ("rank_weakest", true, rank.weakestMatchClass),
                    ("rank_aggregate", true, rank.aggregateMatchClass),
                    ("rank_priority", true, rank.fieldPriority),
                    ("last_captured_at", false, cursor.lastCapturedAt),
                    ("recency_order", false, cursor.recencyOrder),
                    ("id", false, cursor.entryID),
                ]
            )
            cursorPredicate = "WHERE \(sql)"
            arguments += cursorArguments
        }

        let rows = try Row.fetchAll(
            database,
            sql: """
                WITH \(plan.ctes),
                ranked AS (
                    SELECT entry.id AS id,
                           entry.captured_at AS captured_at,
                           entry.last_captured_at AS last_captured_at,
                           entry.recency_order AS recency_order,
                           entry.preview_text AS preview_text,
                           entry.is_favorite AS is_favorite,
                           entry.source_bundle_id AS source_bundle_id,
                           entry.source_display_name AS source_display_name,
                           entry.source_provenance AS source_provenance,
                           \(plan.tier) AS rank_tier,
                           \(plan.weakestMatchClass) AS rank_weakest,
                           \(plan.aggregateMatchClass) AS rank_aggregate,
                           \(plan.fieldPriority) AS rank_priority
                    FROM clipboard_entries AS entry
                    \(plan.joins)
                    \(predicate)
                )
                SELECT * FROM ranked
                \(cursorPredicate)
                ORDER BY rank_tier, rank_weakest, rank_aggregate,
                         rank_priority, last_captured_at DESC,
                         recency_order DESC, id DESC
                LIMIT 101
                """,
            arguments: arguments
        )

        let hasMore = rows.count > 100
        let pageRows = Array(rows.prefix(100))
        let entries = try pageRows.map { try entry(from: $0, in: database) }
        let nextCursor = hasMore
            ? try pageRows.last.map {
                try makeCursor(
                    binding: binding,
                    rank: SearchRank(
                        completeQueryTier: $0["rank_tier"],
                        weakestMatchClass: $0["rank_weakest"],
                        aggregateMatchClass: $0["rank_aggregate"],
                        fieldPriority: $0["rank_priority"]
                    ),
                    lastCapturedAt: $0["last_captured_at"],
                    recencyOrder: $0["recency_order"],
                    entryID: $0["id"]
                )
            }
            : nil
        return ClipboardHistoryPage(
            entries: entries,
            nextCursor: nextCursor
        )
    }

    /// Matching only: one CTE per term, joined so an entry must satisfy every
    /// term. Used by `indexedCount`, which needs no ranking.
    private static func makeTermPlan(terms: [String]) -> SearchPlan? {
        guard !terms.isEmpty else { return nil }
        var ctes: [String] = []
        var joins: [String] = []
        var arguments: StatementArguments = []
        for (index, term) in terms.enumerated() {
            let name = "term_\(index)"
            guard let cte = bestMatchCTE(
                name: name,
                needle: term,
                candidateTerm: term
            ) else {
                return nil
            }
            ctes.append(cte.sql)
            arguments += cte.arguments
            joins.append("JOIN \(name) ON \(name).entry_id = entry.id")
        }
        return SearchPlan(
            ctes: ctes.joined(separator: ",\n"),
            joins: joins.joined(separator: "\n"),
            arguments: arguments,
            tier: "0",
            weakestMatchClass: "0",
            aggregateMatchClass: "0",
            fieldPriority: "0"
        )
    }

    /// Matching plus the ranking key, as SQL expressions over the term CTEs.
    ///
    /// An entry whose single field contains the whole query outranks one that
    /// only satisfies the terms separately, which is the `complete` CTE. For a
    /// single-term query the whole query *is* the term, so that CTE is skipped
    /// and every match is a complete one.
    private static func makeRankedPlan(
        terms: [String],
        normalizedQuery: String
    ) -> SearchPlan? {
        guard var plan = makeTermPlan(terms: terms) else { return nil }
        let radix = rankingGroupRadix
        let matchClasses = terms.indices.map { "term_\($0).packed / \(radix)" }
        let priorities = terms.indices.map { "term_\($0).packed % \(radix)" }
        if terms.count == 1 {
            plan.tier = "0"
            plan.weakestMatchClass = matchClasses[0]
            plan.aggregateMatchClass = matchClasses[0]
            plan.fieldPriority = priorities[0]
            return plan
        }
        // A field holding the whole query holds the first term too, so the
        // complete match reuses that term's FTS candidates instead of a
        // second index scan.
        guard let complete = bestMatchCTE(
            name: "complete",
            needle: normalizedQuery,
            candidateTerm: terms[0]
        ) else {
            return nil
        }
        plan.ctes += ",\n" + complete.sql
        plan.arguments += complete.arguments
        plan.joins += "\nLEFT JOIN complete ON complete.entry_id = entry.id"
        let completeClass = "complete.packed / \(radix)"
        plan.tier = "CASE WHEN complete.packed IS NULL THEN 1 ELSE 0 END"
        plan.weakestMatchClass = """
            CASE WHEN complete.packed IS NULL
                 THEN max(\(matchClasses.joined(separator: ", ")))
                 ELSE \(completeClass) END
            """
        plan.aggregateMatchClass = """
            CASE WHEN complete.packed IS NULL
                 THEN (\(matchClasses.joined(separator: " + ")))
                 ELSE \(completeClass) END
            """
        plan.fieldPriority = """
            CASE WHEN complete.packed IS NULL
                 THEN (\(priorities.joined(separator: " + ")))
                 ELSE complete.packed % \(radix) END
            """
        return plan
    }

    /// An entry's best field for one needle, as a single packed integer so
    /// `MIN` picks the field that wins on match class first and ranking group
    /// second — two independent `MIN`s could take each half from a different
    /// field. Match class is 0 exact, 1 prefix, 2 substring.
    ///
    /// The FTS index only narrows candidates (trigram matching is a superset),
    /// so `instr` still decides membership — the same check the Swift side
    /// used to do, on values it no longer has to load.
    private static func bestMatchCTE(
        name: String,
        needle: String,
        candidateTerm: String
    ) -> (sql: String, arguments: StatementArguments)? {
        let source: String
        let ftsArgument: String
        if candidateTerm.unicodeScalars.count <= 2 {
            guard let token = encodedShortTerm(candidateTerm) else {
                return nil
            }
            source = "clipboard_search_short_grams"
            ftsArgument = ftsLiteral(token)
        } else {
            source = "clipboard_search_trigram"
            ftsArgument = ftsLiteral(candidateTerm)
        }
        let sql = """
            \(name) AS (
                SELECT field.entry_id AS entry_id,
                       MIN(
                           (CASE
                                WHEN field.normalized_value = ? THEN 0
                                WHEN instr(field.normalized_value, ?) = 1
                                    THEN 1
                                ELSE 2
                            END) * \(rankingGroupRadix)
                           + field.ranking_group
                       ) AS packed
                FROM \(source) AS candidate
                JOIN clipboard_search_fields AS field
                  ON field.id = candidate.rowid
                WHERE \(source) MATCH ?
                  AND instr(field.normalized_value, ?) > 0
                GROUP BY field.entry_id
            )
            """
        return (sql, [needle, needle, ftsArgument, needle])
    }

    /// Keyset pagination for a mixed-direction ORDER BY: the rows strictly
    /// after `keys`, compared in the order given. Hand-writing the nesting for
    /// seven keys is how off-by-one page boundaries get in.
    private static func strictlyAfterPredicate(
        keys: [(column: String, ascending: Bool, value: any DatabaseValueConvertible)]
    ) -> (sql: String, arguments: StatementArguments) {
        // All keys equal means the row *is* the cursor, which is not after it.
        var sql = "0"
        for key in keys.reversed() {
            let comparison = key.ascending ? ">" : "<"
            sql = """
                (\(key.column) \(comparison) ? \
                OR (\(key.column) = ? AND \(sql)))
                """
        }
        return (sql, StatementArguments(keys.flatMap { [$0.value, $0.value] }))
    }

    private static func appendTypedFilters(
        _ query: ClipboardHistoryQuery,
        entryAlias: String,
        to conditions: inout [String],
        arguments: inout StatementArguments,
        expiryCutoff: Double?
    ) {
        if let expiryCutoff {
            conditions.append(
                """
                EXISTS (
                    SELECT 1
                    FROM clipboard_retention_state AS retention
                    WHERE retention.entry_id = \(entryAlias).id
                      AND (
                          retention.is_protected = 1
                          OR retention.retention_started_at > ?
                      )
                )
                """
            )
            arguments += [expiryCutoff]
        }
        if query.favoritesOnly {
            conditions.append("\(entryAlias).is_favorite = 1")
        }
        if let sourceID = query.sourceID {
            conditions.append("\(entryAlias).source_bundle_id = ?")
            arguments += [sourceID]
        }
        if let tagID = query.tagID {
            conditions.append(
                """
                EXISTS (
                    SELECT 1
                    FROM clipboard_entry_tags AS tag
                    WHERE tag.entry_id = \(entryAlias).id
                      AND tag.tag_id = ?
                )
                """
            )
            arguments += [tagID]
        }
        if let facet = query.facet {
            conditions.append(
                """
                EXISTS (
                    SELECT 1
                    FROM clipboard_entry_facets AS facet
                    WHERE facet.entry_id = \(entryAlias).id
                      AND facet.facet = ?
                )
                """
            )
            arguments += [facet.rawValue]
        }
        if let capturedAfter = query.capturedAfter {
            conditions.append("\(entryAlias).captured_at >= ?")
            arguments += [capturedAfter.timeIntervalSince1970]
        }
        if let capturedBefore = query.capturedBefore {
            conditions.append("\(entryAlias).captured_at <= ?")
            arguments += [capturedBefore.timeIntervalSince1970]
        }
    }

    static func entry(
        from row: Row,
        in database: Database
    ) throws -> ClipboardHistoryEntry {
        let storedID: String = row["id"]
        guard let value = UUID(uuidString: storedID) else {
            throw ClipboardHistoryModuleError.storeUnavailable
        }
        let facets = try String.fetchAll(
            database,
            sql: """
                SELECT facet
                FROM clipboard_entry_facets
                WHERE entry_id = ?
                """,
            arguments: [storedID]
        )
        let tagIDs = try String.fetchAll(
            database,
            sql: """
                SELECT assignment.tag_id
                FROM clipboard_entry_tags AS assignment
                JOIN clipboard_tag_definitions AS definition
                  ON definition.id = assignment.tag_id
                WHERE assignment.entry_id = ?
                ORDER BY assignment.tag_id
                """,
            arguments: [storedID]
        )
        return ClipboardHistoryEntry(
            id: ClipboardHistoryEntryID(value),
            capturedAt: Date(timeIntervalSince1970: row["captured_at"]),
            previewText: row["preview_text"],
            facets: Set(facets.compactMap(ClipboardHistoryFacet.init)),
            isFavorite: row["is_favorite"],
            tagIDs: Set(tagIDs),
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: row["source_bundle_id"],
                displayName: row["source_display_name"],
                provenance: ClipboardHistoryCaptureSourceProvenance(
                    rawValue: row["source_provenance"]
                ) ?? .unknown
            )
        )
    }

    private static func normalizedQuery(_ value: String) -> String {
        normalizeSearchText(value)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func makeCursor(
        binding: SearchCursorBinding,
        rank: SearchRank?,
        lastCapturedAt: Double,
        recencyOrder: Int,
        entryID: String
    ) throws -> ClipboardHistoryCursor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ClipboardHistoryCursor(
            token: try encoder.encode(
                SearchCursorPayload(
                    binding: binding,
                    rank: rank,
                    lastCapturedAt: lastCapturedAt,
                    recencyOrder: recencyOrder,
                    entryID: entryID
                )
            )
        )
    }
}

/// The SQL a search compiles to: the term CTEs, how they join onto
/// `clipboard_entries`, and the ranking key as expressions over them.
private struct SearchPlan {
    var ctes: String
    var joins: String
    var arguments: StatementArguments
    var tier: String
    var weakestMatchClass: String
    var aggregateMatchClass: String
    var fieldPriority: String
}

/// The ranking key, carried in the cursor so the next page resumes exactly
/// where the last one stopped.
private struct SearchRank: Codable {
    let completeQueryTier: Int
    let weakestMatchClass: Int
    let aggregateMatchClass: Int
    let fieldPriority: Int
}

private struct SearchCursorBinding: Codable, Equatable {
    let digest: Data

    init(
        normalizedQuery: String,
        facet: String?,
        sourceID: String?,
        tagID: String?,
        favoritesOnly: Bool,
        capturedAfter: Double?,
        capturedBefore: Double?,
        indexGeneration: Int64
    ) throws {
        let input = SearchCursorInput(
            normalizedQuery: normalizedQuery,
            facet: facet,
            sourceID: sourceID,
            tagID: tagID,
            favoritesOnly: favoritesOnly,
            capturedAfter: capturedAfter,
            capturedBefore: capturedBefore,
            indexGeneration: indexGeneration
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        digest = Data(SHA256.hash(data: try encoder.encode(input)))
    }
}

private struct SearchCursorInput: Codable {
    let normalizedQuery: String
    let facet: String?
    let sourceID: String?
    let tagID: String?
    let favoritesOnly: Bool
    let capturedAfter: Double?
    let capturedBefore: Double?
    let indexGeneration: Int64
}

private struct SearchCursorPayload: Codable {
    let binding: SearchCursorBinding
    let rank: SearchRank?
    let lastCapturedAt: Double
    let recencyOrder: Int
    let entryID: String
}
