import CryptoKit
import Foundation
import GRDB

struct ClipboardHistoryPageSyncContext: Sendable {
    let textConflicts: Set<String>
    let files: [String: [ClipboardHistoryFileDisplayPlan<ClipboardHistorySyncFileSummary>]]
    let locations: [String: [ClipboardHistoryFileDisplayPlan<ClipboardHistoryLinkedFileLocation>]]
    let materializationRevisions: [String: Int64]
}

struct ClipboardHistoryResolvedDisplay: Sendable {
    let page: ClipboardHistoryPage
    let facts: ClipboardHistoryFileDisplayFacts
}

struct ClipboardHistoryPageDisplaySnapshot: Sendable {
    let page: ClipboardHistoryPage
    var context: ClipboardHistoryPageSyncContext?

    var hasNativeFacts: Bool {
        guard let context else { return false }
        return context.files.values.contains { !$0.isEmpty } || context.locations.values.contains { !$0.isEmpty }
    }

    func resolve(facts initialFacts: ClipboardHistoryFileDisplayFacts = .init(),
        faults: ClipboardHistoryFaultInjector = .init(),
        checkCancellation: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> ClipboardHistoryResolvedDisplay {
        guard let context else { return .init(page: page, facts: initialFacts) }
        var facts = initialFacts
        facts.setNativeReadCheck {
            try checkCancellation()
            try faults.check(.nativeFileDisplayProbe)
            try checkCancellation()
        }
        let entries = try page.entries.map { entry in
            try checkCancellation()
            let id = entry.id.value.uuidString.lowercased()
            let files = try (context.files[id] ?? []).map { plan in
                try checkCancellation()
                let value = plan.resolve(&facts)
                try facts.checkNativeReadFailure()
                return value
            }
            let locations = try (context.locations[id] ?? []).map { plan in
                try checkCancellation()
                let value = plan.resolve(&facts)
                try facts.checkNativeReadFailure()
                return value
            }
            return ClipboardHistoryEntry(id: entry.id, capturedAt: entry.capturedAt,
                previewText: entry.previewText, facets: entry.facets, isFavorite: entry.isFavorite,
                tagIDs: entry.tagIDs, source: entry.source, materializationRevision: entry.materializationRevision,
                hasTextConflict: entry.hasTextConflict,
                syncFiles: files, linkedFileLocations: locations)
        }
        try checkCancellation()
        facts.setNativeReadCheck({})
        return .init(page: .init(entries: entries, nextCursor: page.nextCursor,
            cursorDisposition: page.cursorDisposition, state: page.state), facts: facts)
    }
}

extension ClipboardHistoryModule {
    private static func pageSyncContext(entryIDs: [String], in database: Database) throws -> ClipboardHistoryPageSyncContext {
        guard !entryIDs.isEmpty else { return .init(textConflicts: [], files: [:], locations: [:], materializationRevisions: [:]) }
        // Representations have immutable AUTOINCREMENT identities. Replacing
        // exact content deletes/inserts rows; any future in-place payload edit
        // must also advance this materialization token.
        let placeholders = Array(repeating: "?", count: entryIDs.count).joined(separator: ",")
        let revisions = try Row.fetchAll(database, sql: """
            SELECT entry_id, MAX(id) AS revision FROM clipboard_representations
            WHERE entry_id IN (\(placeholders)) GROUP BY entry_id
            """, arguments: StatementArguments(entryIDs))
        let materializationRevisions = Dictionary(uniqueKeysWithValues: revisions.map { row in
            (row["entry_id"] as String, row["revision"] as Int64)
        })
        let accountID = try String.fetchOne(database, sql: "SELECT account_id FROM clipboard_sync_settings WHERE id = 1")
        let conflicts = try syncTextConflicts(entryIDs: entryIDs, accountID: accountID, in: database)
        let files = try syncFileSummaryPlans(entryIDs: entryIDs, in: database)
        let locations = try linkedFileLocationPlans(entryIDs: entryIDs, in: database)
        return .init(textConflicts: conflicts, files: files, locations: locations, materializationRevisions: materializationRevisions)
    }

    func indexedSourceSummaries() throws
        -> [ClipboardHistorySourceSummary]
    {
        let database = try requiredDatabase()
        return try database.read { database in
            let expiryCutoff = try Self.expiryCutoff(
                at: now(),
                in: database
            )
            var conditions: [String] = []
            var arguments: StatementArguments = []
            Self.appendTypedFilters(
                ClipboardHistoryQuery(),
                entryAlias: "entry",
                to: &conditions,
                arguments: &arguments,
                expiryCutoff: expiryCutoff
            )
            let predicate = conditions.isEmpty
                ? "1"
                : conditions.joined(separator: " AND ")
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT entry.source_bundle_id,
                           entry.source_provenance,
                           COALESCE(
                               MAX(entry.source_display_name),
                               entry.source_bundle_id
                           ) AS source_display_name,
                           COUNT(*) AS entry_count
                    FROM clipboard_entries AS entry
                    WHERE \(predicate)
                    GROUP BY entry.source_bundle_id,
                             CASE
                                 WHEN entry.source_bundle_id IS NULL
                                   AND entry.source_provenance = 'universalClipboard'
                                 THEN 'universalClipboard'
                                 WHEN entry.source_bundle_id IS NULL
                                 THEN 'unknown'
                                 ELSE ''
                             END
                    ORDER BY entry.source_bundle_id IS NULL,
                             source_display_name COLLATE NOCASE,
                             entry.source_provenance
                    """,
                arguments: arguments
            )
            return rows.map { row in
                let bundleIdentifier: String? = row["source_bundle_id"]
                let provenance = ClipboardHistoryCaptureSourceProvenance(
                    rawValue: row["source_provenance"]
                ) ?? .unknown
                let id: ClipboardHistorySourceID
                if let bundleIdentifier {
                    id = .application(bundleIdentifier)
                } else if provenance == .universalClipboard {
                    id = .universalClipboard
                } else {
                    id = .unknown
                }
                return ClipboardHistorySourceSummary(
                    id: id,
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
    ) async throws -> ClipboardHistoryPage {
        let epoch = storeEpoch
        let sourceDatabase = try requiredDatabase()
        var facts = ClipboardHistoryFileDisplayFacts()
        for _ in 0..<3 {
            try Task.checkCancellation()
            let (snapshot, revision) = try indexedPageSnapshot(query, after: cursor)
            // A SQL-only result is already coherent. Do not add a suspension
            // or invalidate text browsing for unrelated file progress.
            guard snapshot.hasNativeFacts else { return snapshot.page }
            let faults = faultInjector
            let previousFacts = facts
            do {
                let resolved = try await ClipboardHistoryNativeDisplayQueue.shared.resolve(key: .init(
                    pool: sourceDatabase, epoch: epoch, revision: revision, request: .page(query, cursor), page: snapshot.page),
                    waiting: faults.nativeDisplayWaiting) { checkCancellation in
                    try checkCancellation()
                    try faults.check(.pageNativeFileFacts)
                    return try snapshot.resolve(facts: previousFacts, faults: faults, checkCancellation: checkCancellation)
                }
                facts = resolved.facts
            } catch ClipboardHistoryNativeDisplayQueue.WaitError.timedOut {
                // A timeout ends this request's native attempts. It never
                // starts another worker or waits through three timer budgets.
                return try currentDisplayPage(query, after: cursor, facts: facts, pool: sourceDatabase, epoch: epoch)
            }
            try Task.checkCancellation()
            guard epoch == storeEpoch, database === sourceDatabase else { throw ClipboardHistoryModuleError.storeUnavailable }
            if try linkedRead({ try Self.historyRevision(in: $0) }) == revision {
                // Coalescing shares only native facts. SQL-only transfer state
                // may change without advancing the history revision.
                return try snapshot.resolve(facts: facts.cacheOnly()).page
            }
        }
        return try currentDisplayPage(query, after: cursor, facts: facts, pool: sourceDatabase, epoch: epoch)
    }

    private func currentDisplayPage(_ query: ClipboardHistoryQuery, after cursor: ClipboardHistoryCursor?,
        facts: ClipboardHistoryFileDisplayFacts, pool: DatabasePool, epoch: Int) throws -> ClipboardHistoryPage {
        try Task.checkCancellation()
        guard epoch == storeEpoch, database === pool else { throw ClipboardHistoryModuleError.storeUnavailable }
        // Native facts are display hints. Refresh SQL authority, membership,
        // filters, and cursor generation without another suspension or I/O.
        let (latest, _) = try indexedPageSnapshot(query, after: cursor)
        return try latest.resolve(facts: facts.cacheOnly()).page
    }

    static func entryMutationResult(from row: Row, in database: Database, didMutate: Bool) throws -> MutationApplyResult {
        let snapshot = try entryDisplaySnapshot(from: row, in: database)
        return .init(outcome: .updated(snapshot.page.entries[0]), didMutate: didMutate,
            displaySnapshot: snapshot, displayRevision: try historyRevision(in: database))
    }

    private static func entryDisplaySnapshot(from row: Row, in database: Database) throws -> ClipboardHistoryPageDisplaySnapshot {
        let context = try pageSyncContext(entryIDs: [row["id"]], in: database)
        let entry = try entry(from: row, in: database, syncContext: context)
        return .init(page: .init(entries: [entry], nextCursor: nil, cursorDisposition: .initial), context: context)
    }

    func resolveMutationDisplay(_ result: MutationApplyResult, in pool: DatabasePool,
        epoch: Int) async throws -> ClipboardHistoryMutationOutcome {
        guard let snapshot = result.displaySnapshot, snapshot.hasNativeFacts,
              case .updated(let entry) = result.outcome else { return result.outcome }
        let faults = faultInjector
        var facts = ClipboardHistoryFileDisplayFacts()
        do {
            let resolved = try await ClipboardHistoryNativeDisplayQueue.shared.resolve(key: .init(
                pool: pool, epoch: epoch, revision: result.displayRevision, request: .mutation(entry.id), page: snapshot.page),
                waiting: faults.nativeDisplayWaiting) { checkCancellation in
                try checkCancellation()
                try faults.check(.entryNativeFileFacts)
                return try snapshot.resolve(faults: faults, checkCancellation: checkCancellation)
            }
            facts = resolved.facts
        } catch ClipboardHistoryNativeDisplayQueue.WaitError.timedOut {
            // Metadata has already committed. Return current SQL with
            // conservative hints rather than an error for optional display I/O.
        }
        try Task.checkCancellation()
        guard epoch == storeEpoch, database === pool else { throw ClipboardHistoryModuleError.storeUnavailable }
        let latest = try linkedRead { database -> ClipboardHistoryPageDisplaySnapshot? in
            let id = entry.id.value.uuidString.lowercased()
            guard try isLiveEntry(id, at: now(), in: database),
                  let row = try Row.fetchOne(database, sql: "SELECT * FROM clipboard_entries WHERE id = ?", arguments: [id]) else { return nil }
            return try Self.entryDisplaySnapshot(from: row, in: database)
        }
        guard let latest else { return .notFound }
        // The mutation already committed. Return current SQL metadata rather
        // than failing on unrelated revisions or restoring an older favorite.
        // Native facts are display hints: newly encountered identities remain
        // unavailable until a fresh page inspects them; no I/O occurs here.
        let page = try latest.resolve(facts: facts.cacheOnly()).page
        return .updated(page.entries[0])
    }

    private func indexedPageSnapshot(_ query: ClipboardHistoryQuery, after cursor: ClipboardHistoryCursor?)
        throws -> (ClipboardHistoryPageDisplaySnapshot, Int64) {
        let database = try requiredDatabase()
        let normalizedQuery = Self.normalizedQuery(query.text)
        return try database.read { database in
            let revision = try Self.historyRevision(in: database)
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
                indexGeneration: generation
            )
            let validCursor = cursor
                .flatMap { try? JSONDecoder().decode(
                    SearchCursorPayload.self,
                    from: $0.token
                ) }
                .flatMap { $0.binding == binding ? $0 : nil }
            // A cursor whose binding no longer matches is dropped rather than
            // rejected, so the caller gets the first page instead of an
            // error. That is invisible in the entries, hence the disposition.
            let disposition: ClipboardHistoryCursorDisposition
            if cursor == nil {
                disposition = .initial
            } else if validCursor != nil {
                disposition = .continued
            } else {
                disposition = .restarted
            }

            if normalizedQuery.isEmpty {
                return (try Self.browsePage(
                    query,
                    binding: binding,
                    cursor: validCursor,
                    disposition: disposition,
                    expiryCutoff: expiryCutoff,
                    in: database
                ), revision)
            }
            switch try Self.searchIndexStatus(in: database) {
            case .ready:
                break
            case .indexing:
                return (.init(page: ClipboardHistoryPage(
                    entries: [],
                    nextCursor: nil,
                    cursorDisposition: disposition,
                    state: .indexing
                )), revision)
            case .failed(let reason):
                return (.init(page: ClipboardHistoryPage(
                    entries: [],
                    nextCursor: nil,
                    cursorDisposition: disposition,
                    state: .failed(reason)
                )), revision)
            }
            return (try Self.searchPage(
                query,
                normalizedQuery: normalizedQuery,
                binding: binding,
                cursor: validCursor,
                disposition: disposition,
                expiryCutoff: expiryCutoff,
                in: database
            ), revision)
        }
    }

    private static func browsePage(
        _ query: ClipboardHistoryQuery,
        binding: SearchCursorBinding,
        cursor: SearchCursorPayload?,
        disposition: ClipboardHistoryCursorDisposition,
        expiryCutoff: Double?,
        in database: Database
    ) throws -> ClipboardHistoryPageDisplaySnapshot {
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
        let context = try pageSyncContext(entryIDs: pageRows.map { $0["id"] as String }, in: database)
        let entries = try pageRows.map {
            try entry(from: $0, in: database, syncContext: context)
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
        return .init(page: ClipboardHistoryPage(
            entries: entries,
            nextCursor: nextCursor,
            cursorDisposition: disposition
        ), context: context)
    }

    private static func searchPage(
        _ query: ClipboardHistoryQuery,
        normalizedQuery: String,
        binding: SearchCursorBinding,
        cursor: SearchCursorPayload?,
        disposition: ClipboardHistoryCursorDisposition,
        expiryCutoff: Double?,
        in database: Database
    ) throws -> ClipboardHistoryPageDisplaySnapshot {
        let terms = normalizedQuery.split(separator: " ").map(String.init)
        guard !terms.isEmpty else {
            return try browsePage(
                query,
                binding: binding,
                cursor: cursor,
                disposition: disposition,
                expiryCutoff: expiryCutoff,
                in: database
            )
        }
        guard let plan = makeRankedPlan(
            terms: terms,
            normalizedQuery: normalizedQuery
        ) else {
            return .init(page: ClipboardHistoryPage(
                entries: [],
                nextCursor: nil,
                cursorDisposition: disposition
            ))
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
        let context = try pageSyncContext(entryIDs: pageRows.map { $0["id"] as String }, in: database)
        let entries = try pageRows.map { try entry(from: $0, in: database, syncContext: context) }
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
        return .init(page: ClipboardHistoryPage(
            entries: entries,
            nextCursor: nextCursor,
            cursorDisposition: disposition
        ), context: context)
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
            switch sourceID {
            case .application(let bundleIdentifier):
                conditions.append("\(entryAlias).source_bundle_id = ?")
                arguments += [bundleIdentifier]
            case .universalClipboard:
                conditions.append(
                    "\(entryAlias).source_bundle_id IS NULL "
                        + "AND \(entryAlias).source_provenance = ?"
                )
                arguments += [
                    ClipboardHistoryCaptureSourceProvenance
                        .universalClipboard.rawValue
                ]
            case .unknown:
                conditions.append(
                    "\(entryAlias).source_bundle_id IS NULL "
                        + "AND \(entryAlias).source_provenance <> ?"
                )
                arguments += [
                    ClipboardHistoryCaptureSourceProvenance
                        .universalClipboard.rawValue
                ]
            }
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
    }

    static func entry(
        from row: Row,
        in database: Database,
        syncContext: ClipboardHistoryPageSyncContext? = nil
    ) throws -> ClipboardHistoryEntry {
        let storedID: String = row["id"]
        guard let value = UUID(uuidString: storedID) else {
            throw ClipboardHistoryModuleError.storeUnavailable
        }
        let context = try syncContext ?? pageSyncContext(entryIDs: [storedID], in: database)
        // Page and mutation snapshots resolve these plans after releasing SQL.
        // Callers without a prepared context retain the live mapping.
        var facts = ClipboardHistoryFileDisplayFacts()
        let files = syncContext == nil ? context.files[storedID]?.map { $0.resolve(&facts) } ?? [] : []
        let locations = syncContext == nil ? context.locations[storedID]?.map { $0.resolve(&facts) } ?? [] : []
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
            ),
            materializationRevision: context.materializationRevisions[storedID] ?? 0,
            hasTextConflict: context.textConflicts.contains(storedID),
            syncFiles: files,
            linkedFileLocations: locations
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
        sourceID: ClipboardHistorySourceID?,
        tagID: String?,
        favoritesOnly: Bool,
        indexGeneration: Int64
    ) throws {
        let input = SearchCursorInput(
            normalizedQuery: normalizedQuery,
            facet: facet,
            sourceID: sourceID,
            tagID: tagID,
            favoritesOnly: favoritesOnly,
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
    let sourceID: ClipboardHistorySourceID?
    let tagID: String?
    let favoritesOnly: Bool
    let indexGeneration: Int64
}

private struct SearchCursorPayload: Codable {
    let binding: SearchCursorBinding
    let rank: SearchRank?
    let lastCapturedAt: Double
    let recencyOrder: Int
    let entryID: String
}
