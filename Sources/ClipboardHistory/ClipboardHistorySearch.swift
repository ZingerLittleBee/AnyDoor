import CryptoKit
import Foundation
import GRDB

extension ClipboardHistoryModule {
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
            var matchingIDs: Set<String>?
            for term in terms {
                let termIDs = Set(
                    try Self.candidateFields(
                        matching: term,
                        in: database
                    ).compactMap { row -> String? in
                        let value: String = row["normalized_value"]
                        guard value.range(of: term) != nil else {
                            return nil
                        }
                        return row["entry_id"]
                    }
                )
                matchingIDs = matchingIDs.map {
                    $0.intersection(termIDs)
                } ?? termIDs
                if matchingIDs?.isEmpty == true {
                    return 0
                }
            }
            guard let matchingIDs, !matchingIDs.isEmpty else { return 0 }
            return try Self.filteredEntryRows(
                ids: Array(matchingIDs),
                query: query,
                expiryCutoff: expiryCutoff,
                in: database
            ).count
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

        var matchesByEntry: [String: [String: [SearchFieldMatch]]] = [:]
        for term in terms {
            let candidateRows = try candidateFields(
                matching: term,
                in: database
            )
            var matchedEntryIDs = Set<String>()
            for row in candidateRows {
                let normalizedValue: String = row["normalized_value"]
                guard normalizedValue.range(of: term) != nil else {
                    continue
                }
                let entryID: String = row["entry_id"]
                matchedEntryIDs.insert(entryID)
                matchesByEntry[entryID, default: [:]][term, default: []]
                    .append(
                        SearchFieldMatch(
                            normalizedValue: normalizedValue,
                            rankingGroup: row["ranking_group"]
                        )
                    )
            }
            if matchesByEntry.isEmpty {
                return ClipboardHistoryPage(entries: [], nextCursor: nil)
            }
            matchesByEntry = matchesByEntry.filter {
                matchedEntryIDs.contains($0.key)
            }
        }

        let metadata = try filteredEntryRows(
            ids: Array(matchesByEntry.keys),
            query: query,
            expiryCutoff: expiryCutoff,
            in: database
        )
        var ranked: [RankedSearchEntry] = []
        for row in metadata {
            let entryID: String = row["id"]
            guard let termMatches = matchesByEntry[entryID],
                terms.allSatisfy({ termMatches[$0]?.isEmpty == false })
            else {
                continue
            }
            let allMatches = termMatches.values.flatMap { $0 }
            let completeMatches = allMatches.filter {
                $0.normalizedValue.range(of: normalizedQuery) != nil
            }
            let rank: SearchRank
            if let complete = completeMatches.min(by: {
                $0.completeRank(for: normalizedQuery)
                    < $1.completeRank(for: normalizedQuery)
            }) {
                let completeRank = complete.completeRank(
                    for: normalizedQuery
                )
                rank = SearchRank(
                    completeQueryTier: 0,
                    weakestMatchClass: completeRank.matchClass,
                    aggregateMatchClass: completeRank.matchClass,
                    fieldPriority: complete.rankingGroup
                )
            } else {
                let bestTermMatches = terms.compactMap { term in
                    termMatches[term]?.min {
                        $0.termRank(for: term) < $1.termRank(for: term)
                    }
                }
                guard bestTermMatches.count == terms.count else {
                    continue
                }
                let termRanks = zip(terms, bestTermMatches).map {
                    $1.termRank(for: $0)
                }
                rank = SearchRank(
                    completeQueryTier: 1,
                    weakestMatchClass:
                        termRanks.map(\.matchClass).max() ?? 2,
                    aggregateMatchClass:
                        termRanks.map(\.matchClass).reduce(0, +),
                    fieldPriority:
                        bestTermMatches.map(\.rankingGroup).reduce(0, +)
                )
            }
            ranked.append(
                RankedSearchEntry(
                    row: row,
                    rank: rank,
                    lastCapturedAt: row["last_captured_at"],
                    recencyOrder: row["recency_order"],
                    entryID: entryID
                )
            )
        }
        ranked.sort()
        if let cursor, let lastRank = cursor.rank {
            ranked.removeAll {
                !$0.isAfter(
                    rank: lastRank,
                    lastCapturedAt: cursor.lastCapturedAt,
                    recencyOrder: cursor.recencyOrder,
                    entryID: cursor.entryID
                )
            }
        }

        let hasMore = ranked.count > 100
        let pageRows = Array(ranked.prefix(100))
        let entries = try pageRows.map {
            try entry(from: $0.row, in: database)
        }
        let nextCursor = hasMore
            ? try pageRows.last.map {
                try makeCursor(
                    binding: binding,
                    rank: $0.rank,
                    lastCapturedAt: $0.lastCapturedAt,
                    recencyOrder: $0.recencyOrder,
                    entryID: $0.entryID
                )
            }
            : nil
        return ClipboardHistoryPage(
            entries: entries,
            nextCursor: nextCursor
        )
    }

    private static func candidateFields(
        matching term: String,
        in database: Database
    ) throws -> [Row] {
        if term.unicodeScalars.count <= 2 {
            guard let token = encodedShortTerm(term) else { return [] }
            return try Row.fetchAll(
                database,
                sql: """
                    SELECT field.entry_id, field.normalized_value,
                           field.ranking_group
                    FROM clipboard_search_short_grams AS candidate
                    JOIN clipboard_search_fields AS field
                      ON field.id = candidate.rowid
                    WHERE clipboard_search_short_grams MATCH ?
                    """,
                arguments: [ftsLiteral(token)]
            )
        }
        return try Row.fetchAll(
            database,
            sql: """
                SELECT field.entry_id, field.normalized_value,
                       field.ranking_group
                FROM clipboard_search_trigram AS candidate
                JOIN clipboard_search_fields AS field
                  ON field.id = candidate.rowid
                WHERE clipboard_search_trigram MATCH ?
                """,
            arguments: [ftsLiteral(term)]
        )
    }

    private static func filteredEntryRows(
        ids: [String],
        query: ClipboardHistoryQuery,
        expiryCutoff: Double?,
        in database: Database
    ) throws -> [Row] {
        var result: [Row] = []
        for chunkStart in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(
                ids[chunkStart..<min(chunkStart + 500, ids.count)]
            )
            var conditions = [
                "entry.id IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ", ")))"
            ]
            var arguments = StatementArguments(chunk)
            appendTypedFilters(
                query,
                entryAlias: "entry",
                to: &conditions,
                arguments: &arguments,
                expiryCutoff: expiryCutoff
            )
            result += try Row.fetchAll(
                database,
                sql: """
                    SELECT entry.id, entry.captured_at,
                           entry.last_captured_at, entry.recency_order,
                           entry.preview_text,
                           entry.is_favorite, entry.source_bundle_id,
                           entry.source_display_name,
                           entry.source_provenance
                    FROM clipboard_entries AS entry
                    WHERE \(conditions.joined(separator: " AND "))
                    """,
                arguments: arguments
            )
        }
        return result
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

private struct SearchFieldMatch {
    let normalizedValue: String
    let rankingGroup: Int

    func completeRank(for query: String) -> SearchMatchRank {
        SearchMatchRank(
            matchClass: matchClass(for: query),
            fieldPriority: rankingGroup
        )
    }

    func termRank(for term: String) -> SearchMatchRank {
        SearchMatchRank(
            matchClass: matchClass(for: term),
            fieldPriority: rankingGroup
        )
    }

    private func matchClass(for value: String) -> Int {
        if normalizedValue == value {
            return 0
        }
        if normalizedValue.hasPrefix(value) {
            return 1
        }
        return 2
    }
}

private struct SearchMatchRank: Comparable {
    let matchClass: Int
    let fieldPriority: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.matchClass, lhs.fieldPriority)
            < (rhs.matchClass, rhs.fieldPriority)
    }
}

private struct SearchRank: Codable, Equatable, Comparable {
    let completeQueryTier: Int
    let weakestMatchClass: Int
    let aggregateMatchClass: Int
    let fieldPriority: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (
            lhs.completeQueryTier,
            lhs.weakestMatchClass,
            lhs.aggregateMatchClass,
            lhs.fieldPriority
        ) < (
            rhs.completeQueryTier,
            rhs.weakestMatchClass,
            rhs.aggregateMatchClass,
            rhs.fieldPriority
        )
    }
}

private struct RankedSearchEntry: Comparable {
    let row: Row
    let rank: SearchRank
    let lastCapturedAt: Double
    let recencyOrder: Int
    let entryID: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.rank != rhs.rank {
            return lhs.rank < rhs.rank
        }
        if lhs.lastCapturedAt != rhs.lastCapturedAt {
            return lhs.lastCapturedAt > rhs.lastCapturedAt
        }
        if lhs.recencyOrder != rhs.recencyOrder {
            return lhs.recencyOrder > rhs.recencyOrder
        }
        return lhs.entryID > rhs.entryID
    }

    func isAfter(
        rank cursorRank: SearchRank,
        lastCapturedAt cursorCapturedAt: Double,
        recencyOrder cursorRecencyOrder: Int,
        entryID cursorEntryID: String
    ) -> Bool {
        if rank != cursorRank {
            return rank > cursorRank
        }
        if lastCapturedAt != cursorCapturedAt {
            return lastCapturedAt < cursorCapturedAt
        }
        if recencyOrder != cursorRecencyOrder {
            return recencyOrder < cursorRecencyOrder
        }
        return entryID < cursorEntryID
    }
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
